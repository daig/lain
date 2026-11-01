//! The host video path for one session (Swift: `LainHostCore/Video/HostVideoPipeline.swift`, with the
//! `VideoConfig` bookkeeping of `LainMedia/VideoEncoder.swift`).

use lain_platform::{
    Chroma, Clock, EncodeConfig, EncodeRequest, EncodedFrame, PlatformError, StreamInfo, StreamedDisplay, VideoEvent,
    VideoSession,
};
use lain_proto::{
    ChromaFormat, FrameAck, HeaderFlags, KeyframeReason, KeyframeRequest, Message, VideoCodec, VideoConfig, VideoFrame,
};
use tracing::{debug, info, warn};

use crate::hevc::AccessUnit;
use crate::stats::{FrameAckWindow, HostVideoStats, RateMeter, RollingPercentiles};
use crate::{Connection, FrameGate, IdleRefiner, Outbound};

/// Tuning (Swift: `HostVideoPipeline.Options`). Swift's `idleCheckMs` is gone: the refiner's timer is armed
/// for exactly when it is due ([`VideoPipeline::next_deadline`]). Its `cursorHz` belongs to
/// [`CursorMonitor`](crate::CursorMonitor).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PipelineOptions {
    /// N in §7.3: encoded frames that may be unacknowledged.
    pub max_in_flight: usize,
    /// The frame rate asked of the encoder, capped by the client's (see [`encode_config`]).
    pub frame_rate: u32,
    pub average_bit_rate: u32,
    pub idle_refinement_ms: u64,
    pub max_refinements: u32,
}

impl Default for PipelineOptions {
    fn default() -> Self {
        Self {
            max_in_flight: 2,
            frame_rate: 120,
            average_bit_rate: 60_000_000,
            idle_refinement_ms: 150,
            max_refinements: 2,
        }
    }
}

/// What the encoder is asked for, for `display` and a client whose `Hello` says `max_refresh_rate` (0:
/// unknown). Swift: the `VideoEncoder.Settings` built in `HostVideoPipeline.start`: the frame rate is the
/// options' capped by the client's.
///
/// Intended difference from Swift (decision L3): always HEVC Main 4:2:0 8-bit, whatever the client decodes;
/// the Mac host asks for 4:4:4 10-bit when the client hardware-decodes it.
pub fn encode_config(display: &StreamedDisplay, max_refresh_rate: u16, options: &PipelineOptions) -> EncodeConfig {
    let frame_rate =
        if max_refresh_rate > 0 { options.frame_rate.min(u32::from(max_refresh_rate)) } else { options.frame_rate };
    EncodeConfig {
        width: display.pixel_width,
        height: display.pixel_height,
        frame_rate,
        bitrate: options.average_bit_rate,
        chroma: Chroma::Yuv420,
        bit_depth: 8,
    }
}

/// Why video ended: the session's last event. The caller keeps the session going without video (Swift:
/// `onError`, and `CaptureStoppedByUser`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VideoEnd {
    Failed(PlatformError),
    StoppedByUser,
}

/// The first wait before a pending keyframe is asked for again, on an idle desktop.
const KEYFRAME_RETRY_FIRST_NS: u64 = 100_000_000;
/// The longest wait between those tries: the backoff doubles up to it.
const KEYFRAME_RETRY_MAX_NS: u64 = 1_000_000_000;

/// A captured (or re-offered) frame in the gate (Swift: `HostVideoPipeline.Item`). The session holds the
/// pixels; the pipeline holds only which capture it is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Item {
    /// Which capture (re-offers keep it).
    capture: u64,
    /// The capture time sent as `VideoFrame.captureTimeNs`. For a re-offer, the time of the re-offer, as in
    /// Swift.
    capture_ns: u64,
    refinement: bool,
}

/// The request in the encoder.
#[derive(Debug, Clone, Copy)]
struct Outstanding {
    frame_id: u32,
    item: Item,
    keyframe: bool,
    /// A keyframe asked for after a failure: the encoder's references may hold pictures the client never got.
    recovery: bool,
}

