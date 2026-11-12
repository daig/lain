//! The video thread: the `VideoSession` contract over capture, conversion and encoding, behind seams so that it
//! is unit-tested on fakes (the brief's acceptance). Its structure is SL5's (`spikes/linux-convert/e2e/e2e.c
//! --loop thread --pipeline`, polled): capture arrives from PipeWire's own thread into a latest-wins slot; the
//! newest picture is converted as soon as it arrives, one conversion ahead of the encoder; the encoder's
//! completion is polled while the next conversion runs. Swift: `HostVideoPipeline`'s capture-to-encoder path,
//! `VideoEncoder` and `FrameSource` (behaviour).
//!
//! The contract (`lain_platform::video`), and how it is kept here:
//! - **The newest capture only, kept after encoding.** A picture becomes a capture once it is converted into one
//!   of the NV12 surfaces; `Captured` is announced then (an intended difference from announcing on arrival: a
//!   picture whose import fails, or that a newer one replaces before its conversion starts, is never
//!   announced). Every request encodes the newest announced capture's surface, which stays untouched until a
//!   newer capture replaces it, so a keyframe or a refinement on an idle desktop re-encodes it.
//! - **One result per request**, in order, within a bound: a watchdog answers `EncodeFailed` for a request with
//!   no result after [`EngineConfig::watchdog`]; its late access unit is dropped. An encoder hung beyond
//!   [`EngineConfig::hung`] is rebuilt.
//! - **`EncodeFailed` before the first capture.**
//! - **Every access unit validated** ([`crate::au::validate`]): a start code first, a slice, all of VPS, SPS and
//!   PPS or none, and a requested IDR that is IRAP with all three. A bad one is `EncodeFailed`.
//! - **After any failure the next picture is an IDR**, whatever the core asks (spike A: the encoder used the lost
//!   picture as its reference, and Swift's pipeline doesn't ask for a keyframe after a failed encode).
//! - **Keyframe recovery escalates:** after [`EngineConfig::idr_failures_before_rebuild`] failed IDRs in a row the
//!   encoder session is rebuilt (a fresh rate-control buffer, spike A); after [`EngineConfig::max_rebuilds`]
//!   rebuilds without a good IDR, the session ends with `Failed`.
//! - **Session end:** lain's display ending (`GnomeSource::ended`) becomes `StoppedByUser` or `Failed`; `Destroyed`
//!   (lain's own stop) only stops capture: the core is already stopping, and requests are still answered from
//!   the kept capture. A PipeWire stream that ends while the display still runs becomes `Failed` after
//!   [`EngineConfig::end_grace`], unless the display's end reason arrives first.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

use lain_gnome::DisplayEnd;
use lain_platform::{EncodeRequest, EncodedFrame, PlatformError, VideoEvent};
use tokio::sync::{mpsc, watch};

use crate::encoder::PictureKind;
use crate::frame::Picture;

/// What the engine needs from the GPU: NV12 surfaces it converts into and encodes from (the real one is
/// [`crate::gpu::GpuPipeline`]; the tests' is a fake).
pub trait Gpu {
    /// How many NV12 surfaces there are (at least 3: the newest capture, the one encoding, the one converting).
    fn surfaces(&self) -> usize;
    /// Starts converting `picture` into `surface`. One conversion at a time.
    fn start_conversion(&mut self, picture: &Picture, surface: usize) -> Result<(), String>;
    /// Waits up to `timeout_ns` for the conversion in flight: `Ok(true)` once it has finished.
    fn poll_conversion(&mut self, timeout_ns: u64) -> Result<bool, String>;
    /// Gives up on the conversion in flight (it timed out).
    fn cancel_conversion(&mut self);
    /// Submits the encode of `surface`. One encode at a time.
    fn submit_encode(&mut self, surface: usize, kind: PictureKind) -> Result<(), String>;
    /// Waits up to `timeout_ns` for the encode in flight: `None` while it runs, then its Annex-B access unit or
    /// why there is none. Afterwards the encoder is free.
    fn poll_encode(&mut self, timeout_ns: u64) -> Option<Result<Vec<u8>, String>>;
    /// Drops the encode session (and whatever it has in flight) and makes a new one; its first picture is an IDR.
    fn rebuild_encoder(&mut self) -> Result<(), String>;
    /// The rate control's target from the next picture on (adaptive bitrate); kept across rebuilds.
    fn set_bitrate(&mut self, bits_per_second: u32);
}

/// One picture from capture, with its capture time. Dropping it gives the buffer back to PipeWire.
pub struct CaptureFrame {
    pub picture: Picture,
    /// `CLOCK_MONOTONIC` ns: the compositor's time for the picture (`spa_meta_header.pts`), else its arrival.
    pub capture_ns: u64,
    release: Option<Box<dyn FnOnce() + Send>>,
}

impl CaptureFrame {
    pub fn new(picture: Picture, capture_ns: u64, release: Option<Box<dyn FnOnce() + Send>>) -> Self {
        Self { picture, capture_ns, release }
    }
}

impl Drop for CaptureFrame {
    fn drop(&mut self) {
        if let Some(release) = self.release.take() {
            release();
        }
    }
}

impl std::fmt::Debug for CaptureFrame {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CaptureFrame").field("capture_ns", &self.capture_ns).finish_non_exhaustive()
    }
}

/// The engine's bounds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineConfig {
    /// A request without a result after this gets `EncodeFailed` (the contract: "well within a second"; spike A
    /// suggested 100 ms, several frame times; a forced IDR takes about 8 ms).
    pub watchdog: Duration,
    /// An encode still running after this is abandoned and the encoder rebuilt.
    pub hung: Duration,
    /// A conversion taking longer than this has failed.
    pub conversion_timeout: Duration,
    /// How long a PipeWire stream end waits for lain's display's end reason before it is `Failed`.
    pub end_grace: Duration,
    /// Conversions failing in a row before the session is `Failed` (an import that can't work).
    pub max_conversion_failures: u32,
    /// IDRs failing in a row before the encoder session is rebuilt.
    pub idr_failures_before_rebuild: u32,
    /// Rebuilds without a good IDR before the session is `Failed`.
    pub max_rebuilds: u32,
}

impl Default for EngineConfig {
    fn default() -> Self {
        Self {
            watchdog: Duration::from_millis(250),
            hung: Duration::from_secs(2),
            conversion_timeout: Duration::from_millis(500),
            end_grace: Duration::from_secs(1),
            max_conversion_failures: 5,
            idr_failures_before_rebuild: 2,
            max_rebuilds: 3,
        }
    }
}

