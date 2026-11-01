//! The HEVC encoder on libva (decision L7): a port of the encoder in `spikes/linux-convert/e2e/e2e.c` (`enc_init`,
//! `enc_submit`, `enc_collect`; spike A's `vaenc` settings), with `fixture/hevcfix.c`'s one change, bit stuffing
//! off. Swift: `LainMedia/VideoEncoder` (the behaviour: one frame in and one out, a keyframe on request).
//!
//! - HEVC Main 4:2:0 8-bit, no B-frames, one reference (the previous picture), no periodic IDR (`intra_period`
//!   and `intra_idr_period` 0), an IDR on request.
//! - CBR at the configured bitrate with a two-frame HRD, the rate control told the configured frame rate (Mutter's
//!   caps are variable-rate, spike A), and **bit stuffing off** (`rc_flags.disable_bit_stuffing`): Mesa pads every
//!   picture below its budget with filler data otherwise.
//! - lain's own VPS, SPS and PPS as packed headers on every IDR, and a packed slice header on every picture
//!   (Mesa writes the parameter sets only with one; [`crate::bitstream`]). Only the VPS reaches the stream as
//!   written: radeonsi parses the packed SPS, PPS and slice header for their values and writes its own (its SPS
//!   at VCN's 64 × 16 coded size, which is why [`SequenceHeaders::coded_size`] uses that alignment, with
//!   transform depths 4/4; its PPS with dependent slice segments on; its slice headers with its own QP).
//! - Refinement re-encodes at a lower QP: the picture's `pic_init_qp` is [`REFINEMENT_QP`] (as `vaenc
//!   --refine-qp` set it). The packed slice header carries the same `slice_qp_delta`, but that has no effect on
//!   the wire: Mesa writes the slice's QP itself. Measured here: Mesa 26.0.8 ignores a per-picture
//!   change of the rate control's `max_qp` or of the HRD with packed headers (the output was byte-identical), and
//!   follows the initial QP. Swift lets VideoToolbox spend the spare budget instead; libva gives a direct QP. A
//!   refinement exceeds the two-frame HRD (it is meant to: an idle desktop has the budget to spare).
//! - The coded buffer holds a raw picture (`width × height × 1.5`), never less than four frames' budget.
//!
//! One picture is in flight at a time ([`HevcEncoder::submit`], then [`HevcEncoder::poll`]).

use std::rc::Rc;

use crate::bitstream::{SequenceHeaders, slice_header_qp};
use crate::ffi::va as sys;
use crate::va::{Display, VABufferID, VAConfigID, VAContextID, VASurfaceID, VaError};

/// The QP a refinement picture is coded at: its `pic_init_qp` and its slice's QP (and the rate control's
/// `max_qp`). Spike A re-encoded at QP 18 in a QP 30 stream (806–843 KB, 8.4–9.2 ms); 22 trades a little of that
/// quality for smaller refinements (measured 2026-11-01 on the gradient fixture at 2752×2064: Y PSNR 39.1 → 45.8 dB
/// with one refinement of 487 KB, 46.9 dB after three).
pub const REFINEMENT_QP: u32 = 22;
/// The QP range of ordinary pictures (spike A's `vaenc`: the whole range).
pub const MIN_QP: u32 = 1;
pub const MAX_QP: u32 = 51;
/// How long a rebuild waits for a picture still in flight before tearing the session down. Short: the engine
/// rebuilds only after a hang (`EngineConfig::hung`) or after failed IDRs, so that picture is known to be late,
/// and the video thread must not stop for a second (the watchdog, conversions and requests all wait on it).
/// Tearing down early is safe for the GPU: the kernel keeps every buffer a submitted job uses alive until the
/// job's fence signals (run on the GPU: `gpu_tests::rebuild_with_a_picture_in_flight`).
pub const REBUILD_WAIT_NS: u64 = 20_000_000;
/// How long dropping the encoder waits for a picture in flight.
const DROP_WAIT_NS: u64 = 1_000_000_000;
/// The POC restarts with a forced IDR before it could overflow the driver's `i32`.
const POC_LIMIT: u32 = 1 << 30;

/// What the encoder is set up for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EncoderSettings {
    /// The visible size (even); the coded size is it rounded up to VCN's 64 × 16 ([`SequenceHeaders::coded_size`]).
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    /// Bits per second.
    pub bitrate: u32,
}

impl EncoderSettings {
    pub fn headers(&self) -> SequenceHeaders {
        SequenceHeaders::new(self.width, self.height, self.fps, self.bitrate)
    }

