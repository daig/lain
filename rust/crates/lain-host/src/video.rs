//! One session's video: the virtual display's lifecycle around `lain-media`'s pipeline (Swift:
//! `LainHostCore/Video/HostVideoPipeline.swift`'s `start`, `stop` and `waitUntilStopped`; the encode path
//! itself is `lain_media::VideoPipeline`).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use lain_link::ChannelSender;
use lain_media::{Connection, CursorMonitor, HostVideoStats, Outbound, PipelineOptions, VideoEnd, VideoPipeline};
use lain_platform::{
    Clock, DisplayBackend, DisplaySpec, Platform, PlatformError, StreamedDisplay, VideoBackend, VideoEvent,
};
use lain_proto::{ChromaFormat, Hello, Message};
use tokio::sync::{Notify, mpsc, watch};
use tracing::{error, info};

use crate::keeper::DisplayKeeper;
use crate::util::Cancel;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The display a client's `Hello` asks for: its pixel size (long side first), the scale it chose (v7), and its
/// maximum refresh rate (0: 120 Hz). Swift: `VirtualDisplay.Spec.sized(pixelWidth:pixelHeight:)` and
/// `DisplayScaleChoice`.
///
/// - **The size** is the client's own: the 13-inch iPad Pro's 2752×2064, or another shape (an iPhone Duo asks
///   for its inner display, 2853×2007). A size that makes no display (nothing, absurd, or portrait) falls back
///   to the iPad's, as in Swift. An odd side is rounded down to even, since 4:2:0 video needs even sides.
/// - **The scale** the client chose (`Hello.desired_scale`), brought to the nearest of [`OFFERED_SCALES`] (on a
///   tie, the larger, as in Swift); none chosen (a v6 client), 2, which the owner's `scale` setting replaces in
///   `lain-gnome`, as the Mac host's own scale.
/// - **Intended difference from Swift, from Mutter:** Mutter applies a scale n/d only if it divides both sides
///   exactly (Mutter 50.1 `for_each_scale`), and lain's video doesn't scale, where the Mac renders at 2× and
///   capture scales. So a chosen scale makes the display a few pixels smaller where needed: the largest even
///   size within the client's whose sides that scale divides ([`size_for_scale`]); the Duo at 3× gets
///   2850×2004. The client fits the stream to its screen.
/// - Intended difference from Swift, whose Mac host is fixed at 120 Hz: the refresh rate follows the client.
pub fn display_spec(hello: &Hello) -> DisplaySpec {
    let (w, h) = (hello.pixel_width, hello.pixel_height);
    let (w, h) =
        if (640..=4096).contains(&w) && (480..=4096).contains(&h) && w >= h { (w & !1, h & !1) } else { IPAD_PIXELS };
    let desired_scale = choose_scale(hello.desired_scale);
    let (pixel_width, pixel_height) = size_for_scale(w, h, desired_scale);
    DisplaySpec {
        pixel_width,
        pixel_height,
        scale: 2,
        desired_scale,
        refresh_hz: if hello.max_refresh_rate == 0 { 120 } else { u32::from(hello.max_refresh_rate) },
    }
}

/// The scales a v7 client may choose (`HelloAck.displayScales`), in hundredths: every quarter from 1 to 3, as
/// far as the Mac host offers (it stops at 1.5 for its 2× backing store; GNOME renders at the panel's pixels and
/// has no such limit, and the owner's `scale` setting allows 1–3).
pub const OFFERED_SCALES: [u16; 9] = [100, 125, 150, 175, 200, 225, 250, 275, 300];

/// The offered scale nearest to `requested` (hundredths; on a tie the larger, as Swift's
/// `DisplayScaleChoice.choose`), or 0 for no request.
pub fn choose_scale(requested: u16) -> u16 {
    if requested == 0 {
        return 0;
    }
    OFFERED_SCALES.iter().copied().min_by_key(|&s| (s.abs_diff(requested), std::cmp::Reverse(s))).unwrap_or(0)
}