/// Counters, for logs and the live tests.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EngineStats {
    /// Pictures PipeWire delivered.
    pub delivered: u64,
    /// Pictures a newer one replaced in the slot before conversion.
    pub replaced: u64,
    pub captures: u64,
    pub encoded: u64,
    pub failed: u64,
    pub conversion_failures: u64,
    pub rebuilds: u64,
}

#[derive(Default)]
struct InboxState {
    frame: Option<CaptureFrame>,
    requests: VecDeque<(EncodeRequest, u64)>,
    stop: bool,
    capture_end: Option<String>,
    stats: EngineStats,
}

/// Where capture and the session hand work to the video thread: a latest-wins picture slot, the requests, the
/// stop flag. Writers hold its lock only to swap a value, so neither PipeWire's thread nor `encode` waits.
#[derive(Default)]
pub struct Inbox {
    state: Mutex<InboxState>,
    wake: Condvar,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Inbox {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// A new picture; the one it replaces (never converted) goes back to PipeWire.
    pub fn push_frame(&self, frame: CaptureFrame) {
        let old = {
            let mut s = lock(&self.state);
            if s.stop {
                return;
            }
            s.stats.delivered += 1;
            let old = s.frame.replace(frame);
            if old.is_some() {
                s.stats.replaced += 1;
            }
            old
        };
        self.wake.notify_one();
        drop(old);
    }

    /// A request; ignored once the inbox is stopped (nobody would answer it: the event channel is closed).
    pub fn push_request(&self, request: EncodeRequest) {
        {
            let mut s = lock(&self.state);
            if s.stop {
                return;
            }
            s.requests.push_back((request, lain_platform::clock::now_ns()));
        }
        self.wake.notify_one();
    }

    /// The PipeWire stream ended or failed, for `why`.
    pub fn capture_ended(&self, why: String) {
        lock(&self.state).capture_end.get_or_insert(why);
        self.wake.notify_one();
    }

    pub fn stop(&self) {
        let frame = {
            let mut s = lock(&self.state);
            s.stop = true;
            s.requests.clear();
            s.frame.take()
        };
        self.wake.notify_all();
        drop(frame);
    }

    pub fn stats(&self) -> EngineStats {
        lock(&self.state).stats
    }
}

#[derive(Debug, Clone, Copy)]
struct Newest {
    surface: usize,
    capture: u64,
    capture_ns: u64,
}

struct Converting {
    frame: CaptureFrame,
    surface: usize,
    started_ns: u64,
}

struct InFlight {
    request: EncodeRequest,
    requested_ns: u64,
    surface: usize,
    capture: Newest,
    submit_ns: u64,
    idr: bool,
    /// The watchdog has answered it already: its result is dropped.
    timed_out: bool,
}

enum Flow {
    Go,
    Exit,
}

/// The video thread's state.
pub struct Engine<G: Gpu> {
    gpu: G,
    cfg: EngineConfig,
    inbox: Arc<Inbox>,
    events: Option<mpsc::UnboundedSender<VideoEvent>>,
    ended: watch::Receiver<Option<DisplayEnd>>,
    stop_capture: Box<dyn Fn() + Send>,
    capture_stopped: bool,
    capture_end: Option<(u64, String)>,
    requests: VecDeque<(EncodeRequest, u64)>,
    newest: Option<Newest>,
    converting: Option<Converting>,
    encoding: Option<InFlight>,
    captures: u64,
    need_idr: bool,
    failed_idrs: u32,
    rebuilds: u32,
    conversion_failures: u32,
    stats: EngineStats,
}

fn ms(d: Duration) -> u64 {
    d.as_nanos() as u64
}

impl<G: Gpu> Engine<G> {
    pub fn new(
        gpu: G,
        cfg: EngineConfig,
        inbox: Arc<Inbox>,
        events: mpsc::UnboundedSender<VideoEvent>,
        ended: watch::Receiver<Option<DisplayEnd>>,
        stop_capture: Box<dyn Fn() + Send>,
    ) -> Self {
        assert!(gpu.surfaces() >= 3, "the engine needs three surfaces");
        Self {
            gpu,
            cfg,
            inbox,
            events: Some(events),
            ended,
            stop_capture,
            capture_stopped: false,
            capture_end: None,
            requests: VecDeque::new(),
            newest: None,
            converting: None,
            encoding: None,
            captures: 0,
            need_idr: true,
            failed_idrs: 0,
            rebuilds: 0,
            conversion_failures: 0,
            stats: EngineStats::default(),
        }
    }

    fn emit(&self, event: VideoEvent) {
        // The counters first, so a reader who saw the event sees them.
        {
            let mut s = lock(&self.inbox.state);
            s.stats.captures = self.stats.captures;
            s.stats.encoded = self.stats.encoded;
            s.stats.failed = self.stats.failed;
            s.stats.conversion_failures = self.stats.conversion_failures;
            s.stats.rebuilds = self.stats.rebuilds;
        }
        if let Some(tx) = &self.events {
            let _ = tx.send(event);
        }
    }

    /// Runs until stopped or until the session ends; then the GPU is dropped (on this thread, where the GL context
    /// is current) and the event channel closes.
    pub fn run(mut self) {
        loop {
            if let Flow::Exit = self.step() {
                break;
            }
        }
        (self.stop_capture)();
        self.events = None;
        if let Some(c) = self.converting.take() {
            self.gpu.cancel_conversion();
            drop(c);
        }
        // Also when the session ended by itself (StoppedByUser, Failed): a picture capture pushed after the last
        // turn goes back to PipeWire now, not when the owner stops or drops the session, and later pictures and
        // requests are refused.
        self.inbox.stop();
        tracing::debug!(stats = ?self.stats, "video thread ends");
    }

    fn fatal(&mut self, why: String) -> Flow {
        tracing::warn!("video fails: {why}");
        self.emit(VideoEvent::Failed(PlatformError::Failed(why)));
        Flow::Exit
    }

