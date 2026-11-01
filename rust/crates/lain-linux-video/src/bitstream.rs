//! lain's own HEVC VPS, SPS, PPS and slice segment headers, written as packed headers for libva (decision L7:
//! Mesa writes no VPS). A port of the writer in `spikes/linux-convert/e2e/e2e.c` (`build_vps`, `build_sps`,
//! `build_pps`, `build_slice`), which made `lain-media`'s fixtures (`fixture/hevcfix.c`). No Swift counterpart:
//! VideoToolbox writes its own.
//!
//! **What reaches the wire** (measured on radeonsi, Mesa 26.0.8, in the GPU tests and `lain-media`'s fixtures):
//! only the VPS goes out as written here. Mesa parses the packed SPS, PPS and slice header for their values and
//! writes its own: the SPS with `pic_width/height_in_luma_samples` at VCN's alignment ([`CODED_ALIGN`]) and
//! `max_transform_hierarchy_depth_inter/intra` 4/4 (3/3 here), the PPS with `dependent_slice_segments_enabled_flag`
//! 1, and slice headers with its rate control's `slice_qp_delta`. It keeps the level, the conformance window, the
//! VUI colour, range and timing (asserted on its output by `gpu_tests::the_stream_is_the_display_size`). So the
//! bit-exact and round-trip tests below cover the values Mesa reads, not the bytes the client receives.
//!
//! Intended differences from the spike's writer, all parameters of [`SequenceHeaders`]:
//! - the level is computed from the coded picture size, frame rate and bitrate ([`level_idc`]): 5.2 for
//!   2752×2064 at 120 Hz and 60 Mbps, where the spike always wrote 5.1, which is too low for that sample rate;
//! - the VUI's transfer characteristics are 13 (sRGB), matching `StreamInfo`'s `ColorTags::SRGB_FULL_RANGE`;
//!   the spike wrote 1. The client reads colour from `VideoConfig`, not the VUI (spike A, Colour);
//! - the coded size is the visible size rounded up to VCN's HEVC alignment, 64 wide and 16 high
//!   ([`CODED_ALIGN`]), with a conformance window cropping it to the visible size. The spike rounded to 8 (the
//!   minimum coding block) and only ever encoded multiples of 64×16: Mesa rewrites the SPS at its aligned size
//!   but keeps the packed SPS's window, so a window computed against an 8-aligned size decodes too large (seen
//!   2026-11-01: 1366×770 decoded at 1406×778, 1920×1080 at 1920×1088).
//!
//! With the spike's values ([`SequenceHeaders::spike`], 8-aligned) the output is bit-exact with the C writer's
//! (tested).

/// Writes bits MSB first, with Exp-Golomb codes (H.265 §9.2).
#[derive(Debug, Default, Clone)]
pub struct BitWriter {
    bytes: Vec<u8>,
    bits: usize,
}

impl BitWriter {
    pub fn new() -> Self {
        Self::default()
    }

    /// The `n` low bits of `v`, most significant first (`n` ≤ 32).
    pub fn put(&mut self, v: u32, n: u32) {
        for i in (0..n).rev() {
            if self.bits.is_multiple_of(8) {
                self.bytes.push(0);
            }
            if (v >> i) & 1 == 1 {
                let last = self.bytes.len() - 1;
                self.bytes[last] |= 0x80 >> (self.bits % 8);
            }
            self.bits += 1;
        }
    }

    pub fn flag(&mut self, f: bool) {
        self.put(u32::from(f), 1);
    }

    /// `ue(v)`.
    pub fn ue(&mut self, v: u32) {
        let x = u64::from(v) + 1;
        let n = 63 - x.leading_zeros();
        self.put(0, n);
        // n + 1 ≤ 33 bits: write the leading 1 apart when x needs 33.
        if n == 32 {
            self.put(1, 1);
            self.put(x as u32, 32);
        } else {
            self.put(x as u32, n + 1);
        }
    }

    /// `se(v)`.
    pub fn se(&mut self, v: i32) {
        let mapped = if v <= 0 { (-(i64::from(v))) as u32 * 2 } else { (v as u32) * 2 - 1 };
        self.ue(mapped);
    }

    /// `rbsp_trailing_bits()`: a stop bit, then zeros to the byte boundary.
    pub fn trailing(&mut self) {
        self.put(1, 1);
        self.align_zero();
    }

    fn align_zero(&mut self) {
        while !self.bits.is_multiple_of(8) {
            self.put(0, 1);
        }
    }

    pub fn bit_len(&self) -> usize {
        self.bits
    }

    /// The whole bytes written (a partial last byte is dropped, as the C writer's `bits / 8`).
    pub fn bytes(&self) -> &[u8] {
        &self.bytes[..self.bits / 8]
    }
}