/// The largest even size within `w`×`h` whose sides `scale` (hundredths, a quarter) divides exactly, so that
/// Mutter can apply it: for n/d in lowest terms (d ≤ 4) both sides must be multiples of n. 0: unchanged.
pub fn size_for_scale(w: u32, h: u32, scale: u16) -> (u32, u32) {
    if scale == 0 {
        return (w, h);
    }
    let quarters = u32::from(scale) / 25;
    let numerator = quarters / gcd(quarters, 4);
    let step = numerator / gcd(numerator, 2) * 2; // lcm(numerator, 2)
    (w - w % step, h - h % step)
}

fn gcd(a: u32, b: u32) -> u32 {
    if b == 0 { a } else { gcd(b, a % b) }
}

/// The 13-inch iPad Pro's display, the one a size that makes no display falls back to (Swift: the default
/// `VirtualDisplay.Spec`).
pub const IPAD_PIXELS: (u32, u32) = (2752, 2064);

/// Why [`SessionVideo::start`] gave no video.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum StartError {
    /// `stop()` ran while starting (Swift: `HostVideoError.stopped`).
    Stopped,
    /// The display or the capture couldn't start; the session goes on input only.
    Failed(PlatformError),
}

/// What the stream is, once running.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Streaming {
    pub(crate) display: StreamedDisplay,
    pub(crate) chroma: ChromaFormat,
    pub(crate) bit_depth: u8,
}

#[derive(Debug, Default)]
struct Shared {
    streaming: Option<Streaming>,
    stats: Option<HostVideoStats>,
    commands: Option<mpsc::UnboundedSender<Message>>,
}

/// One session's video (Swift: `HostVideoPipeline`'s lifecycle): creates the virtual display from the
/// client's `Hello`, starts capture and encode on it, and drives a [`VideoPipeline`] and a [`CursorMonitor`]
/// in a task of its own until it is stopped or capture ends, then stops the capture and removes the display.
///
/// [`stop`](Self::stop) is synchronous: no new output starts once it returns (one message already past the
/// check may still go out); the capture stop and the display's removal finish in the background
/// ([`wait_until_stopped`](Self::wait_until_stopped)). A stop while the display is still being created drops
/// the creation, which the backend undoes (`create` is cancel-safe).
pub(crate) struct SessionVideo {
    stop: Cancel,
    /// No display made by this video exists (true before start and after teardown).
    done: watch::Sender<bool>,
    /// Messages may still go out.
    sending: Arc<AtomicBool>,
    shared: Mutex<Shared>,
    /// Told whenever the streamed display appears or goes, so the layout is re-sent.
    changed: Arc<Notify>,
}

impl SessionVideo {
    pub(crate) fn new(changed: Arc<Notify>) -> Arc<Self> {
        Arc::new(Self {
            stop: Cancel::new(),
            done: watch::Sender::new(true),
            sending: Arc::new(AtomicBool::new(true)),
            shared: Mutex::new(Shared::default()),
            changed,
        })
    }

    /// The stream while it runs (Swift: `streamedDisplay`, nil before and once stopped or failed).
    pub(crate) fn streaming(&self) -> Option<Streaming> {
        lock(&self.shared).streaming
    }

    pub(crate) fn stats(&self) -> Option<HostVideoStats> {
        let s = lock(&self.shared);
        s.streaming.and(s.stats.clone())
    }

    /// A `FrameAck` or `KeyframeRequest` from the client; dropped unless running.
    pub(crate) fn handle(&self, message: Message) {
        if let Some(commands) = &lock(&self.shared).commands {
            let _ = commands.send(message);
        }
    }

    /// Stops video: no new output starts once this returns (one message already past the check may still go
    /// out). Idempotent.
    pub(crate) fn stop(&self) {
        self.sending.store(false, Ordering::SeqCst);
        self.stop.cancel();
        let had = {
            let mut s = lock(&self.shared);
            s.commands = None;
            s.streaming.take().is_some()
        };
        if had {
            self.changed.notify_one();
        }
    }