    /// One turn of the loop: take what arrived, check how the session stands, advance the conversion and the
    /// encode, and wait a little.
    fn step(&mut self) -> Flow {
        let now = lain_platform::clock::now_ns();
        let mut frame = None;
        {
            let mut s = lock(&self.inbox.state);
            if s.stop {
                return Flow::Exit;
            }
            self.requests.extend(s.requests.drain(..));
            if let Some(why) = &s.capture_end
                && self.capture_end.is_none()
            {
                self.capture_end = Some((now, why.clone()));
            }
            if self.converting.is_none() {
                frame = s.frame.take();
            }
        }
        if let Flow::Exit = self.check_end(now) {
            return Flow::Exit;
        }
        if let Some(frame) = frame
            && !self.capture_stopped
            && let Flow::Exit = self.start_conversion(frame, now)
        {
            return Flow::Exit;
        }
        if let Flow::Exit = self.advance(now) {
            return Flow::Exit;
        }
        self.wait();
        Flow::Go
    }

    fn check_end(&mut self, now: u64) -> Flow {
        let end = self.ended.borrow().clone();
        match end {
            Some(DisplayEnd::StoppedByUser) => {
                tracing::info!("lain's display was stopped from the desktop: video ends");
                self.emit(VideoEvent::StoppedByUser);
                return Flow::Exit;
            }
            Some(DisplayEnd::Failed(why)) => return self.fatal(format!("lain's display failed: {why}")),
            Some(DisplayEnd::Destroyed) if !self.capture_stopped => {
                self.capture_stopped = true;
                (self.stop_capture)();
            }
            Some(DisplayEnd::Destroyed) => {}
            None => {}
        }
        if let Some((at, why)) = &self.capture_end
            && !self.capture_stopped
            && now.saturating_sub(*at) >= ms(self.cfg.end_grace)
        {
            let why = why.clone();
            return self.fatal(format!("lain's display's stream ended: {why}"));
        }
        Flow::Go
    }

    fn free_surface(&self) -> Option<usize> {
        let busy = |s: usize| {
            self.newest.is_some_and(|n| n.surface == s) || self.encoding.as_ref().is_some_and(|e| e.surface == s)
        };
        (0..self.gpu.surfaces()).find(|&s| !busy(s))
    }

    fn start_conversion(&mut self, frame: CaptureFrame, now: u64) -> Flow {
        let Some(surface) = self.free_surface() else { return Flow::Go };
        match self.gpu.start_conversion(&frame.picture, surface) {
            Ok(()) => self.converting = Some(Converting { frame, surface, started_ns: now }),
            Err(e) => {
                // Whatever the failed start left behind is given up, so the next conversion can start.
                self.gpu.cancel_conversion();
                drop(frame);
                return self.conversion_failed(e);
            }
        }
        Flow::Go
    }

    fn conversion_failed(&mut self, why: String) -> Flow {
        self.conversion_failures += 1;
        self.stats.conversion_failures += 1;
        tracing::debug!("a captured picture couldn't be converted: {why}");
        if self.conversion_failures >= self.cfg.max_conversion_failures {
            return self.fatal(format!("captured pictures can't be converted: {why}"));
        }
        Flow::Go
    }

    fn advance(&mut self, now: u64) -> Flow {
        // How long to wait on the GPU this turn: 50 µs on each with both in flight (e2e.c alternates the
        // conversion's fence and the coded buffer, so an access unit is collected when the encode finishes, not
        // when the conversion does: SL5's "polled"), 250 µs with one, nothing when idle (the inbox wait instead).
        let (conv_wait, enc_wait) = match (self.converting.is_some(), self.encoding.is_some()) {
            (true, true) => (50_000, 50_000),
            (true, false) => (250_000, 0),
            (false, true) => (0, 250_000),
            (false, false) => (0, 0),
        };
        // The conversion: done → the newest capture.
        if let Some(c) = &self.converting {
            match self.gpu.poll_conversion(conv_wait) {
                Ok(true) => {
                    let c = self.converting.take().expect("converting");
                    self.captures += 1;
                    self.stats.captures += 1;
                    self.conversion_failures = 0;
                    let newest = Newest { surface: c.surface, capture: self.captures, capture_ns: c.frame.capture_ns };
                    self.newest = Some(newest);
                    drop(c.frame); // back to PipeWire as soon as the conversion has read it (SL5)
                    self.emit(VideoEvent::Captured { capture: newest.capture, capture_ns: newest.capture_ns });
                }
                Ok(false) => {
                    if now.saturating_sub(c.started_ns) >= ms(self.cfg.conversion_timeout) {
                        self.gpu.cancel_conversion();
                        self.converting = None;
                        if let Flow::Exit = self.conversion_failed("the conversion timed out".into()) {
                            return Flow::Exit;
                        }
                    }
                }
                Err(e) => {
                    self.converting = None;
                    if let Flow::Exit = self.conversion_failed(e) {
                        return Flow::Exit;
                    }
                }
            }
        }
        // The encode in flight: its result, the watchdog, a hung encoder.
        if self.encoding.is_some() {
            if let Some(result) = self.gpu.poll_encode(enc_wait) {
                let job = self.encoding.take().expect("encoding");
                if let Flow::Exit = self.finished(job, result) {
                    return Flow::Exit;
                }
            } else if let Some(job) = &mut self.encoding {
                let now = lain_platform::clock::now_ns();
                if !job.timed_out && now.saturating_sub(job.requested_ns) >= ms(self.cfg.watchdog) {
                    job.timed_out = true;
                    let (frame_id, idr) = (job.request.frame_id, job.idr);
                    tracing::debug!(frame_id, "the encoder yielded nothing in time");
                    self.emit(VideoEvent::EncodeFailed { frame_id });
                    self.stats.failed += 1;
                    if let Flow::Exit = self.encode_failed(idr, "no access unit in time") {
                        return Flow::Exit;
                    }
                }
                if let Some(job) = &self.encoding
                    && now.saturating_sub(job.submit_ns) >= ms(self.cfg.hung)
                {
                    tracing::warn!("the encoder hung; rebuilding it");
                    let job = self.encoding.take().expect("encoding");
                    if !job.timed_out {
                        // Only if `hung` ≤ `watchdog` (EngineConfig is public): the request still gets its one
                        // result.
                        self.emit(VideoEvent::EncodeFailed { frame_id: job.request.frame_id });
                        self.stats.failed += 1;
                    }
                    if let Flow::Exit = self.rebuild("the encoder hung".into()) {
                        return Flow::Exit;
                    }
                }
            }
        }
        // Requests waiting behind a hung encode get their watchdog too.
        if self.encoding.is_some() {
            let now = lain_platform::clock::now_ns();
            while let Some(&(request, at)) = self.requests.front()
                && now.saturating_sub(at) >= ms(self.cfg.watchdog)
            {
                self.requests.pop_front();
                self.emit(VideoEvent::EncodeFailed { frame_id: request.frame_id });
                self.stats.failed += 1;
            }
            return Flow::Go;
        }
        // The next request, when the encoder is free.
        while self.encoding.is_none()
            && let Some((request, at)) = self.requests.pop_front()
        {
            if let Some(bitrate) = request.bitrate {
                self.gpu.set_bitrate(bitrate);
            }
            let Some(newest) = self.newest else {
                self.emit(VideoEvent::EncodeFailed { frame_id: request.frame_id });
                self.stats.failed += 1;
                continue;
            };
            let idr = request.keyframe || self.need_idr;
            let kind = PictureKind { idr, refinement: request.refinement };
            let submit_ns = lain_platform::clock::now_ns();
            match self.gpu.submit_encode(newest.surface, kind) {
                Ok(()) => {
                    self.encoding = Some(InFlight {
                        request,
                        requested_ns: at,
                        surface: newest.surface,
                        capture: newest,
                        submit_ns,
                        idr,
                        timed_out: false,
                    });
                }
                Err(e) => {
                    tracing::debug!(frame_id = request.frame_id, "submitting the encode failed: {e}");
                    self.emit(VideoEvent::EncodeFailed { frame_id: request.frame_id });
                    self.stats.failed += 1;
                    if let Flow::Exit = self.encode_failed(idr, &e) {
                        return Flow::Exit;
                    }
                }
            }
        }
        Flow::Go
    }