/// One NAL unit: a 4-byte start code, the 2-byte header (layer 0, temporal id 1), then the RBSP with emulation
/// prevention bytes inserted (`00 00` followed by 0–3 gets a `03`).
pub fn nal(nal_type: u8, rbsp: &BitWriter) -> Vec<u8> {
    let payload = rbsp.bytes();
    let mut out = Vec::with_capacity(payload.len() + 8);
    out.extend_from_slice(&[0, 0, 0, 1, nal_type << 1, 1]);
    let mut zeros = 0;
    for &b in payload {
        if zeros >= 2 && b <= 3 {
            out.push(3);
            zeros = 0;
        }
        out.push(b);
        zeros = if b == 0 { zeros + 1 } else { 0 };
    }
    out
}

/// NAL unit types written here (H.265 Table 7-1).
pub mod nal_type {
    pub const TRAIL_R: u8 = 1;
    pub const IDR_W_RADL: u8 = 19;
    pub const VPS: u8 = 32;
    pub const SPS: u8 = 33;
    pub const PPS: u8 = 34;
}

/// HEVC Main, 4:2:0 8-bit, at the level the stream needs: the sequence-level values of the headers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SequenceHeaders {
    /// The visible size in luma samples (even).
    pub width: u32,
    pub height: u32,
    /// The VUI timing (`1 / fps`).
    pub fps: u32,
    /// `general_level_idc` (30 × the level).
    pub level_idc: u8,
    pub full_range: bool,
    pub primaries: u8,
    pub transfer: u8,
    pub matrix: u8,
    /// What the coded size is rounded up to, (width, height): [`CODED_ALIGN`] for lain's stream, [`MIN_CB`] for
    /// the spike's.
    pub coded_align: (u32, u32),
}

/// The minimum coding block size (the SPS's `log2_min_luma_coding_block_size`): the coded picture size is a
/// multiple of it.
pub const MIN_CB: u32 = 8;

/// The coded-size alignment of VCN's HEVC encoder, (width, height): radeonsi codes a picture of the context's
/// size rounded up to 64 × 16 and writes that size into its SPS (Mesa's `radeon_vcn_enc`, measured 2026-11-01:
/// 1366×770 is coded at 1408×784, 1920×1080 at 1920×1088). The packed SPS says the same size, so the conformance
/// window it carries (which Mesa copies) crops exactly to the visible size.
pub const CODED_ALIGN: (u32, u32) = (64, 16);

/// `v` rounded up to a multiple of [`MIN_CB`].
pub fn align_cb(v: u32) -> u32 {
    v.div_ceil(MIN_CB) * MIN_CB
}

/// `(width, height)` rounded up to `align`.
pub fn align_size((width, height): (u32, u32), align: (u32, u32)) -> (u32, u32) {
    (width.div_ceil(align.0) * align.0, height.div_ceil(align.1) * align.1)
}

/// The lowest Main-tier level (H.265 Table A.8: `MaxLumaPs`, `MaxLumaSr`, `MaxBR` with `CpbVclFactor` 1000, and
/// the picture-dimension bound `sqrt(MaxLumaPs × 8)`) that holds a coded `width × height` at `fps` and
/// `bitrate`, as `general_level_idc`. 186 (level 6.2) if none does. The size is rounded up to [`MIN_CB`] here;
/// callers pass the coded size.
pub fn level_idc(width: u32, height: u32, fps: u32, bitrate: u32) -> u8 {
    // (level_idc, MaxLumaPs, MaxLumaSr, MaxBR in kbit/s).
    const LEVELS: &[(u8, u64, u64, u64)] = &[
        (30, 36_864, 552_960, 128),
        (60, 122_880, 3_686_400, 1_500),
        (63, 245_760, 7_372_800, 3_000),
        (90, 552_960, 16_588_800, 6_000),
        (93, 983_040, 33_177_600, 10_000),
        (120, 2_228_224, 66_846_720, 12_000),
        (123, 2_228_224, 133_693_440, 20_000),
        (150, 8_912_896, 267_386_880, 25_000),
        (153, 8_912_896, 534_773_760, 40_000),
        (156, 8_912_896, 1_069_547_520, 60_000),
        (180, 35_651_584, 1_069_547_520, 60_000),
        (183, 35_651_584, 2_139_095_040, 120_000),
        (186, 35_651_584, 4_278_190_080, 240_000),
    ];
    let (w, h) = (u64::from(align_cb(width)), u64::from(align_cb(height)));
    let ps = w * h;
    let sr = ps * u64::from(fps.max(1));
    let br = u64::from(bitrate);
    for &(idc, max_ps, max_sr, max_br) in LEVELS {
        let max_dim = ((max_ps * 8) as f64).sqrt() as u64;
        if ps <= max_ps && w <= max_dim && h <= max_dim && sr <= max_sr && br <= max_br * 1000 {
            return idc;
        }
    }
    186
}