/// The host video path for one session (Swift: `HostVideoPipeline`), as a state machine its owner drives:
/// [`VideoEvent`]s from the session, the client's `FrameAck`s and `KeyframeRequest`s, and a timer, in; host →
/// client messages out through the output callback, each tagged with its connection.
///
/// - Captures go into a [`FrameGate`] (latest-wins slot, one request in the encoder, at most
///   `max_in_flight` frames unacknowledged); a request from the gate becomes [`VideoSession::encode`] with
///   the next frame id (increasing from 1; Swift: encode ids).
/// - Each `Encoded` result is converted from Annex-B ([`AccessUnit::from_annexb`]). When its parameter sets
///   (or the stream's format) differ from the last ones sent, a `VideoConfig` with a new `configId` goes out
///   first; then the `VideoFrame`, flagged `KEYFRAME` when it holds an IRAP slice and `REFINEMENT` when it was
///   an idle refinement of the very capture that was encoded. Both go on the video connection.
/// - Idle refinement re-offers the newest capture `idle_refinement_ms` after it, and again as often as
///   `max_refinements` allows; a `KeyframeRequest` forces the next request to be a keyframe and re-offers the
///   newest capture, so it goes out even when the desktop is idle.
/// - `Failed` and `StoppedByUser` end video: [`handle_event`](Self::handle_event) returns them, and the
///   pipeline ignores everything afterwards.
///
/// The owner calls [`on_timer`](Self::on_timer) at [`next_deadline`](Self::next_deadline), which it re-reads
/// after every call into the pipeline. Time comes from the [`Clock`]. Nothing here blocks or awaits except
/// [`stop`](Self::stop).
///
/// Intended differences from Swift:
/// - The display's lifecycle (create, destroy, the start/stop races) is the owner's (`lain-host`); this type
///   starts with a running session.
/// - `EncodeFailed` (and an access unit that can't be sent) makes the next request a keyframe: the encoder's
///   reference chain may be broken (the contract). VideoToolbox never needed this.
/// - The session encodes its newest capture when asked, not the gate's frame, so a result may show a newer
///   capture than the request was for. Then the refinement flag is dropped, the newer capture's time is sent,
///   and a frame for a capture no newer than the one just shown is discarded from the slot instead of encoded
///   again (unless a keyframe is pending).
/// - The `KEYFRAME` flag and `isKeyframe` come from the access unit's slices; a result whose keyframe-ness
///   disagrees with the request is sent as what it is (except as below), and a keyframe still pending is
///   asked for again.
/// - A result before any parameter sets have been sent (which the client couldn't decode), or one that isn't
///   valid Annex-B, isn't sent: it counts as a failure. So is a non-IRAP result for a keyframe asked for
///   after a failure: it may predict from a picture the client never got, and the client, not waiting for a
///   keyframe, would decode it.
/// - While a keyframe is owed (after a failure, or a result that wasn't one) and nothing else will bring it,
///   the newest capture is re-offered on a timer, 100 ms after the failure and then at a backoff doubling up
///   to 1 s, without a cap on the tries; it starts over once a keyframe is sent. Swift relies on the idle
///   refinements, at most `maxRefinements` of them, which suffice when the encoder never fails, but the
///   client asks again only when a frame arrives, and cursor-only motion makes no capture.
/// - A `Captured` for a capture a result has already shown (the session encodes its newest, and its events
///   may come in either order) is not offered unless a keyframe is owed: it would only encode the same
///   picture again. It counts as dropped before encoding.
pub struct VideoPipeline<S: VideoSession, C: Clock> {
    session: S,
    clock: C,
    out: Box<dyn FnMut(Outbound) + Send>,
    info: StreamInfo,
    running: bool,
    gate: FrameGate<Item>,
    refiner: IdleRefiner,
    /// The newest capture number (Swift: `newestCapture`).
    newest_capture: u64,
    last_captured: Option<Item>,
    outstanding: Option<Outstanding>,
    next_frame_id: u32,
    /// The newest capture a result has shown.
    shown_capture: u64,
    /// `Captured` events not offered because their capture was already shown.
    skipped_shown: u64,
    /// A request has failed since the last keyframe was sent.
    reference_broken: bool,
    /// When the owed keyframe is asked for again, and the wait after that.
    keyframe_retry_ns: Option<u64>,
    keyframe_backoff_ns: u64,
    /// The next request is a keyframe (Swift: the encoder's `forceKeyframe`, initially true).
    force_keyframe: bool,
    config_id: u32,
    config: Option<VideoConfig>,
    acks: FrameAckWindow,
    stats: HostVideoStats,
    encode_ms: RollingPercentiles,
    rtt_ms: RollingPercentiles,
    rate: RateMeter,
}