    fn finished(&mut self, job: InFlight, result: Result<Vec<u8>, String>) -> Flow {
        if job.timed_out {
            // Answered by the watchdog already; whatever came out is dropped (the next picture is an IDR).
            return Flow::Go;
        }
        let frame_id = job.request.frame_id;
        let checked = result.and_then(|annexb| crate::au::validate(&annexb, job.idr).map(|s| (annexb, s)));
        match checked {
            Ok((annexb, summary)) => {
                if summary.keyframe {
                    self.need_idr = false;
                    self.failed_idrs = 0;
                    self.rebuilds = 0;
                }
                self.stats.encoded += 1;
                self.emit(VideoEvent::Encoded(EncodedFrame {
                    frame_id,
                    capture: job.capture.capture,
                    capture_ns: job.capture.capture_ns,
                    submit_ns: job.submit_ns,
                    encode_done_ns: lain_platform::clock::now_ns(),
                    keyframe: summary.keyframe,
                    annexb,
                }));
                Flow::Go
            }
            Err(why) => {
                tracing::debug!(frame_id, idr = job.idr, "the encode produced no usable access unit: {why}");
                self.emit(VideoEvent::EncodeFailed { frame_id });
                self.stats.failed += 1;
                self.encode_failed(job.idr, &why)
            }
        }
    }

    /// After a failed picture (`why`): the next one is an IDR, and failed IDRs escalate to a rebuild, whose
    /// reason (and so a fatal end's) carries the last failure.
    fn encode_failed(&mut self, idr: bool, why: &str) -> Flow {
        self.need_idr = true;
        if idr {
            self.failed_idrs += 1;
            if self.failed_idrs >= self.cfg.idr_failures_before_rebuild {
                if let Some(job) = &mut self.encoding {
                    // The hung picture goes with the old session.
                    job.timed_out = true;
                }
                self.encoding = None;
                return self.rebuild(format!("{} IDRs failed in a row, the last: {why}", self.failed_idrs));
            }
        }
        Flow::Go
    }

    fn rebuild(&mut self, why: String) -> Flow {
        self.rebuilds += 1;
        self.stats.rebuilds += 1;
        self.failed_idrs = 0;
        self.need_idr = true;
        if self.rebuilds > self.cfg.max_rebuilds {
            return self.fatal(format!("the encoder keeps failing ({why}; {} rebuilds)", self.rebuilds - 1));
        }
        tracing::info!("rebuilding the encoder session: {why}");
        match self.gpu.rebuild_encoder() {
            Ok(()) => Flow::Go,
            Err(e) => self.fatal(format!("rebuilding the encoder failed: {e}")),
        }
    }