    /// One picture's CBR budget in bytes.
    pub fn frame_budget(&self) -> u32 {
        self.bitrate / 8 / self.fps.max(1)
    }

    /// The coded buffer's size: a raw 4:2:0 picture at the coded size (the worst IDR), at least four frames'
    /// budget, rounded up to 4 KiB.
    pub fn coded_buffer_size(&self) -> u32 {
        let (w, h) = self.headers().coded_size();
        let raw = u64::from(w) * u64::from(h) * 3 / 2;
        let size = raw.max(u64::from(self.frame_budget()) * 4);
        (size.div_ceil(4096) * 4096).min(u64::from(u32::MAX - 4095)) as u32
    }

    /// The HRD: a two-frame buffer, one frame full at the start (spike A's `vaenc`).
    pub fn hrd(&self) -> (u32, u32) {
        let frame_bits = self.bitrate / self.fps.max(1);
        (frame_bits, frame_bits.saturating_mul(2))
    }
}

/// What kind of picture to code.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PictureKind {
    pub idr: bool,
    pub refinement: bool,
}

/// One coded picture.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodedPicture {
    /// Annex-B, as the driver wrote it.
    pub annexb: Vec<u8>,
    /// It was coded as an IDR.
    pub idr: bool,
    /// The OR of the coded segments' status words (`VA_CODED_BUF_STATUS_*`).
    pub status: u32,
}

/// Why a coded picture can't be used, from its segments' status: the slice or the frame overflowed.
pub fn coded_status_problem(status: u32) -> Option<&'static str> {
    if status & sys::VA_CODED_BUF_STATUS_SLICE_OVERFLOW_MASK != 0 {
        Some("the slice overflowed the coded buffer")
    } else if status & sys::VA_CODED_BUF_STATUS_FRAME_SIZE_OVERFLOW != 0 {
        Some("the frame overflowed its size limit")
    } else if status & sys::VA_CODED_BUF_STATUS_BAD_BITSTREAM != 0 {
        Some("the driver reported a bad bitstream")
    } else {
        None
    }
}

struct InFlight {
    buffers: Vec<VABufferID>,
    idr: bool,
}

/// The encode session: config, context, two reconstructed pictures, the coded buffer. Its input surfaces belong
/// to the caller and are registered as render targets.
pub struct HevcEncoder {
    va: Rc<Display>,
    settings: EncoderSettings,
    headers: SequenceHeaders,
    inputs: Vec<VASurfaceID>,
    config: VAConfigID,
    ctx: VAContextID,
    recon: Vec<VASurfaceID>,
    coded: VABufferID,
    coded_size: u32,
    poc: u32,
    cur: usize,
    in_flight: Option<InFlight>,
}

/// Whether the driver can encode HEVC Main with CBR and the packed headers lain writes.
pub fn check_support(va: &Display) -> Result<(), String> {
    let entrypoints = va.entrypoints(sys::VAProfileHEVCMain).map_err(|e| e.to_string())?;
    if !entrypoints.contains(&sys::VAEntrypointEncSlice) {
        return Err(format!("{} can't encode HEVC Main (entrypoints {entrypoints:?})", va.vendor()));
    }
    let values = va
        .config_attributes(
            sys::VAProfileHEVCMain,
            sys::VAEntrypointEncSlice,
            &[sys::VAConfigAttribRTFormat, sys::VAConfigAttribRateControl, sys::VAConfigAttribEncPackedHeaders],
        )
        .map_err(|e| e.to_string())?;
    let packed =
        sys::VA_ENC_PACKED_HEADER_SEQUENCE | sys::VA_ENC_PACKED_HEADER_PICTURE | sys::VA_ENC_PACKED_HEADER_SLICE;
    let unsupported = sys::VA_ATTRIB_NOT_SUPPORTED;
    if values[0] == unsupported || values[0] & sys::VA_RT_FORMAT_YUV420 == 0 {
        return Err("the HEVC encoder takes no 4:2:0 input".into());
    }
    if values[1] == unsupported || values[1] & sys::VA_RC_CBR == 0 {
        return Err("the HEVC encoder has no CBR".into());
    }
    if values[2] == unsupported || values[2] & packed != packed {
        return Err(format!("the HEVC encoder takes no packed sequence, picture and slice headers ({:#x})", values[2]));
    }
    Ok(())
}