impl<S: VideoSession, C: Clock> VideoPipeline<S, C> {
    /// Takes over a running session. `out` receives every message to send, in order.
    pub fn new(session: S, clock: C, options: PipelineOptions, out: impl FnMut(Outbound) + Send + 'static) -> Self {
        let info = session.info();
        let stats = HostVideoStats {
            chroma: Some(chroma_format(info.chroma)),
            pixel_width: info.width,
            pixel_height: info.height,
            ..HostVideoStats::default()
        };
        info!(
            width = info.width,
            height = info.height,
            chroma = ?info.chroma,
            bit_depth = info.bit_depth,
            "video pipeline running"
        );
        Self {
            session,
            clock,
            out: Box::new(out),
            info,
            running: true,
            gate: FrameGate::new(options.max_in_flight),
            refiner: IdleRefiner::new(options.idle_refinement_ms, options.max_refinements),
            newest_capture: 0,
            last_captured: None,
            outstanding: None,
            next_frame_id: 1,
            shown_capture: 0,
            skipped_shown: 0,
            reference_broken: false,
            keyframe_retry_ns: None,
            keyframe_backoff_ns: KEYFRAME_RETRY_FIRST_NS,
            force_keyframe: true,
            config_id: 0,
            config: None,
            acks: FrameAckWindow::new(64),
            stats,
            encode_ms: RollingPercentiles::new(240),
            rtt_ms: RollingPercentiles::new(240),
            rate: RateMeter::new(512),
        }
    }

    /// The session (for its owner; the pipeline makes every `encode` call itself).
    pub fn session(&self) -> &S {
        &self.session
    }

    /// What the encoder produces.
    pub fn info(&self) -> StreamInfo {
        self.info
    }

    /// The chroma actually streamed (Swift: `chroma`).
    pub fn chroma(&self) -> ChromaFormat {
        chroma_format(self.info.chroma)
    }

    /// Until video ends or [`stop`](Self::stop).
    pub fn is_running(&self) -> bool {
        self.running
    }

    /// The `VideoConfig` last sent.
    pub fn current_config(&self) -> Option<&VideoConfig> {
        self.config.as_ref()
    }

    /// One event from the session. `Some` when video has ended (`Failed`, `StoppedByUser`).
    pub fn handle_event(&mut self, event: VideoEvent) -> Option<VideoEnd> {
        if !self.running {
            return None;
        }
        match event {
            VideoEvent::Captured { capture, capture_ns } => self.captured(capture, capture_ns),
            VideoEvent::Encoded(frame) => self.encoded(frame),
            VideoEvent::EncodeFailed { frame_id } => {
                if self.take_outstanding(frame_id).is_some() {
                    debug!(frame_id, "encode failed");
                    self.failed();
                }
            }
            VideoEvent::Failed(error) => {
                warn!(%error, "capture failed");
                self.running = false;
                return Some(VideoEnd::Failed(error));
            }
            VideoEvent::StoppedByUser => {
                info!("capture stopped by the owner");
                self.running = false;
                return Some(VideoEnd::StoppedByUser);
            }
        }
        None
    }