    /// Returns once no display from this video exists, even if `stop` interrupted `start` (Swift:
    /// `waitUntilStopped`).
    pub(crate) async fn wait_until_stopped(&self) {
        let mut done = self.done.subscribe();
        let _ = done.wait_for(|d| *d).await;
    }

    /// Creates the display for `hello`, starts capture and encode, and streams on `video` (frames) and
    /// `realtime` (cursor shapes). Returns the chroma streamed and the bit depth. `on_end` is called once if
    /// capture ends on its own (`Failed` or `StoppedByUser`); the video is torn down after it.
    #[allow(clippy::too_many_arguments)] // the session's channels and callbacks, as before, plus the keeper
    pub(crate) async fn start<P: Platform>(
        self: &Arc<Self>,
        platform: &P,
        hello: &Hello,
        options: PipelineOptions,
        realtime: ChannelSender,
        video: ChannelSender,
        on_end: impl FnOnce(VideoEnd) + Send + 'static,
        keeper: &Arc<DisplayKeeper<P::Display>>,
    ) -> Result<Streaming, StartError> {
        // Marked started before the stop check: a waiter that saw `done` had the stop come first, and the check
        // then sees it, so no display is made after `wait_until_stopped` returned.
        self.done.send_replace(false);
        if self.stop.is_cancelled() {
            self.done.send_replace(true);
            return Err(StartError::Stopped);
        }
        let result = self.start_inner(platform, hello, options, realtime, video, on_end, keeper).await;
        if result.is_err() {
            self.done.send_replace(true);
        }
        result
    }