impl HevcEncoder {
    /// Sets up an encode session for `settings`, with `inputs` (NV12 surfaces at the coded size) as the pictures
    /// it will encode.
    pub fn new(va: Rc<Display>, settings: EncoderSettings, inputs: &[VASurfaceID]) -> Result<Self, VaError> {
        let headers = settings.headers();
        let mut enc = Self {
            va,
            settings,
            headers,
            inputs: inputs.to_vec(),
            config: sys::VA_INVALID_ID,
            ctx: sys::VA_INVALID_ID,
            recon: Vec::new(),
            coded: sys::VA_INVALID_ID,
            coded_size: settings.coded_buffer_size(),
            poc: 0,
            cur: 0,
            in_flight: None,
        };
        enc.create()?;
        Ok(enc)
    }

    fn create(&mut self) -> Result<(), VaError> {
        let (w, h) = self.headers.coded_size();
        let packed =
            sys::VA_ENC_PACKED_HEADER_SEQUENCE | sys::VA_ENC_PACKED_HEADER_PICTURE | sys::VA_ENC_PACKED_HEADER_SLICE;
        self.config = self.va.create_config(
            sys::VAProfileHEVCMain,
            sys::VAEntrypointEncSlice,
            &[
                (sys::VAConfigAttribRTFormat, sys::VA_RT_FORMAT_YUV420),
                (sys::VAConfigAttribRateControl, sys::VA_RC_CBR),
                (sys::VAConfigAttribEncPackedHeaders, packed),
            ],
        )?;
        self.recon = self.va.create_surfaces(w, h, 2, None)?;
        let mut targets = self.recon.clone();
        targets.extend_from_slice(&self.inputs);
        self.ctx = self.va.create_context(self.config, w, h, &targets)?;
        self.coded = self.va.create_coded_buffer(self.ctx, self.coded_size)?;
        self.poc = 0;
        self.cur = 0;
        Ok(())
    }

    fn destroy(&mut self, wait_ns: u64) {
        if let Some(f) = self.in_flight.take() {
            // Let the hardware finish with the buffers (bounded) before they go.
            let _ = self.va.sync_buffer(self.coded, wait_ns);
            for b in f.buffers {
                self.va.destroy_buffer(b);
            }
        }
        if self.coded != sys::VA_INVALID_ID {
            self.va.destroy_buffer(self.coded);
        }
        if self.ctx != sys::VA_INVALID_ID {
            self.va.destroy_context(self.ctx);
        }
        self.va.destroy_surfaces(&self.recon);
        if self.config != sys::VA_INVALID_ID {
            self.va.destroy_config(self.config);
        }
        self.coded = sys::VA_INVALID_ID;
        self.ctx = sys::VA_INVALID_ID;
        self.config = sys::VA_INVALID_ID;
        self.recon.clear();
    }

    /// Tears the session down and makes a new one (the escalation after failing IDRs: a fresh context resets the
    /// rate control's buffer, so the first IDR is small, spike A). The next picture is an IDR. A picture still in
    /// flight is waited for only [`REBUILD_WAIT_NS`].
    pub fn rebuild(&mut self) -> Result<(), VaError> {
        self.destroy(REBUILD_WAIT_NS);
        self.create()
    }

    pub fn settings(&self) -> EncoderSettings {
        self.settings
    }

    pub fn headers(&self) -> SequenceHeaders {
        self.headers
    }

    pub fn busy(&self) -> bool {
        self.in_flight.is_some()
    }

    /// Submits `input` (one of the input surfaces) as the next picture. An IDR restarts the POC and carries
    /// VPS, SPS and PPS; the first picture of a session is always one. Fails if a picture is already in flight.
    pub fn submit(&mut self, input: VASurfaceID, kind: PictureKind) -> Result<(), VaError> {
        if self.in_flight.is_some() {
            return Err(VaError { call: "submit", status: -1, message: "a picture is already in flight".into() });
        }
        let idr = kind.idr || self.poc == 0 || self.poc >= POC_LIMIT;
        if idr {
            self.poc = 0;
        }
        let mut buffers = Vec::with_capacity(16);
        let result = self.render(input, idr, kind.refinement, &mut buffers);
        match result {
            Ok(()) => {
                self.in_flight = Some(InFlight { buffers, idr });
                Ok(())
            }
            Err(e) => {
                for b in buffers {
                    self.va.destroy_buffer(b);
                }
                // The reference chain is unknown after a failed submit: start again with an IDR.
                self.poc = 0;
                Err(e)
            }
        }
    }