    /// Sleeps until the inbox changes (at most 10 ms, for the end checks), when nothing is in flight.
    fn wait(&mut self) {
        if self.converting.is_some() || self.encoding.is_some() {
            return; // advance() waited on the GPU already
        }
        let s = lock(&self.inbox.state);
        let idle = !s.stop
            && s.requests.is_empty()
            && (s.frame.is_none() || self.capture_stopped)
            && s.capture_end.is_some() == self.capture_end.is_some();
        if idle {
            let _ = self.inbox.wake.wait_timeout(s, Duration::from_millis(10));
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::frame::Pixels;
    use std::collections::HashMap;
    use std::time::Instant;

    /// How the fake encoder answers one submit.
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub(crate) enum Outcome {
        /// A valid access unit (an IDR with its parameter sets, or a P-frame).
        Good,
        /// Bytes with no start code (spike A's corrupt `vah265enc` output).
        Garbage,
        /// A P-frame whatever was asked.
        PFrame,
        /// Nothing until the test releases it.
        Hang,
        /// The submit itself fails.
        SubmitError,
        /// The encode reports an error.
        EncodeError,
    }

    #[derive(Debug, Default)]
    pub(crate) struct FakeState {
        /// Every `set_bitrate`, in order.
        pub(crate) bitrates: Vec<u32>,
        /// Each surface's content: the marker of the picture last converted into it.
        pub(crate) surfaces: HashMap<usize, u8>,
        pub(crate) conversions: Vec<(u8, usize)>,
        pub(crate) converting: Option<(u8, usize)>,
        pub(crate) conversion_pending: bool,
        pub(crate) fail_conversions: bool,
        /// A failed start leaves its conversion behind, as `GlConverter::convert` once kept its fence after a
        /// GL error: only `cancel_conversion` clears it.
        pub(crate) failed_start_lingers: bool,
        pub(crate) submits: Vec<(usize, PictureKind, u8)>,
        pub(crate) outcomes: VecDeque<Outcome>,
        pub(crate) in_flight: Option<(PictureKind, u8, Outcome)>,
        pub(crate) release_hang: bool,
        pub(crate) rebuilds: u32,
        pub(crate) fail_rebuild: bool,
    }

    /// The fake GPU: conversions copy the picture's marker (its first byte) into the surface; encodes answer per
    /// the scripted outcomes (default `Good`) with the surface's marker in the slice.
    #[derive(Clone, Default)]
    pub(crate) struct FakeGpu(pub(crate) Arc<Mutex<FakeState>>);

    impl FakeGpu {
        pub(crate) fn state(&self) -> MutexGuard<'_, FakeState> {
            lock(&self.0)
        }
    }

    pub(crate) fn fake_au(idr: bool, marker: u8) -> Vec<u8> {
        let mut out = Vec::new();
        if idr {
            for t in [32u8, 33, 34] {
                out.extend([0, 0, 0, 1, t << 1, 1, 0xA0 | t]);
            }
        }
        out.extend([0, 0, 0, 1, if idr { 19 << 1 } else { 1 << 1 }, 1, marker.max(1)]);
        out
    }

    impl Gpu for FakeGpu {
        fn surfaces(&self) -> usize {
            4
        }

        fn start_conversion(&mut self, picture: &Picture, surface: usize) -> Result<(), String> {
            let mut s = self.state();
            assert!(s.converting.is_none(), "one conversion at a time");
            if s.fail_conversions {
                if s.failed_start_lingers {
                    s.converting = Some((data_marker(picture), surface));
                }
                return Err("import refused".into());
            }
            let Pixels::Memory { data, .. } = &picture.pixels else { panic!("fake pictures are in memory") };
            s.converting = Some((data[0], surface));
            Ok(())
        }

        fn poll_conversion(&mut self, timeout_ns: u64) -> Result<bool, String> {
            let mut s = self.state();
            let Some((marker, surface)) = s.converting else { return Ok(true) };
            if s.conversion_pending {
                drop(s);
                std::thread::sleep(Duration::from_nanos(timeout_ns.min(1_000_000)));
                return Ok(false);
            }
            s.surfaces.insert(surface, marker);
            s.conversions.push((marker, surface));
            s.converting = None;
            Ok(true)
        }

        fn cancel_conversion(&mut self) {
            self.state().converting = None;
        }

        fn submit_encode(&mut self, surface: usize, kind: PictureKind) -> Result<(), String> {
            let mut s = self.state();
            assert!(s.in_flight.is_none(), "one encode at a time");
            assert!(s.converting.is_none_or(|(_, c)| c != surface), "never encode the surface being converted");
            let marker = *s.surfaces.get(&surface).expect("a converted surface");
            let outcome = s.outcomes.pop_front().unwrap_or(Outcome::Good);
            s.submits.push((surface, kind, marker));
            if outcome == Outcome::SubmitError {
                return Err("vaBeginPicture: invalid".into());
            }
            s.in_flight = Some((kind, marker, outcome));
            Ok(())
        }

        fn poll_encode(&mut self, timeout_ns: u64) -> Option<Result<Vec<u8>, String>> {
            let mut s = self.state();
            let (kind, marker, outcome) = s.in_flight?;
            if outcome == Outcome::Hang && !s.release_hang {
                drop(s);
                std::thread::sleep(Duration::from_nanos(timeout_ns.min(1_000_000)));
                return None;
            }
            s.in_flight = None;
            Some(match outcome {
                Outcome::Good | Outcome::Hang => Ok(fake_au(kind.idr, marker)),
                Outcome::Garbage => Ok(vec![0x26, 0x01, 0xAF, marker]),
                Outcome::PFrame => Ok(fake_au(false, marker)),
                Outcome::EncodeError => Err("vaSyncBuffer: operation failed".into()),
                Outcome::SubmitError => unreachable!(),
            })
        }

        fn set_bitrate(&mut self, bits_per_second: u32) {
            self.state().bitrates.push(bits_per_second);
        }

        fn rebuild_encoder(&mut self) -> Result<(), String> {
            let mut s = self.state();
            s.rebuilds += 1;
            s.in_flight = None;
            if s.fail_rebuild { Err("vaCreateContext: allocation failed".into()) } else { Ok(()) }
        }
    }

    fn data_marker(picture: &Picture) -> u8 {
        let Pixels::Memory { data, .. } = &picture.pixels else { panic!("fake pictures are in memory") };
        data[0]
    }

    pub(crate) fn picture(marker: u8) -> Picture {
        Picture { width: 2, height: 2, pixels: Pixels::Memory { data: vec![marker; 16], stride: 8 } }
    }

    /// A running engine on a fake GPU, with its inbox, events and end watch.
    pub(crate) struct Harness {
        pub(crate) gpu: FakeGpu,
        pub(crate) inbox: Arc<Inbox>,
        pub(crate) events: mpsc::UnboundedReceiver<VideoEvent>,
        pub(crate) ended: watch::Sender<Option<DisplayEnd>>,
        pub(crate) capture_stops: Arc<Mutex<u32>>,
        thread: Option<std::thread::JoinHandle<()>>,
    }

    pub(crate) fn fast_config() -> EngineConfig {
        EngineConfig {
            watchdog: Duration::from_millis(60),
            hung: Duration::from_millis(300),
            conversion_timeout: Duration::from_millis(100),
            end_grace: Duration::from_millis(100),
            ..EngineConfig::default()
        }
    }

    impl Harness {
        pub(crate) fn new(cfg: EngineConfig) -> Self {
            let gpu = FakeGpu::default();
            let inbox = Inbox::new();
            let (tx, events) = mpsc::unbounded_channel();
            let (ended, ended_rx) = watch::channel(None);
            let capture_stops = Arc::new(Mutex::new(0));
            let stops = capture_stops.clone();
            let engine =
                Engine::new(gpu.clone(), cfg, inbox.clone(), tx, ended_rx, Box::new(move || *lock(&stops) += 1));
            let thread = Some(std::thread::spawn(move || engine.run()));
            Self { gpu, inbox, events, ended, capture_stops, thread }
        }

        pub(crate) fn frame(&self, marker: u8) -> Arc<Mutex<bool>> {
            let returned = Arc::new(Mutex::new(false));
            let r = returned.clone();
            let ts = 1_000 * u64::from(marker);
            self.inbox.push_frame(CaptureFrame::new(picture(marker), ts, Some(Box::new(move || *lock(&r) = true))));
            returned
        }

        pub(crate) fn request(&self, frame_id: u32, keyframe: bool, refinement: bool) {
            self.inbox.push_request(EncodeRequest { frame_id, keyframe, refinement, bitrate: None });
        }

        pub(crate) fn request_at(&self, frame_id: u32, bitrate: u32) {
            self.inbox.push_request(EncodeRequest {
                frame_id,
                keyframe: false,
                refinement: false,
                bitrate: Some(bitrate),
            });
        }

        /// The next event, within 2 s.
        pub(crate) fn next(&mut self) -> Option<VideoEvent> {
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                match self.events.try_recv() {
                    Ok(e) => return Some(e),
                    Err(mpsc::error::TryRecvError::Disconnected) => return None,
                    Err(mpsc::error::TryRecvError::Empty) if Instant::now() > deadline => panic!("no event within 2 s"),
                    Err(_) => std::thread::sleep(Duration::from_millis(1)),
                }
            }
        }

        pub(crate) fn captured(&mut self) -> u64 {
            match self.next() {
                Some(VideoEvent::Captured { capture, .. }) => capture,
                other => panic!("expected Captured, got {other:?}"),
            }
        }

        pub(crate) fn encoded(&mut self) -> EncodedFrame {
            match self.next() {
                Some(VideoEvent::Encoded(f)) => f,
                other => panic!("expected Encoded, got {other:?}"),
            }
        }

        pub(crate) fn failed(&mut self) -> u32 {
            match self.next() {
                Some(VideoEvent::EncodeFailed { frame_id }) => frame_id,
                other => panic!("expected EncodeFailed, got {other:?}"),
            }
        }

        /// Nothing more within `ms`.
        pub(crate) fn quiet(&mut self, ms: u64) {
            std::thread::sleep(Duration::from_millis(ms));
            if let Ok(e) = self.events.try_recv() {
                panic!("unexpected {e:?}");
            }
        }

        pub(crate) fn stop(&mut self) {
            self.inbox.stop();
            if let Some(t) = self.thread.take() {
                t.join().unwrap();
            }
        }
    }