    /// Inbound on the video connection (Swift: `handleVideo`): `FrameAck`, and a `KeyframeRequest` (which
    /// the client sends on realtime, and the Swift host accepts on either). Returns whether it was one of
    /// those.
    pub fn handle_message(&mut self, message: &Message) -> bool {
        match message {
            Message::FrameAck(ack) => self.frame_ack(ack),
            Message::KeyframeRequest(request) => self.keyframe_request(request),
            _ => return false,
        }
        true
    }

    /// A `FrameAck` from the client.
    pub fn frame_ack(&mut self, ack: &FrameAck) {
        if !self.running {
            return;
        }
        let now = self.clock.now_ns();
        if let Some(a) = self.acks.acked(ack.frame_id, now) {
            self.rtt_ms.record(a.round_trip_ns as f64 / 1e6);
        }
        let next = self.gate.acked(ack.frame_id);
        self.submit(next);
    }

    /// A `KeyframeRequest` from the client (Swift: `requestKeyframe(reason:)`; D22: recovery is a keyframe).
    /// The newest capture is re-offered so the keyframe goes out even when the desktop is idle. On `resumed`
    /// and `startup` the client may have dropped frames without acking them, so the ack window restarts.
    pub fn keyframe_request(&mut self, request: &KeyframeRequest) {
        self.request_keyframe(request.reason);
    }

    /// [`keyframe_request`](Self::keyframe_request) by reason.
    pub fn request_keyframe(&mut self, reason: KeyframeReason) {
        if !self.running {
            return;
        }
        let now = self.clock.now_ns();
        let restart = matches!(reason, KeyframeReason::Resumed | KeyframeReason::Startup);
        if restart {
            self.acks.reset();
        }
        if self.last_captured.is_some() {
            self.refiner.new_frame(now);
        }
        info!(?reason, "keyframe requested");
        self.force_keyframe = true;
        if restart {
            let next = self.gate.reset();
            self.submit(next);
        }
        if let Some(last) = self.last_captured
            && !self.gate.slot_occupied()
        {
            self.offer(Item { capture: last.capture, capture_ns: now, refinement: false });
        }
    }

    /// When [`on_timer`](Self::on_timer) next has work, on the clock's time line: the next idle refinement,
    /// or the next try at a keyframe still owed. `None` when there is none to schedule; any later call into
    /// the pipeline may change that.
    pub fn next_deadline(&self) -> Option<u64> {
        if !self.running || self.gate.slot_occupied() {
            return None;
        }
        [self.refiner.next_due(), self.keyframe_retry_due()].into_iter().flatten().min()
    }

    /// The idle check (Swift: `idleTick`): re-offers the newest capture as a refinement when it is due, or
    /// (not in Swift) as a plain frame when an owed keyframe is due to be tried again.
    pub fn on_timer(&mut self) {
        if !self.running || self.gate.slot_occupied() {
            return;
        }
        let now = self.clock.now_ns();
        let Some(last) = self.last_captured else { return };
        if self.refiner.should_refine(now) {
            self.offer(Item { capture: last.capture, capture_ns: now, refinement: true });
        } else if self.keyframe_retry_due().is_some_and(|due| now >= due) {
            self.keyframe_retry_ns = None;
            debug!(capture = last.capture, "keyframe still owed: re-offering the newest capture");
            self.offer(Item { capture: last.capture, capture_ns: now, refinement: false });
        }
    }

    /// A snapshot (Swift: `stats`).
    pub fn stats(&self) -> HostVideoStats {
        let gate = self.gate.stats();
        HostVideoStats {
            offered: gate.offered,
            encoded: gate.encoded,
            dropped_before_encode: gate.dropped_before_encode + self.skipped_shown,
            peak_in_flight: gate.peak_in_flight,
            in_flight: self.gate.in_flight(),
            bytes_per_second: self.rate.bytes_per_second(self.clock.now_ns(), 1_000_000_000),
            encode_ms_p50: self.encode_ms.p50(),
            encode_ms_p95: self.encode_ms.p95(),
            ack_rtt_ms_p50: self.rtt_ms.p50(),
            ack_rtt_ms_p95: self.rtt_ms.p95(),
            ..self.stats.clone()
        }
    }