impl SequenceHeaders {
    /// lain's stream: Main at the computed level, full range, BT.709 primaries and matrix, the sRGB transfer
    /// (the colour `ColorTags::SRGB_FULL_RANGE` describes).
    pub fn new(width: u32, height: u32, fps: u32, bitrate: u32) -> Self {
        let color = lain_platform::ColorTags::SRGB_FULL_RANGE;
        let (cw, ch) = align_size((width, height), CODED_ALIGN);
        Self {
            width,
            height,
            fps,
            level_idc: level_idc(cw, ch, fps, bitrate),
            full_range: color.full_range,
            primaries: color.primaries,
            transfer: color.transfer,
            matrix: color.matrix,
            coded_align: CODED_ALIGN,
        }
    }

    /// The spike's values (`e2e.c`): level 5.1, transfer 1 and the coded size rounded to 8, for the bit-exact
    /// comparison.
    pub fn spike(width: u32, height: u32, fps: u32) -> Self {
        Self {
            width,
            height,
            fps,
            level_idc: 153,
            full_range: true,
            primaries: 1,
            transfer: 1,
            matrix: 1,
            coded_align: (MIN_CB, MIN_CB),
        }
    }

    /// The coded size: the visible size rounded up to [`Self::coded_align`] (VCN's 64 × 16 for lain's stream).
    /// The encode context, its surfaces and the SPS are at this size.
    pub fn coded_size(&self) -> (u32, u32) {
        align_size((self.width, self.height), self.coded_align)
    }

    /// `profile_tier_level(1, 0)`: Main profile, Main tier, compatible with Main and Main 10, progressive frames.
    fn profile_tier_level(&self, w: &mut BitWriter) {
        w.put(0, 2); // general_profile_space
        w.put(0, 1); // general_tier_flag: Main
        w.put(1, 5); // general_profile_idc: Main
        w.put(0x6000_0000, 32); // compatibility flags: Main (1) and Main 10 (2)
        w.put(1, 1); // progressive_source_flag
        w.put(0, 1); // interlaced_source_flag
        w.put(0, 1); // non_packed_constraint_flag
        w.put(1, 1); // frame_only_constraint_flag
        w.put(0, 32); // 43 reserved bits and general_inbld_flag
        w.put(0, 12);
        w.put(u32::from(self.level_idc), 8);
    }

    /// The VPS NAL unit, with its start code.
    pub fn vps(&self) -> Vec<u8> {
        let mut w = BitWriter::new();
        w.put(0, 4); // vps_video_parameter_set_id
        w.put(1, 1); // vps_base_layer_internal_flag
        w.put(1, 1); // vps_base_layer_available_flag
        w.put(0, 6); // vps_max_layers_minus1
        w.put(0, 3); // vps_max_sub_layers_minus1
        w.put(1, 1); // vps_temporal_id_nesting_flag
        w.put(0xFFFF, 16); // vps_reserved_0xffff_16bits
        self.profile_tier_level(&mut w);
        w.put(1, 1); // vps_sub_layer_ordering_info_present_flag
        w.ue(1); // vps_max_dec_pic_buffering_minus1: two pictures
        w.ue(0); // vps_max_num_reorder_pics
        w.ue(0); // vps_max_latency_increase_plus1
        w.put(0, 6); // vps_max_layer_id
        w.ue(0); // vps_num_layer_sets_minus1
        w.put(0, 1); // vps_timing_info_present_flag
        w.put(0, 1); // vps_extension_flag
        w.trailing();
        nal(nal_type::VPS, &w)
    }