    impl Drop for Harness {
        fn drop(&mut self) {
            self.stop();
        }
    }

    fn marker_of(f: &EncodedFrame) -> u8 {
        *f.annexb.last().unwrap()
    }

    #[test]
    fn encode_before_the_first_capture_fails() {
        let mut h = Harness::new(fast_config());
        h.request(1, true, false);
        assert_eq!(h.failed(), 1);
        h.request(2, false, false);
        assert_eq!(h.failed(), 2);
        assert!(h.gpu.state().submits.is_empty());
    }

    #[test]
    fn captures_are_announced_once_converted_and_buffers_go_back() {
        let mut h = Harness::new(fast_config());
        let returned = h.frame(7);
        assert_eq!(h.captured(), 1);
        assert!(*lock(&returned), "the PipeWire buffer goes back once converted");
        h.request(1, true, false);
        let f = h.encoded();
        assert_eq!((f.frame_id, f.capture, f.capture_ns, f.keyframe), (1, 1, 7_000, true));
        assert_eq!(marker_of(&f), 7);
        assert!(f.submit_ns <= f.encode_done_ns);
        crate::au::validate(&f.annexb, true).unwrap();
    }

    #[test]
    fn the_first_picture_is_an_idr_and_then_p_frames() {
        let mut h = Harness::new(fast_config());
        h.frame(1);
        h.captured();
        h.request(1, false, false);
        assert!(h.encoded().keyframe, "a session starts with an IDR even if the core asks for a P-frame");
        h.frame(2);
        h.captured();
        h.request(2, false, false);
        let f = h.encoded();
        assert!(!f.keyframe);
        assert_eq!((f.capture, marker_of(&f)), (2, 2));
        let kinds: Vec<bool> = h.gpu.state().submits.iter().map(|s| s.1.idr).collect();
        assert_eq!(kinds, [true, false]);
    }

    #[test]
    fn the_newest_capture_is_kept_for_keyframes_and_refinements() {
        let mut h = Harness::new(fast_config());
        h.frame(3);
        h.captured();
        h.request(1, false, false);
        h.encoded();
        // Idle desktop: nothing new. A keyframe and a refinement re-encode capture 1.
        h.request(2, true, false);
        let k = h.encoded();
        assert_eq!((k.capture, k.keyframe, marker_of(&k)), (1, true, 3));
        h.request(3, false, true);
        let r = h.encoded();
        assert_eq!((r.capture, r.keyframe, marker_of(&r)), (1, false, 3));
        let submits = h.gpu.state().submits.clone();
        assert_eq!(submits[2].1, PictureKind { idr: false, refinement: true });
        assert!(submits.iter().all(|s| s.0 == submits[0].0), "the same surface every time");
    }

    /// A request's new bitrate reaches the encoder before its picture; a request without one leaves it.
    #[test]
    fn a_request_carries_the_bitrate_to_the_encoder() {
        let mut h = Harness::new(fast_config());
        h.frame(3);
        h.captured();
        h.request_at(1, 20_000_000);
        h.encoded();
        h.request(2, false, false);
        h.encoded();
        assert_eq!(h.gpu.state().bitrates, [20_000_000]);
    }

    #[test]
    fn latest_wins_and_an_encode_never_takes_an_older_capture() {
        let mut h = Harness::new(fast_config());
        // Hold the first conversion so two more pictures arrive behind it: only the newest survives.
        h.gpu.state().conversion_pending = true;
        let first = h.frame(1);
        std::thread::sleep(Duration::from_millis(20));
        let second = h.frame(2);
        let third = h.frame(3);
        assert!(*lock(&second), "the replaced picture goes back unconverted");
        assert!(!*lock(&third) && !*lock(&first));
        h.gpu.state().conversion_pending = false;
        assert_eq!(h.captured(), 1);
        assert_eq!(h.captured(), 2);
        h.request(1, false, false);
        let f = h.encoded();
        assert_eq!((f.capture, marker_of(&f)), (2, 3), "capture 2 is picture 3");
        assert_eq!(h.inbox.stats().replaced, 1);
        // A conversion in flight never touches the surface being encoded or the newest one.
        let conversions = h.gpu.state().conversions.clone();
        assert_ne!(conversions[0].1, conversions[1].1);
    }