    /// Stops the session; nothing is sent afterwards. Idempotent.
    pub async fn stop(&mut self) {
        self.running = false;
        self.outstanding = None;
        self.session.stop().await;
    }

    // MARK: Inputs

    fn captured(&mut self, capture: u64, capture_ns: u64) {
        let now = self.clock.now_ns();
        let item = Item { capture, capture_ns, refinement: false };
        self.newest_capture = self.newest_capture.max(capture);
        self.stats.captured += 1;
        self.last_captured = Some(item);
        self.refiner.new_frame(now);
        if capture <= self.shown_capture && !self.force_keyframe {
            // A result has shown this capture already (see the type's doc). What waits in the slot is older.
            self.gate.discard_slot_if(|i| i.capture < capture);
            self.skipped_shown += 1;
            debug!(capture, "capture already shown: not encoded again");
            return;
        }
        self.offer(item);
    }

    /// When an owed keyframe is next tried: only while nothing else will bring it (no request in the
    /// encoder; the slot is checked by the callers).
    fn keyframe_retry_due(&self) -> Option<u64> {
        let owed = self.force_keyframe && self.outstanding.is_none() && self.last_captured.is_some();
        self.keyframe_retry_ns.filter(|_| owed)
    }

    /// A keyframe is owed after a failure or a result that wasn't one: try again after the backoff.
    fn schedule_keyframe_retry(&mut self) {
        let now = self.clock.now_ns();
        self.keyframe_retry_ns = Some(now.saturating_add(self.keyframe_backoff_ns));
        self.keyframe_backoff_ns = (self.keyframe_backoff_ns * 2).min(KEYFRAME_RETRY_MAX_NS);
    }

    fn offer(&mut self, item: Item) {
        let stale = item.capture < self.newest_capture;
        let next = self.gate.offer_unless_stale(item, stale);
        self.submit(next);
    }

    /// The gate let `item` into the encoder (Swift: `submit`).
    fn submit(&mut self, item: Option<Item>) {
        let Some(item) = item else { return };
        if !self.running {
            return;
        }
        let frame_id = self.next_frame_id;
        self.next_frame_id = self.next_frame_id.wrapping_add(1);
        let keyframe = std::mem::take(&mut self.force_keyframe);
        if keyframe {
            // This request is the try; its result schedules the next one if needed.
            self.keyframe_retry_ns = None;
        }
        let recovery = keyframe && self.reference_broken;
        self.outstanding = Some(Outstanding { frame_id, item, keyframe, recovery });
        self.session.encode(EncodeRequest { frame_id, keyframe, refinement: item.refinement });
    }

    fn take_outstanding(&mut self, frame_id: u32) -> Option<Outstanding> {
        match self.outstanding {
            Some(o) if o.frame_id == frame_id => self.outstanding.take(),
            _ => {
                warn!(frame_id, outstanding = ?self.outstanding.map(|o| o.frame_id), "result for no outstanding request");
                None
            }
        }
    }

    /// The request produced nothing that can be sent (Swift: `encoded(nil)`).
    fn failed(&mut self) {
        self.stats.encode_failures += 1;
        self.force_keyframe = true;
        self.reference_broken = true;
        self.schedule_keyframe_retry();
        let next = self.gate.encode_failed();
        self.submit(next);
    }