    fn render(
        &self,
        input: VASurfaceID,
        idr: bool,
        refinement: bool,
        bufs: &mut Vec<VABufferID>,
    ) -> Result<(), VaError> {
        let s = self.settings;
        let h = self.headers;
        let (cw, ch) = h.coded_size();
        let ctx = self.ctx;
        let va = &self.va;
        if idr {
            let mut seq = sys::VAEncSequenceParameterBufferHEVC {
                general_profile_idc: 1,
                general_level_idc: h.level_idc,
                general_tier_flag: 0,
                intra_period: 0,
                intra_idr_period: 0,
                ip_period: 1,
                bits_per_second: s.bitrate,
                pic_width_in_luma_samples: cw as u16,
                pic_height_in_luma_samples: ch as u16,
                log2_diff_max_min_luma_coding_block_size: 3,
                log2_diff_max_min_transform_block_size: 3,
                max_transform_hierarchy_depth_inter: 3,
                max_transform_hierarchy_depth_intra: 3,
                vui_parameters_present_flag: 1,
                vui_num_units_in_tick: 1,
                vui_time_scale: s.fps,
                ..Default::default()
            };
            let mut fields = sys::_VAEncSequenceParameterBufferHEVC__bindgen_ty_1__bindgen_ty_1::default();
            fields.set_chroma_format_idc(1);
            fields.set_amp_enabled_flag(1);
            fields.set_low_delay_seq(1);
            seq.seq_fields.bits = fields;
            let mut vui = sys::_VAEncSequenceParameterBufferHEVC__bindgen_ty_2__bindgen_ty_1::default();
            vui.set_vui_timing_info_present_flag(1);
            seq.vui_fields.bits = vui;
            bufs.push(va.create_buffer(ctx, sys::VAEncSequenceParameterBufferType, &seq)?);
        }

        let mut rc = sys::VAEncMiscParameterRateControl {
            bits_per_second: s.bitrate,
            target_percentage: 100,
            window_size: 1000,
            initial_qp: 26,
            min_qp: MIN_QP,
            max_qp: if refinement { REFINEMENT_QP } else { MAX_QP },
            ..Default::default()
        };
        let mut rc_flags = sys::_VAEncMiscParameterRateControl__bindgen_ty_1__bindgen_ty_1::default();
        rc_flags.set_disable_bit_stuffing(1);
        rc.rc_flags.bits = rc_flags;
        bufs.push(va.create_misc_buffer(ctx, sys::VAEncMiscParameterTypeRateControl, &rc)?);
        let fr = sys::VAEncMiscParameterFrameRate { framerate: s.fps, ..Default::default() };
        bufs.push(va.create_misc_buffer(ctx, sys::VAEncMiscParameterTypeFrameRate, &fr)?);
        let (fullness, size) = s.hrd();
        let hrd =
            sys::VAEncMiscParameterHRD { initial_buffer_fullness: fullness, buffer_size: size, ..Default::default() };
        bufs.push(va.create_misc_buffer(ctx, sys::VAEncMiscParameterTypeHRD, &hrd)?);

        // A refinement starts from REFINEMENT_QP, in the picture parameters and the packed slice header alike.
        let init_qp: i32 = if refinement { REFINEMENT_QP as i32 } else { 26 };
        let invalid = sys::VAPictureHEVC {
            picture_id: sys::VA_INVALID_SURFACE,
            flags: sys::VA_PICTURE_HEVC_INVALID,
            ..Default::default()
        };
        let mut pic = sys::VAEncPictureParameterBufferHEVC {
            decoded_curr_pic: sys::VAPictureHEVC {
                picture_id: self.recon[self.cur],
                pic_order_cnt: self.poc as i32,
                ..Default::default()
            },
            reference_frames: [invalid; 15],
            coded_buf: self.coded,
            collocated_ref_pic_index: 0xFF,
            pic_init_qp: init_qp as u8,
            nal_unit_type: if idr { 19 } else { 1 },
            ..Default::default()
        };
        let reference = sys::VAPictureHEVC {
            picture_id: self.recon[self.cur ^ 1],
            pic_order_cnt: self.poc as i32 - 1,
            flags: 0,
            ..Default::default()
        };
        if !idr {
            pic.reference_frames[0] = reference;
        }
        let mut pf = sys::_VAEncPictureParameterBufferHEVC__bindgen_ty_1__bindgen_ty_1::default();
        pf.set_idr_pic_flag(u32::from(idr));
        pf.set_coding_type(if idr { 1 } else { 2 });
        pf.set_reference_pic_flag(1);
        pf.set_cu_qp_delta_enabled_flag(1);
        pf.set_pps_loop_filter_across_slices_enabled_flag(1);
        pic.pic_fields.bits = pf;
        bufs.push(va.create_buffer(ctx, sys::VAEncPictureParameterBufferType, &pic)?);

        if idr {
            self.packed(sys::VAEncPackedHeaderSequence, &h.vps(), bufs)?;
            self.packed(sys::VAEncPackedHeaderSequence, &h.sps(), bufs)?;
            self.packed(sys::VAEncPackedHeaderPicture, &h.pps(), bufs)?;
        }

        let ctus = cw.div_ceil(64) * ch.div_ceil(64);
        let mut slice = sys::VAEncSliceParameterBufferHEVC {
            num_ctu_in_slice: ctus,
            slice_type: if idr { 2 } else { 1 },
            ref_pic_list0: [invalid; 15],
            ref_pic_list1: [invalid; 15],
            max_num_merge_cand: 5,
            ..Default::default()
        };
        if !idr {
            slice.ref_pic_list0[0] = reference;
        }
        let mut sf = sys::_VAEncSliceParameterBufferHEVC__bindgen_ty_1__bindgen_ty_1::default();
        sf.set_last_slice_of_pic_flag(1);
        sf.set_slice_loop_filter_across_slices_enabled_flag(1);
        slice.slice_fields.bits = sf;
        bufs.push(va.create_buffer(ctx, sys::VAEncSliceParameterBufferType, &slice)?);
        self.packed(sys::VAEncPackedHeaderSlice, &slice_header_qp(idr, self.poc, init_qp - 26), bufs)?;

        va.submit_picture(ctx, input, bufs)
    }