    #[test]
    fn conversion_runs_ahead_of_the_encoder_into_another_surface() {
        let mut h = Harness::new(fast_config());
        h.frame(1);
        h.captured();
        h.gpu.state().outcomes.push_back(Outcome::Hang);
        h.request(1, true, false);
        // While capture 1 encodes, picture 2 converts into a third surface and becomes the newest.
        std::thread::sleep(Duration::from_millis(5));
        h.frame(2);
        assert_eq!(h.captured(), 2);
        h.gpu.state().release_hang = true;
        let f = h.encoded();
        assert_eq!((f.frame_id, f.capture, marker_of(&f)), (1, 1, 1), "the encode in flight keeps its capture");
        h.request(2, false, false);
        let g = h.encoded();
        assert_eq!((g.capture, marker_of(&g)), (2, 2));
        let s = h.gpu.state();
        assert_ne!(s.submits[0].0, s.submits[1].0);
    }

    #[test]
    fn a_bad_access_unit_fails_and_forces_an_idr() {
        let mut h = Harness::new(fast_config());
        h.frame(1);
        h.captured();
        h.request(1, true, false);
        h.encoded();
        h.gpu.state().outcomes.push_back(Outcome::Garbage);
        h.request(2, false, false);
        assert_eq!(h.failed(), 2);
        h.request(3, false, false);
        let f = h.encoded();
        assert!(f.keyframe, "after a lost picture the next one is an IDR, though the core asked for a P-frame");
        h.request(4, false, false);
        assert!(!h.encoded().keyframe);
    }

    #[test]
    fn a_p_frame_for_a_requested_idr_is_a_failure() {
        let mut h = Harness::new(fast_config());
        h.frame(1);
        h.captured();
        h.gpu.state().outcomes.push_back(Outcome::PFrame);
        h.request(1, true, false);
        assert_eq!(h.failed(), 1);
        h.request(2, true, false);
        assert!(h.encoded().keyframe);
        assert_eq!(h.gpu.state().rebuilds, 0, "one failed IDR doesn't rebuild");
    }

    #[test]
    fn failing_idrs_rebuild_the_encoder_then_fail_the_session() {
        let mut h = Harness::new(fast_config());
        h.frame(1);
        h.captured();
        h.gpu.state().outcomes.extend([Outcome::Garbage, Outcome::EncodeError]);
        h.request(1, true, false);
        assert_eq!(h.failed(), 1);
        h.request(2, true, false);
        assert_eq!(h.failed(), 2);
        assert_eq!(h.gpu.state().rebuilds, 1, "two failed IDRs in a row rebuild the session");
        h.request(3, true, false);
        assert!(h.encoded().keyframe, "the rebuilt session recovers");

        // Now every IDR fails: rebuild after every second one, three times, then Failed.
        h.gpu.state().outcomes.extend([Outcome::Garbage; 8]);
        let mut id = 10;
        let end = loop {
            h.request(id, true, false);
            match h.next() {
                Some(VideoEvent::EncodeFailed { frame_id }) => assert_eq!(frame_id, id),
                Some(VideoEvent::Failed(e)) => break e,
                other => panic!("{other:?}"),
            }
            id += 1;
        };
        assert!(end.to_string().contains("keeps failing"), "{end}");
        assert!(end.to_string().contains("IDRs failed in a row, the last: "), "the reason is kept: {end}");
        assert_eq!(h.next(), None, "nothing follows Failed");
        assert_eq!(h.gpu.state().rebuilds, 1 + 3);
        assert_eq!(*lock(&h.capture_stops), 1, "capture is stopped");
    }

    #[test]
    fn a_failed_rebuild_fails_the_session() {
        let mut h = Harness::new(fast_config());
        h.frame(1);
        h.captured();
        h.gpu.state().fail_rebuild = true;
        h.gpu.state().outcomes.extend([Outcome::SubmitError, Outcome::SubmitError]);
        h.request(1, true, false);
        assert_eq!(h.failed(), 1);
        h.request(2, true, false);
        assert_eq!(h.failed(), 2);
        assert!(matches!(h.next(), Some(VideoEvent::Failed(e)) if e.to_string().contains("rebuilding")));
        assert_eq!(h.next(), None);
    }

    #[test]
    fn the_watchdog_answers_a_hung_encode_and_drops_its_late_result() {
        let mut h = Harness::new(fast_config());
        h.frame(1);
        h.captured();
        h.request(1, true, false);
        h.encoded();
        h.gpu.state().outcomes.push_back(Outcome::Hang);
        let asked = Instant::now();
        h.request(2, false, false);
        assert_eq!(h.failed(), 2);
        let waited = asked.elapsed();
        assert!(waited >= Duration::from_millis(55) && waited < Duration::from_millis(500), "{waited:?}");
        // The late AU is dropped; the next request waits for the encoder, then is an IDR.
        h.gpu.state().release_hang = true;
        h.request(3, false, false);
        let f = h.encoded();
        assert_eq!(f.frame_id, 3);
        assert!(f.keyframe);
        h.quiet(30);
    }

    #[test]
    fn a_hung_encoder_is_rebuilt_and_requests_behind_it_are_answered() {
        let mut h = Harness::new(fast_config());
        h.frame(1);
        h.captured();
        h.gpu.state().outcomes.push_back(Outcome::Hang);
        h.request(1, true, false);
        assert_eq!(h.failed(), 1);
        h.request(2, true, false);
        assert_eq!(h.failed(), 2, "a request queued behind the hung encode gets its own watchdog");
        // Past `hung` the encoder is rebuilt, and the next request is served.
        std::thread::sleep(Duration::from_millis(350));
        assert!(h.gpu.state().rebuilds >= 1);
        h.request(3, true, false);
        assert!(h.encoded().keyframe);
    }

    #[test]
    fn one_result_per_request_in_order() {
        let mut h = Harness::new(fast_config());
        h.frame(1);
        h.captured();
        h.gpu.state().outcomes.extend([
            Outcome::Good,
            Outcome::Garbage,
            Outcome::Good,
            Outcome::SubmitError,
            Outcome::Good,
        ]);
        // Several at once (a contract violation the core never commits, still answered in order).
        for id in 1..=5 {
            h.request(id, false, false);
        }
        let mut ids = Vec::new();
        for _ in 0..5 {
            match h.next() {
                Some(VideoEvent::Encoded(f)) => ids.push((f.frame_id, true)),
                Some(VideoEvent::EncodeFailed { frame_id }) => ids.push((frame_id, false)),
                other => panic!("{other:?}"),
            }
        }
        assert_eq!(ids, [(1, true), (2, false), (3, true), (4, false), (5, true)]);
        h.quiet(20);
    }