    /// The SPS NAL unit, with its start code.
    pub fn sps(&self) -> Vec<u8> {
        let (cw, ch) = self.coded_size();
        let mut w = BitWriter::new();
        w.put(0, 4); // sps_video_parameter_set_id
        w.put(0, 3); // sps_max_sub_layers_minus1
        w.put(1, 1); // sps_temporal_id_nesting_flag
        self.profile_tier_level(&mut w);
        w.ue(0); // sps_seq_parameter_set_id
        w.ue(1); // chroma_format_idc: 4:2:0
        w.ue(cw); // pic_width_in_luma_samples
        w.ue(ch); // pic_height_in_luma_samples
        let crop = (cw != self.width) || (ch != self.height);
        w.flag(crop); // conformance_window_flag
        if crop {
            // In chroma samples (SubWidthC = SubHeightC = 2): left, right, top, bottom.
            w.ue(0);
            w.ue((cw - self.width) / 2);
            w.ue(0);
            w.ue((ch - self.height) / 2);
        }
        w.ue(0); // bit_depth_luma_minus8
        w.ue(0); // bit_depth_chroma_minus8
        w.ue(4); // log2_max_pic_order_cnt_lsb_minus4: 8 bits
        w.put(1, 1); // sps_sub_layer_ordering_info_present_flag
        w.ue(1); // sps_max_dec_pic_buffering_minus1
        w.ue(0); // sps_max_num_reorder_pics
        w.ue(0); // sps_max_latency_increase_plus1
        w.ue(0); // log2_min_luma_coding_block_size_minus3: 8
        w.ue(3); // log2_diff_max_min_luma_coding_block_size: 64
        w.ue(0); // log2_min_luma_transform_block_size_minus2: 4
        w.ue(3); // log2_diff_max_min_luma_transform_block_size: 32
        w.ue(3); // max_transform_hierarchy_depth_inter
        w.ue(3); // max_transform_hierarchy_depth_intra
        w.put(0, 1); // scaling_list_enabled_flag
        w.put(1, 1); // amp_enabled_flag
        w.put(0, 1); // sample_adaptive_offset_enabled_flag
        w.put(0, 1); // pcm_enabled_flag
        w.ue(0); // num_short_term_ref_pic_sets
        w.put(0, 1); // long_term_ref_pics_present_flag
        w.put(0, 1); // sps_temporal_mvp_enabled_flag
        w.put(0, 1); // strong_intra_smoothing_enabled_flag
        w.put(1, 1); // vui_parameters_present_flag
        // vui_parameters()
        w.put(0, 1); // aspect_ratio_info_present_flag
        w.put(0, 1); // overscan_info_present_flag
        w.put(1, 1); // video_signal_type_present_flag
        w.put(5, 3); // video_format: unspecified
        w.flag(self.full_range); // video_full_range_flag
        w.put(1, 1); // colour_description_present_flag
        w.put(u32::from(self.primaries), 8);
        w.put(u32::from(self.transfer), 8);
        w.put(u32::from(self.matrix), 8);
        w.put(0, 1); // chroma_loc_info_present_flag
        w.put(0, 1); // neutral_chroma_indication_flag
        w.put(0, 1); // field_seq_flag
        w.put(0, 1); // frame_field_info_present_flag
        w.put(0, 1); // default_display_window_flag
        w.put(1, 1); // vui_timing_info_present_flag
        w.put(1, 32); // vui_num_units_in_tick
        w.put(self.fps, 32); // vui_time_scale
        w.put(0, 1); // vui_poc_proportional_to_timing_flag
        w.put(0, 1); // vui_hrd_parameters_present_flag
        w.put(0, 1); // bitstream_restriction_flag
        w.put(0, 1); // sps_extension_present_flag
        w.trailing();
        nal(nal_type::SPS, &w)
    }

    /// The PPS NAL unit, with its start code: init_qp 26, `cu_qp_delta` on (the rate control's per-CU QP), loop
    /// filter across slices.
    pub fn pps(&self) -> Vec<u8> {
        let mut w = BitWriter::new();
        w.ue(0); // pps_pic_parameter_set_id
        w.ue(0); // pps_seq_parameter_set_id
        w.put(0, 1); // dependent_slice_segments_enabled_flag
        w.put(0, 1); // output_flag_present_flag
        w.put(0, 3); // num_extra_slice_header_bits
        w.put(0, 1); // sign_data_hiding_enabled_flag
        w.put(0, 1); // cabac_init_present_flag
        w.ue(0); // num_ref_idx_l0_default_active_minus1
        w.ue(0); // num_ref_idx_l1_default_active_minus1
        w.se(0); // init_qp_minus26
        w.put(0, 1); // constrained_intra_pred_flag
        w.put(0, 1); // transform_skip_enabled_flag
        w.put(1, 1); // cu_qp_delta_enabled_flag
        w.ue(0); // diff_cu_qp_delta_depth
        w.se(0); // pps_cb_qp_offset
        w.se(0); // pps_cr_qp_offset
        w.put(0, 1); // pps_slice_chroma_qp_offsets_present_flag
        w.put(0, 1); // weighted_pred_flag
        w.put(0, 1); // weighted_bipred_flag
        w.put(0, 1); // transquant_bypass_enabled_flag
        w.put(0, 1); // tiles_enabled_flag
        w.put(0, 1); // entropy_coding_sync_enabled_flag
        w.put(1, 1); // pps_loop_filter_across_slices_enabled_flag
        w.put(0, 1); // deblocking_filter_control_present_flag
        w.put(0, 1); // pps_scaling_list_data_present_flag
        w.put(0, 1); // lists_modification_present_flag
        w.ue(0); // log2_parallel_merge_level_minus2
        w.put(0, 1); // slice_segment_header_extension_present_flag
        w.put(0, 1); // pps_extension_present_flag
        w.trailing();
        nal(nal_type::PPS, &w)
    }