    fn packed(&self, kind: u32, nal: &[u8], bufs: &mut Vec<VABufferID>) -> Result<(), VaError> {
        let param = sys::VAEncPackedHeaderParameterBuffer {
            type_: kind,
            bit_length: (nal.len() * 8) as u32,
            has_emulation_bytes: 1,
            ..Default::default()
        };
        bufs.push(self.va.create_buffer(self.ctx, sys::VAEncPackedHeaderParameterBufferType, &param)?);
        bufs.push(self.va.create_buffer_bytes(self.ctx, sys::VAEncPackedHeaderDataBufferType, nal)?);
        Ok(())
    }

    /// Waits up to `timeout_ns` for the picture in flight. `None` while it isn't done (or none is in flight);
    /// then its access unit, or why there is none. Either way the picture is finished and the next can be
    /// submitted. A picture whose coded segments report an overflow is an error.
    pub fn poll(&mut self, timeout_ns: u64) -> Option<Result<CodedPicture, VaError>> {
        let in_flight = self.in_flight.as_ref()?;
        let idr = in_flight.idr;
        match self.va.sync_buffer(self.coded, timeout_ns) {
            Ok(false) => return None,
            Ok(true) => {}
            Err(e) => {
                self.finish(false);
                return Some(Err(e));
            }
        }
        let read = self.va.read_coded(self.coded, self.coded_size as usize);
        let result = match read {
            Ok((annexb, status)) => match coded_status_problem(status) {
                Some(problem) => Err(VaError { call: "vaSyncBuffer", status: status as i32, message: problem.into() }),
                None => Ok(CodedPicture { annexb, idr, status }),
            },
            Err(e) => Err(e),
        };
        self.finish(result.is_ok());
        Some(result)
    }

    fn finish(&mut self, ok: bool) {
        if let Some(f) = self.in_flight.take() {
            for b in f.buffers {
                self.va.destroy_buffer(b);
            }
        }
        if ok {
            self.poc += 1;
            self.cur ^= 1;
        } else {
            self.poc = 0;
        }
    }
}

impl Drop for HevcEncoder {
    fn drop(&mut self) {
        self.destroy(DROP_WAIT_NS);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_and_budget() {
        let s = EncoderSettings { width: 2752, height: 2064, fps: 120, bitrate: 60_000_000 };
        assert_eq!(s.frame_budget(), 62_500);
        assert_eq!(s.hrd(), (500_000, 1_000_000));
        assert_eq!(s.coded_buffer_size(), 8_523_776, "2752 × 2064 × 1.5 = 8 520 192, 4 KiB aligned");
        // A tiny picture still holds four frames' budget (hevcfix's overflow at 256×144).
        let tiny = EncoderSettings { width: 256, height: 144, fps: 120, bitrate: 60_000_000 };
        assert_eq!(tiny.coded_buffer_size(), 250_000_u32.div_ceil(4096) * 4096);
    }

    #[test]
    fn status_problems() {
        assert_eq!(coded_status_problem(0), None);
        assert_eq!(coded_status_problem(26), None, "the average QP bits aren't a problem");
        assert!(coded_status_problem(sys::VA_CODED_BUF_STATUS_SLICE_OVERFLOW_MASK).is_some());
        assert!(coded_status_problem(sys::VA_CODED_BUF_STATUS_FRAME_SIZE_OVERFLOW).is_some());
    }
}