    fn encoded(&mut self, frame: EncodedFrame) {
        let Some(request) = self.take_outstanding(frame.frame_id) else { return };
        let au = match AccessUnit::from_annexb(&frame.annexb) {
            Ok(au) => au,
            Err(error) => {
                warn!(frame_id = frame.frame_id, %error, "encoder produced an unusable access unit");
                return self.failed();
            }
        };
        let config = if au.parameter_sets.is_empty() {
            None
        } else if !au.has_all_parameter_sets() {
            warn!(frame_id = frame.frame_id, "access unit lacks a VPS, SPS or PPS");
            return self.failed();
        } else {
            let candidate = self.video_config(au.parameter_sets);
            let same =
                self.config.as_ref().is_some_and(|c| VideoConfig { config_id: c.config_id, ..candidate.clone() } == *c);
            if same { None } else { Some(candidate) }
        };
        if config.is_none() && self.config.is_none() {
            warn!(frame_id = frame.frame_id, "frame before any parameter sets");
            return self.failed();
        }
        if request.keyframe && !au.keyframe {
            if request.recovery {
                warn!(frame_id = frame.frame_id, "keyframe requested after a failure, encoder produced none");
                return self.failed();
            }
            // The client asked for it, so it drops non-keyframes until one comes: harmless to send.
            warn!(frame_id = frame.frame_id, "keyframe requested, encoder produced none");
            self.force_keyframe = true;
            self.schedule_keyframe_retry();
        }
        if au.keyframe {
            self.reference_broken = false;
            self.keyframe_backoff_ns = KEYFRAME_RETRY_FIRST_NS;
        }
        self.shown_capture = self.shown_capture.max(frame.capture);

        let now = self.clock.now_ns();
        let same_capture = frame.capture == request.item.capture;
        let refinement = request.item.refinement && same_capture;
        let capture_time_ns = if same_capture { request.item.capture_ns } else { frame.capture_ns };
        let bytes = au.data.len();
        if frame.encode_done_ns >= frame.submit_ns {
            self.encode_ms.record((frame.encode_done_ns - frame.submit_ns) as f64 / 1e6);
        }
        self.acks.sent(frame.frame_id, bytes, now);
        self.rate.record(bytes, now);
        self.stats.sent += 1;
        self.stats.bytes_sent += bytes as u64;
        self.stats.keyframes += u64::from(au.keyframe);
        self.stats.refinements += u64::from(refinement);

        if let Some(mut config) = config {
            self.config_id = self.config_id.wrapping_add(1);
            config.config_id = self.config_id;
            info!(config_id = config.config_id, "new video config");
            self.config = Some(config.clone());
            self.emit(Message::VideoConfig(config), HeaderFlags::EMPTY);
        }
        let mut flags = if au.keyframe { HeaderFlags::KEYFRAME } else { HeaderFlags::EMPTY };
        if refinement {
            flags |= HeaderFlags::REFINEMENT;
        }
        self.emit(
            Message::VideoFrame(VideoFrame {
                frame_id: frame.frame_id,
                config_id: self.config_id,
                capture_time_ns,
                encode_done_ns: frame.encode_done_ns,
                is_keyframe: au.keyframe,
                data: au.data,
            }),
            flags,
        );

        // The session showed `frame.capture`: a plain frame for it or an older capture in the slot would
        // only encode the same picture again.
        if !self.force_keyframe {
            self.gate.discard_slot_if(|i| !i.refinement && i.capture <= frame.capture);
        }
        let next = self.gate.sent(frame.frame_id);
        self.submit(next);
    }

    fn video_config(&self, parameter_sets: Vec<Vec<u8>>) -> VideoConfig {
        VideoConfig {
            config_id: 0,
            codec: VideoCodec::Hevc,
            chroma: chroma_format(self.info.chroma),
            bit_depth: self.info.bit_depth,
            width: self.info.width,
            height: self.info.height,
            full_range: self.info.color.full_range,
            color_primaries: self.info.color.primaries,
            transfer_function: self.info.color.transfer,
            matrix: self.info.color.matrix,
            parameter_sets,
        }
    }

    fn emit(&mut self, message: Message, flags: HeaderFlags) {
        (self.out)(Outbound { connection: Connection::Video, message, flags });
    }
}

fn chroma_format(chroma: Chroma) -> ChromaFormat {
    match chroma {
        Chroma::Yuv420 => ChromaFormat::Yuv420,
        Chroma::Yuv444 => ChromaFormat::Yuv444,
    }
}