    #[allow(clippy::too_many_arguments)] // the session's channels and callbacks, as before, plus the keeper
    async fn start_inner<P: Platform>(
        self: &Arc<Self>,
        platform: &P,
        hello: &Hello,
        options: PipelineOptions,
        realtime: ChannelSender,
        video: ChannelSender,
        on_end: impl FnOnce(VideoEnd) + Send + 'static,
        keeper: &Arc<DisplayKeeper<P::Display>>,
    ) -> Result<Streaming, StartError> {
        let display = platform.display().clone();
        let spec = display_spec(hello);
        // A display kept from the last session is taken back first (keeper.rs); one that no longer captures
        // (stopped on the desktop while kept) is removed and a new one created.
        let mut kept = keeper.take(spec).await;
        let (streamed, source, session, mut events) = loop {
            let reused = kept.is_some();
            let (streamed, source) = match kept.take() {
                Some(display) => display,
                None => {
                    // `create` is cancel-safe: a stop meanwhile drops it, and the backend removes what it made.
                    let created = tokio::select! {
                        biased;
                        () = self.stop.cancelled() => return Err(StartError::Stopped),
                        created = display.create(spec) => created,
                    };
                    created.map_err(StartError::Failed)?
                }
            };
            if self.stop.is_cancelled() {
                display.destroy().await;
                return Err(StartError::Stopped);
            }
            let config = lain_media::encode_config(&streamed, hello.max_refresh_rate, &options);
            match platform.video().start(&source, config).await {
                Ok((session, events)) => break (streamed, source, session, events),
                Err(e) => {
                    display.destroy().await;
                    if !reused {
                        return Err(StartError::Failed(e));
                    }
                    info!("the kept display no longer captures ({e}); making a new one");
                }
            }
        };
        if self.stop.is_cancelled() {
            lain_platform::VideoSession::stop(&session).await;
            display.destroy().await;
            return Err(StartError::Stopped);
        }

        let sending = self.sending.clone();
        let out = {
            let sending = sending.clone();
            let realtime = realtime.clone();
            move |o: Outbound| {
                if !sending.load(Ordering::SeqCst) {
                    return;
                }
                let channel = match o.connection {
                    Connection::Realtime => &realtime,
                    Connection::Video => &video,
                };
                let _ = channel.send_with_flags(&o.message, Some(o.flags));
            }
        };
        let cursor_out = move |o: Outbound| {
            if sending.load(Ordering::SeqCst) {
                let _ = realtime.send_with_flags(&o.message, Some(o.flags));
            }
        };
        let clock = platform.clock().clone();
        let mut pipeline = VideoPipeline::new(session, clock.clone(), options, out);
        let mut cursor = CursorMonitor::new(
            platform.cursor().clone(),
            clock.clone(),
            CursorMonitor::<P::Cursor, P::Clock>::DEFAULT_HZ,
            cursor_out,
        );
        let info = pipeline.info();
        let streaming = Streaming { display: streamed, chroma: pipeline.chroma(), bit_depth: info.bit_depth };
        let (commands, mut commands_rx) = mpsc::unbounded_channel();
        // Installed under the lock `stop` takes, so a stop either sees it running or is seen here.
        let installed = {
            let mut s = lock(&self.shared);
            let go = !self.stop.is_cancelled();
            if go {
                s.streaming = Some(streaming);
                s.stats = Some(pipeline.stats());
                s.commands = Some(commands);
            }
            go
        };
        if !installed {
            pipeline.stop().await;
            display.destroy().await;
            return Err(StartError::Stopped);
        }
        info!(
            display = streamed.id,
            width = streamed.pixel_width,
            height = streamed.pixel_height,
            chroma = ?streaming.chroma,
            "video: streaming lain's display"
        );
        self.changed.notify_one();
        cursor.start();

        let this = self.clone();
        let keeper = keeper.clone();
        tokio::spawn(async move {
            let end = this.drive(&mut pipeline, &mut cursor, &mut events, &mut commands_rx, &clock).await;
            this.sending.store(false, Ordering::SeqCst);
            {
                let mut s = lock(&this.shared);
                s.streaming = None;
                s.commands = None;
            }
            let ended_on_its_own = end.is_some();
            if let Some(end) = end {
                on_end(end);
            }
            cursor.stop();
            pipeline.stop().await;
            // Stopped (the link went away, or a takeover): kept for the next session. Capture that ended on its
            // own (`StoppedByUser`, `Failed`) takes its display with it.
            if ended_on_its_own || !keeper.keep(spec, streamed, source).await {
                display.destroy().await;
            }
            this.done.send_replace(true);
            this.changed.notify_one();
            info!("video stopped");
        });
        Ok(streaming)
    }

    /// Runs the pipeline until a stop (`None`) or the end of capture.
    async fn drive<S, Src, C>(
        &self,
        pipeline: &mut VideoPipeline<S, C>,
        cursor: &mut CursorMonitor<Src, C>,
        events: &mut mpsc::UnboundedReceiver<VideoEvent>,
        commands: &mut mpsc::UnboundedReceiver<Message>,
        clock: &C,
    ) -> Option<VideoEnd>
    where
        S: lain_platform::VideoSession,
        Src: lain_platform::CursorSource,
        C: Clock,
    {
        let mut fired = false;
        loop {
            let deadline = [pipeline.next_deadline(), cursor.next_deadline()].into_iter().flatten().min();
            let wait = deadline.map(|d| {
                let ns = d.saturating_sub(clock.now_ns());
                // A timer that just fired and is still due did nothing: don't spin on it.
                Duration::from_nanos(if fired && ns == 0 { 1_000_000 } else { ns })
            });
            fired = false;
            tokio::select! {
                biased;
                () = self.stop.cancelled() => return None,
                event = events.recv() => match event {
                    Some(event) => {
                        if let Some(end) = pipeline.handle_event(event) {
                            return Some(end);
                        }
                    }
                    None => {
                        error!("the video session's events ended without a reason");
                        return Some(VideoEnd::Failed(PlatformError::Failed("video events ended".into())));
                    }
                },
                Some(message) = commands.recv() => {
                    pipeline.handle_message(&message);
                }
                () = sleep(wait), if wait.is_some() => {
                    fired = true;
                    pipeline.on_timer();
                    cursor.on_timer();
                }
            }
            lock(&self.shared).stats = Some(pipeline.stats());
        }
    }
}