    /// VPS, SPS and PPS together, as a keyframe's access unit starts.
    pub fn parameter_sets(&self) -> Vec<u8> {
        let mut out = self.vps();
        out.extend(self.sps());
        out.extend(self.pps());
        out
    }
}

/// The slice segment header of one picture, one slice per picture, for the SPS and PPS above: an IDR (I slice),
/// or a TRAIL_R P slice with one reference, the previous picture (POC − 1), coded in the header. Mesa writes
/// the parameter sets only when a packed slice header comes with them (radeonsi's `radeon_vcn_enc_encode_headers`
/// returns early without one), and it parses this header for the slice's values (`e2e.c`).
pub fn slice_header(idr: bool, poc: u32) -> Vec<u8> {
    slice_header_qp(idr, poc, 0)
}

/// [`slice_header`] with `slice_qp_delta` (the slice's QP is 26 + `qp_delta`).
pub fn slice_header_qp(idr: bool, poc: u32, qp_delta: i32) -> Vec<u8> {
    let mut w = BitWriter::new();
    w.put(1, 1); // first_slice_segment_in_pic_flag
    if idr {
        w.put(0, 1); // no_output_of_prior_pics_flag
    }
    w.ue(0); // slice_pic_parameter_set_id
    w.ue(if idr { 2 } else { 1 }); // slice_type: I or P
    if !idr {
        w.put(poc & 0xFF, 8); // slice_pic_order_cnt_lsb
        w.put(0, 1); // short_term_ref_pic_set_sps_flag: coded here
        w.ue(1); // num_negative_pics
        w.ue(0); // num_positive_pics
        w.ue(0); // delta_poc_s0_minus1: POC − 1
        w.put(1, 1); // used_by_curr_pic_s0_flag
        w.put(0, 1); // num_ref_idx_active_override_flag
        w.ue(0); // five_minus_max_num_merge_cand
    }
    w.se(qp_delta); // slice_qp_delta
    w.put(1, 1); // slice_loop_filter_across_slices_enabled_flag
    w.put(1, 1); // byte_alignment(): a one, then zeros
    w.align_zero();
    nal(if idr { nal_type::IDR_W_RADL } else { nal_type::TRAIL_R }, &w)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    // The bytes of e2e.c's (and hevcfix.c's) writer for 2752×2064 at 120 fps, printed by its functions compiled
    // on their own (2026-11-01).
    const C_VPS: &[u8] = &[
        0x00, 0x00, 0x00, 0x01, 0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00,
        0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0xac, 0x09,
    ];
    const C_SPS: &[u8] = &[
        0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00,
        0x00, 0x03, 0x00, 0x99, 0xa0, 0x01, 0x58, 0x20, 0x02, 0x04, 0x59, 0x6b, 0x92, 0x42, 0x11, 0x22, 0x6e, 0x02,
        0x02, 0x02, 0x08, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03, 0x03, 0xc0, 0x40,
    ];
    const C_PPS: &[u8] = &[0x00, 0x00, 0x00, 0x01, 0x44, 0x01, 0xc0, 0x73, 0xc0, 0x89];
    const C_IDR: &[u8] = &[0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xaf, 0x80];
    const C_P5: &[u8] = &[0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0xd0, 0x29, 0x77, 0x80];
    const C_P300: &[u8] = &[0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0xd1, 0x61, 0x77, 0x80];
    const C_SPS_1080P60: &[u8] = &[
        0x00, 0x00, 0x00, 0x01, 0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00,
        0x00, 0x03, 0x00, 0x99, 0xa0, 0x03, 0xc0, 0x80, 0x10, 0xe5, 0x96, 0xb9, 0x24, 0x21, 0x12, 0x26, 0xe0, 0x20,
        0x20, 0x20, 0x80, 0x00, 0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x1e, 0x04,
    ];

    #[test]
    fn bit_exact_with_the_spike_writer() {
        let h = SequenceHeaders::spike(2752, 2064, 120);
        assert_eq!(h.vps(), C_VPS);
        assert_eq!(h.sps(), C_SPS);
        assert_eq!(h.pps(), C_PPS);
        assert_eq!(SequenceHeaders::spike(1920, 1080, 60).sps(), C_SPS_1080P60);
        assert_eq!(slice_header(true, 0), C_IDR);
        assert_eq!(slice_header(false, 5), C_P5);
        assert_eq!(slice_header(false, 300), C_P300, "the POC LSB wraps at 8 bits");
    }

    #[test]
    fn exp_golomb() {
        let mut w = BitWriter::new();
        for v in [0, 1, 2, 3, 7, 8, 255] {
            w.ue(v);
        }
        w.trailing();
        // 1 010 011 00100 0001000 0001001 000000100000000
        let mut r = BitReader::new(w.bytes().to_vec());
        for v in [0, 1, 2, 3, 7, 8, 255] {
            assert_eq!(r.ue(), v);
        }
        let mut w = BitWriter::new();
        for v in [0, 1, -1, 2, -2, i32::MAX, i32::MIN + 1] {
            w.se(v);
        }
        w.ue(u32::MAX);
        w.trailing();
        let mut r = BitReader::new(w.bytes().to_vec());
        for v in [0, 1, -1, 2, -2, i32::MAX, i32::MIN + 1] {
            assert_eq!(r.se(), v);
        }
        assert_eq!(r.ue(), u32::MAX);
    }

    #[test]
    fn emulation_prevention() {
        let mut w = BitWriter::new();
        for b in [0, 0, 0, 0, 0, 1, 0, 0, 2, 0, 0, 3, 0, 0, 4] {
            w.put(b, 8);
        }
        assert_eq!(
            nal(1, &w),
            [0, 0, 0, 1, 2, 1, 0, 0, 3, 0, 0, 3, 0, 1, 0, 0, 3, 2, 0, 0, 3, 3, 0, 0, 4],
            "every 00 00 0x (x ≤ 3) is broken by a 03"
        );
    }

    #[test]
    fn levels() {
        assert_eq!(level_idc(2752, 2064, 120, 60_000_000), 156, "5.2: 681 M samples/s");
        assert_eq!(level_idc(2752, 2064, 60, 60_000_000), 156, "5.2 for the bitrate");
        assert_eq!(level_idc(2752, 2064, 60, 40_000_000), 153);
        assert_eq!(level_idc(1920, 1080, 60, 10_000_000), 123);
        assert_eq!(level_idc(2064, 1548, 120, 60_000_000), 156);
        assert_eq!(level_idc(640, 480, 30, 1_000_000), 90);
        assert_eq!(level_idc(7680, 4320, 120, 60_000_000), 186);
        assert_eq!(level_idc(100_000, 16, 1, 1), 186, "too wide for any level");
    }

    #[test]
    fn lain_stream_values() {
        let h = SequenceHeaders::new(2752, 2064, 120, 60_000_000);
        assert_eq!((h.level_idc, h.full_range, h.primaries, h.transfer, h.matrix), (156, true, 1, 13, 1));
        assert_eq!(h.coded_size(), (2752, 2064));
        // VCN's 64 × 16: every iPad size but 2752×2064 needs a window (2732×2048 → 2752×2048, 2420×1668 →
        // 2432×1680), and so do D1's fallback and 1080p.
        assert_eq!(SequenceHeaders::new(1366, 1026, 60, 1).coded_size(), (1408, 1040));
        assert_eq!(SequenceHeaders::new(2732, 2048, 120, 1).coded_size(), (2752, 2048));
        assert_eq!(SequenceHeaders::new(2420, 1668, 120, 1).coded_size(), (2432, 1680));
        assert_eq!(SequenceHeaders::new(2064, 1548, 120, 1).coded_size(), (2112, 1552));
        assert_eq!(SequenceHeaders::new(1920, 1080, 60, 1).coded_size(), (1920, 1088));
        // The spike's writer rounds to 8, as e2e.c did.
        assert_eq!(SequenceHeaders::spike(1366, 1026, 60).coded_size(), (1368, 1032));
    }

    // ---- a reader for the round trip: the inverse of the writer, removing emulation prevention

    pub(crate) struct BitReader {
        rbsp: Vec<u8>,
        pos: usize,
    }

    impl BitReader {
        pub(crate) fn new(rbsp: Vec<u8>) -> Self {
            Self { rbsp, pos: 0 }
        }

        /// A NAL unit's RBSP: the bytes after the start code and 2-byte header, emulation prevention removed.
        pub(crate) fn from_nal(nal: &[u8]) -> (u8, Self) {
            let body = nal.strip_prefix(&[0, 0, 0, 1][..]).or_else(|| nal.strip_prefix(&[0, 0, 1][..])).unwrap();
            let t = (body[0] >> 1) & 0x3F;
            let mut rbsp = Vec::new();
            let mut zeros = 0;
            for &b in &body[2..] {
                if zeros >= 2 && b == 3 {
                    zeros = 0;
                    continue;
                }
                rbsp.push(b);
                zeros = if b == 0 { zeros + 1 } else { 0 };
            }
            (t, Self::new(rbsp))
        }

        pub(crate) fn u(&mut self, n: u32) -> u32 {
            let mut v = 0u64;
            for _ in 0..n {
                let bit = (self.rbsp[self.pos / 8] >> (7 - self.pos % 8)) & 1;
                v = (v << 1) | u64::from(bit);
                self.pos += 1;
            }
            v as u32
        }

        pub(crate) fn flag(&mut self) -> bool {
            self.u(1) == 1
        }

        pub(crate) fn ue(&mut self) -> u32 {
            let mut zeros = 0;
            while self.u(1) == 0 {
                zeros += 1;
            }
            let rest = if zeros == 32 { u64::from(self.u(32)) } else { u64::from(self.u(zeros)) };
            ((1u64 << zeros) + rest - 1) as u32
        }

        pub(crate) fn se(&mut self) -> i32 {
            let k = i64::from(self.ue());
            (if k % 2 == 1 { (k + 1) / 2 } else { -(k / 2) }) as i32
        }

        /// The rest is `rbsp_trailing_bits()`: a one, then zeros to the end.
        pub(crate) fn trailing(&mut self) -> bool {
            if !self.flag() {
                return false;
            }
            while self.pos < self.rbsp.len() * 8 {
                if self.flag() {
                    return false;
                }
            }
            true
        }

        fn ptl(&mut self) -> (u32, u32) {
            let _space_tier = self.u(3);
            let profile = self.u(5);
            let _compat = self.u(32);
            let _flags = self.u(4);
            let _reserved = (self.u(32), self.u(12));
            (profile, self.u(8))
        }
    }

    /// What the round trip reads back from an SPS.
    #[derive(Debug, PartialEq, Eq)]
    pub(crate) struct ParsedSps {
        pub(crate) profile: u32,
        pub(crate) level: u32,
        pub(crate) chroma_format_idc: u32,
        pub(crate) coded: (u32, u32),
        pub(crate) crop: Option<(u32, u32, u32, u32)>,
        pub(crate) bit_depth: (u32, u32),
        /// `max_transform_hierarchy_depth_inter/intra`: 3/3 here, 4/4 in Mesa's SPS.
        pub(crate) depths: (u32, u32),
        pub(crate) full_range: bool,
        pub(crate) colour: (u32, u32, u32),
        pub(crate) timing: (u32, u32),
    }

    impl ParsedSps {
        /// The visible size: the coded size less the conformance window (in chroma samples, 4:2:0).
        pub(crate) fn visible(&self) -> (u32, u32) {
            let (l, r, t, b) = self.crop.unwrap_or_default();
            (self.coded.0 - 2 * (l + r), self.coded.1 - 2 * (t + b))
        }
    }

    pub(crate) fn parse_sps(nal: &[u8]) -> ParsedSps {
        let (t, mut r) = BitReader::from_nal(nal);
        assert_eq!(t, nal_type::SPS);
        assert_eq!((r.u(4), r.u(3), r.u(1)), (0, 0, 1));
        let (profile, level) = r.ptl();
        assert_eq!(r.ue(), 0, "sps id");
        let chroma_format_idc = r.ue();
        let coded = (r.ue(), r.ue());
        let crop = r.flag().then(|| (r.ue(), r.ue(), r.ue(), r.ue()));
        let bit_depth = (r.ue() + 8, r.ue() + 8);
        assert_eq!(r.ue(), 4);
        assert!(r.flag());
        assert_eq!((r.ue(), r.ue(), r.ue()), (1, 0, 0));
        assert_eq!((r.ue(), r.ue(), r.ue(), r.ue()), (0, 3, 0, 3));
        let depths = (r.ue(), r.ue());
        assert_eq!((r.flag(), r.flag(), r.flag(), r.flag()), (false, true, false, false));
        assert_eq!(r.ue(), 0);
        assert_eq!((r.flag(), r.flag(), r.flag()), (false, false, false));
        assert!(r.flag(), "VUI");
        assert_eq!((r.flag(), r.flag(), r.flag()), (false, false, true));
        assert_eq!(r.u(3), 5);
        let full_range = r.flag();
        assert!(r.flag(), "colour description");
        let colour = (r.u(8), r.u(8), r.u(8));
        assert_eq!((r.flag(), r.flag(), r.flag(), r.flag(), r.flag()), (false, false, false, false, false));
        assert!(r.flag(), "timing");
        let timing = (r.u(32), r.u(32));
        assert_eq!((r.flag(), r.flag(), r.flag(), r.flag()), (false, false, false, false));
        assert!(r.trailing());
        ParsedSps { profile, level, chroma_format_idc, coded, crop, bit_depth, depths, full_range, colour, timing }
    }

    #[test]
    fn sps_round_trip() {
        let h = SequenceHeaders::new(2752, 2064, 120, 60_000_000);
        assert_eq!(
            parse_sps(&h.sps()),
            ParsedSps {
                profile: 1,
                level: 156,
                chroma_format_idc: 1,
                coded: (2752, 2064),
                crop: None,
                bit_depth: (8, 8),
                depths: (3, 3),
                full_range: true,
                colour: (1, 13, 1),
                timing: (1, 120),
            }
        );
        let odd = parse_sps(&SequenceHeaders::new(1366, 1026, 60, 20_000_000).sps());
        assert_eq!((odd.coded, odd.crop, odd.visible()), ((1408, 1040), Some((0, 21, 0, 7)), (1366, 1026)));
        for (w, h) in [(1366, 770), (1920, 1080), (2732, 2048), (2420, 1668), (2388, 1668), (2064, 1548)] {
            let sps = parse_sps(&SequenceHeaders::new(w, h, 120, 60_000_000).sps());
            assert_eq!(sps.visible(), (w, h));
            assert!(sps.coded.0.is_multiple_of(64) && sps.coded.1.is_multiple_of(16), "{w}×{h}: {:?}", sps.coded);
        }
    }

    #[test]
    fn vps_pps_and_slice_round_trip() {
        let h = SequenceHeaders::new(2752, 2064, 120, 60_000_000);
        let (t, mut r) = BitReader::from_nal(&h.vps());
        assert_eq!(t, nal_type::VPS);
        assert_eq!((r.u(4), r.u(1), r.u(1), r.u(6), r.u(3), r.u(1), r.u(16)), (0, 1, 1, 0, 0, 1, 0xFFFF));
        assert_eq!(r.ptl(), (1, 156));
        assert!(r.flag());
        assert_eq!((r.ue(), r.ue(), r.ue(), r.u(6), r.ue(), r.flag(), r.flag()), (1, 0, 0, 0, 0, false, false));
        assert!(r.trailing());

        let (t, mut r) = BitReader::from_nal(&h.pps());
        assert_eq!(t, nal_type::PPS);
        assert_eq!((r.ue(), r.ue()), (0, 0));
        assert_eq!(r.u(7), 0);
        assert_eq!((r.ue(), r.ue(), r.se()), (0, 0, 0));
        assert_eq!((r.flag(), r.flag(), r.flag(), r.ue(), r.se(), r.se()), (false, false, true, 0, 0, 0));
        assert_eq!(r.u(6), 0);
        assert!(r.flag(), "loop filter across slices");
        assert_eq!((r.u(3), r.ue(), r.u(2)), (0, 0, 0));
        assert!(r.trailing());

        for (idr, poc) in [(true, 0), (false, 1), (false, 255), (false, 256)] {
            let (t, mut r) = BitReader::from_nal(&slice_header(idr, poc));
            assert_eq!(t, if idr { nal_type::IDR_W_RADL } else { nal_type::TRAIL_R });
            assert!(r.flag(), "first slice");
            if idr {
                assert!(!r.flag());
            }
            assert_eq!((r.ue(), r.ue()), (0, if idr { 2 } else { 1 }));
            if !idr {
                assert_eq!(r.u(8), poc & 0xFF);
                assert!(!r.flag());
                assert_eq!((r.ue(), r.ue(), r.ue(), r.flag(), r.flag(), r.ue()), (1, 0, 0, true, false, 0));
            }
            assert_eq!((r.se(), r.flag()), (0, true));
            assert!(r.trailing(), "byte_alignment()");
        }
    }

    #[test]
    fn a_refinement_slice_carries_its_qp() {
        for (idr, delta) in [(false, -4), (true, -4), (false, 5)] {
            let (_, mut r) = BitReader::from_nal(&slice_header_qp(idr, 7, delta));
            assert!(r.flag());
            if idr {
                assert!(!r.flag());
            }
            let _ = (r.ue(), r.ue());
            if !idr {
                let _ = (r.u(8), r.flag(), r.ue(), r.ue(), r.ue(), r.flag(), r.flag(), r.ue());
            }
            assert_eq!(r.se(), delta);
            assert!(r.flag() && r.trailing());
        }
    }

    #[test]
    fn lain_media_reads_the_parameter_sets() {
        let h = SequenceHeaders::new(2752, 2064, 120, 60_000_000);
        let sets = lain_media::hevc::parameter_sets(&h.parameter_sets()).unwrap();
        // Without start codes, in VPS, SPS, PPS order, emulation prevention kept.
        assert_eq!(sets, vec![h.vps()[4..].to_vec(), h.sps()[4..].to_vec(), h.pps()[4..].to_vec()]);
        let mut au = h.parameter_sets();
        au.extend(slice_header(true, 0));
        au.extend([0xAF, 0x01]); // stands in for slice data
        let unit = lain_media::AccessUnit::from_annexb(&au).unwrap();
        assert!(unit.keyframe && unit.has_all_parameter_sets());
        assert_eq!(unit.parameter_sets, sets);
    }
}