    #[test]
    fn conversion_failures_skip_pictures_then_fail() {
        let mut h = Harness::new(fast_config());
        h.gpu.state().fail_conversions = true;
        for m in 1..=4 {
            let back = h.frame(m);
            std::thread::sleep(Duration::from_millis(15));
            assert!(*lock(&back), "a picture that can't be converted goes back");
        }
        h.quiet(10);
        h.gpu.state().fail_conversions = false;
        h.frame(9);
        assert_eq!(h.captured(), 1, "a failed picture is never announced");
        h.gpu.state().fail_conversions = true;
        for m in 10..=14 {
            h.frame(m);
            std::thread::sleep(Duration::from_millis(15));
        }
        assert!(matches!(h.next(), Some(VideoEvent::Failed(e)) if e.to_string().contains("can't be converted")));
        assert_eq!(h.next(), None);
    }

    #[test]
    fn a_failed_conversion_start_doesn_t_wedge_the_next() {
        let mut h = Harness::new(fast_config());
        {
            let mut s = h.gpu.state();
            s.fail_conversions = true;
            s.failed_start_lingers = true;
        }
        let back = h.frame(1);
        std::thread::sleep(Duration::from_millis(20));
        assert!(*lock(&back));
        h.gpu.state().fail_conversions = false;
        h.frame(2);
        assert_eq!(h.captured(), 1, "the next picture converts");
        h.request(1, true, false);
        assert_eq!(marker_of(&h.encoded()), 2);
    }

    #[test]
    fn a_hung_encode_is_answered_whatever_the_bounds() {
        // `hung` below `watchdog`: the rebuild comes first, and still answers the request.
        let cfg =
            EngineConfig { watchdog: Duration::from_millis(400), hung: Duration::from_millis(100), ..fast_config() };
        let mut h = Harness::new(cfg);
        h.frame(1);
        h.captured();
        h.gpu.state().outcomes.push_back(Outcome::Hang);
        h.request(1, true, false);
        assert_eq!(h.failed(), 1);
        assert_eq!(h.gpu.state().rebuilds, 1);
        h.quiet(500);
        h.request(2, false, false);
        assert!(h.encoded().keyframe, "the rebuilt encoder starts with an IDR");
    }

    #[test]
    fn a_self_ended_engine_returns_late_pictures_and_refuses_requests() {
        let mut h = Harness::new(fast_config());
        h.ended.send_replace(Some(DisplayEnd::StoppedByUser));
        assert_eq!(h.next(), Some(VideoEvent::StoppedByUser));
        assert_eq!(h.next(), None);
        h.thread.take().unwrap().join().unwrap(); // the engine has ended by itself; nobody called stop
        let back = h.frame(9);
        assert!(*lock(&back), "a picture pushed after the end goes straight back");
        h.request(1, false, false);
        assert!(lock(&h.inbox.state).requests.is_empty(), "nobody would answer it");
        assert_eq!(h.inbox.stats().delivered, 0);
    }

    #[test]
    fn a_stuck_conversion_times_out() {
        let mut h = Harness::new(fast_config());
        h.gpu.state().conversion_pending = true;
        h.frame(1);
        std::thread::sleep(Duration::from_millis(150));
        h.gpu.state().conversion_pending = false;
        assert!(h.gpu.state().converting.is_none(), "cancelled");
        h.frame(2);
        h.captured();
        h.request(1, true, false);
        assert_eq!(marker_of(&h.encoded()), 2);
    }

    #[test]
    fn end_reasons() {
        let mut h = Harness::new(fast_config());
        h.ended.send_replace(Some(DisplayEnd::StoppedByUser));
        assert_eq!(h.next(), Some(VideoEvent::StoppedByUser));
        assert_eq!(h.next(), None);

        let mut h = Harness::new(fast_config());
        h.ended.send_replace(Some(DisplayEnd::Failed("gnome-shell left the bus".into())));
        assert!(matches!(h.next(), Some(VideoEvent::Failed(PlatformError::Failed(m))) if m.contains("gnome-shell")));
        assert_eq!(h.next(), None);

        // Destroyed: capture stops, nothing is reported, the kept capture still answers.
        let mut h = Harness::new(fast_config());
        h.frame(5);
        h.captured();
        h.ended.send_replace(Some(DisplayEnd::Destroyed));
        h.quiet(30);
        assert_eq!(*lock(&h.capture_stops), 1);
        let late = h.frame(6);
        std::thread::sleep(Duration::from_millis(20));
        assert!(h.gpu.state().conversions.len() == 1, "no capture after Destroyed");
        h.request(1, true, false);
        assert_eq!(marker_of(&h.encoded()), 5);
        h.stop();
        assert!(*lock(&late), "the picture still goes back");
    }

    #[test]
    fn a_stream_end_waits_for_the_display_s_reason() {
        // The display's reason arrives within the grace: it wins.
        let mut h = Harness::new(fast_config());
        h.inbox.capture_ended("stream unconnected".into());
        std::thread::sleep(Duration::from_millis(20));
        h.ended.send_replace(Some(DisplayEnd::StoppedByUser));
        assert_eq!(h.next(), Some(VideoEvent::StoppedByUser));
        // No reason within the grace: Failed.
        let mut h = Harness::new(fast_config());
        h.inbox.capture_ended("PipeWire stream error: no target node".into());
        let t = Instant::now();
        assert!(matches!(h.next(), Some(VideoEvent::Failed(e)) if e.to_string().contains("no target node")));
        assert!(t.elapsed() >= Duration::from_millis(90));
        // After Destroyed a stream end is expected and says nothing.
        let mut h = Harness::new(fast_config());
        h.ended.send_replace(Some(DisplayEnd::Destroyed));
        h.inbox.capture_ended("stream unconnected".into());
        h.quiet(200);
    }

    #[test]
    fn stop_ends_everything() {
        let mut h = Harness::new(fast_config());
        h.frame(1);
        h.captured();
        h.gpu.state().outcomes.push_back(Outcome::Hang);
        h.request(1, false, false);
        h.stop();
        assert_eq!(h.next(), None, "no event after stop");
        h.request(2, false, false);
        assert_eq!(*lock(&h.capture_stops), 1);
    }
}