async fn sleep(wait: Option<Duration>) {
    if let Some(wait) = wait {
        tokio::time::sleep(wait).await;
    }
}

#[cfg(test)]
mod spec_tests {
    use super::*;

    fn hello(w: u32, h: u32, scale: u8) -> Hello {
        Hello {
            device_model: "iPhone19,4".into(),
            pixel_width: w,
            pixel_height: h,
            scale,
            max_refresh_rate: 120,
            decode_capabilities: lain_proto::DecodeCapabilities::HEVC_MAIN,
            keyboard_type: lain_proto::KeyboardType::Unknown,
            desired_scale: 0,
        }
    }

    #[test]
    fn a_clients_request_shapes_its_display() {
        // An iPhone Duo asks for its inner display at 3×: even sides, at 2× (Swift: `aClientsRequestShapesItsDisplay`).
        let duo = display_spec(&hello(2853, 2007, 3));
        assert_eq!((duo.pixel_width, duo.pixel_height, duo.scale, duo.refresh_hz), (2852, 2006, 2, 120));
        assert_eq!(
            display_spec(&hello(2752, 2064, 2)),
            DisplaySpec { pixel_width: 2752, pixel_height: 2064, scale: 2, desired_scale: 0, refresh_hz: 120 }
        );
        // A size that makes no display: the iPad's.
        for (w, h) in [(0, 0), (2007, 2853), (100_000, 2000), (639, 480), (640, 479)] {
            let s = display_spec(&hello(w, h, 2));
            assert_eq!((s.pixel_width, s.pixel_height), IPAD_PIXELS, "{w}×{h}");
        }
        assert_eq!(display_spec(&Hello { max_refresh_rate: 0, ..hello(2752, 2064, 2) }).refresh_hz, 120);
    }

    #[test]
    fn a_chosen_scale_shapes_the_display_so_mutter_can_apply_it() {
        let duo = |scale| display_spec(&Hello { desired_scale: scale, ..hello(2853, 2007, 3) });
        assert_eq!((duo(300).pixel_width, duo(300).pixel_height, duo(300).desired_scale), (2850, 2004, 300));
        assert_eq!((duo(200).pixel_width, duo(200).pixel_height), (2852, 2006));
        assert_eq!((duo(175).pixel_width, duo(175).pixel_height), (2842, 2002));
        assert_eq!(duo(0).desired_scale, 0, "a v6 client chooses none");
        // Mutter's rule (meta-monitor.c `for_each_scale`): n/d applies iff both sides times d are multiples of n.
        for scale in OFFERED_SCALES {
            for (w, h) in [(2853, 2007), (2752, 2064), (1920, 1080)] {
                let s = display_spec(&Hello { desired_scale: scale, ..hello(w, h, 2) });
                let (n, d) = (u32::from(scale) / 25 / gcd(u32::from(scale) / 25, 4), 4 / gcd(u32::from(scale) / 25, 4));
                assert!(
                    (s.pixel_width * d).is_multiple_of(n) && (s.pixel_height * d).is_multiple_of(n),
                    "{w}×{h} at {scale}"
                );
                assert!(
                    s.pixel_width.is_multiple_of(2)
                        && s.pixel_height.is_multiple_of(2)
                        && s.pixel_width <= w
                        && w - s.pixel_width < 22
                );
            }
        }
    }

    #[test]
    fn the_nearest_offered_scale_and_on_a_tie_the_larger() {
        assert_eq!(choose_scale(300), 300);
        assert_eq!(choose_scale(310), 300);
        assert_eq!(choose_scale(80), 100);
        assert_eq!(choose_scale(212), 200);
        assert_eq!(choose_scale(213), 225, "nearer 225");
        assert_eq!(choose_scale(0), 0);
        assert_eq!(choose_scale(1), 100);
    }
}
