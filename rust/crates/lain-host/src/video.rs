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

use crate::util::Cancel;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The display a client's `Hello` asks for: its pixel size, scale and maximum refresh rate (0: 120 Hz).
///
/// Intended difference from Swift, whose Mac host creates a fixed display (the 13" iPad Pro's 2752×2064 at
/// 2×, 120 Hz, `VirtualDisplay.Spec`): this serves any iPad. A scale of 0 is taken as 2 (an iPad's).
pub fn display_spec(hello: &Hello) -> DisplaySpec {
    DisplaySpec {
        pixel_width: hello.pixel_width,
        pixel_height: hello.pixel_height,
        scale: if hello.scale == 0 { 2 } else { u32::from(hello.scale) },
        refresh_hz: if hello.max_refresh_rate == 0 { 120 } else { u32::from(hello.max_refresh_rate) },
    }
}

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
/// [`stop`](Self::stop) is synchronous: nothing is sent once it returns; the capture stop and the display's
/// removal finish in the background ([`wait_until_stopped`](Self::wait_until_stopped)). A stop while the
/// display is still being created drops the creation, which the backend undoes (`create` is cancel-safe).
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

    /// Stops video; nothing is sent once this returns. Idempotent.
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
    pub(crate) async fn start<P: Platform>(
        self: &Arc<Self>,
        platform: &P,
        hello: &Hello,
        options: PipelineOptions,
        realtime: ChannelSender,
        video: ChannelSender,
        on_end: impl FnOnce(VideoEnd) + Send + 'static,
    ) -> Result<Streaming, StartError> {
        if self.stop.is_cancelled() {
            return Err(StartError::Stopped);
        }
        self.done.send_replace(false);
        let result = self.start_inner(platform, hello, options, realtime, video, on_end).await;
        if result.is_err() {
            self.done.send_replace(true);
        }
        result
    }

    async fn start_inner<P: Platform>(
        self: &Arc<Self>,
        platform: &P,
        hello: &Hello,
        options: PipelineOptions,
        realtime: ChannelSender,
        video: ChannelSender,
        on_end: impl FnOnce(VideoEnd) + Send + 'static,
    ) -> Result<Streaming, StartError> {
        let display = platform.display().clone();
        let spec = display_spec(hello);
        // `create` is cancel-safe: a stop meanwhile drops it, and the backend removes what it made.
        let created = tokio::select! {
            () = self.stop.cancelled() => return Err(StartError::Stopped),
            created = display.create(spec) => created,
        };
        let (streamed, source) = created.map_err(StartError::Failed)?;
        if self.stop.is_cancelled() {
            display.destroy().await;
            return Err(StartError::Stopped);
        }
        let config = lain_media::encode_config(&streamed, hello.max_refresh_rate, &options);
        let (session, mut events) = match platform.video().start(&source, config).await {
            Ok(started) => started,
            Err(e) => {
                display.destroy().await;
                return Err(StartError::Failed(e));
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
        tokio::spawn(async move {
            let end = this.drive(&mut pipeline, &mut cursor, &mut events, &mut commands_rx, &clock).await;
            this.sending.store(false, Ordering::SeqCst);
            {
                let mut s = lock(&this.shared);
                s.streaming = None;
                s.commands = None;
            }
            if let Some(end) = end {
                on_end(end);
            }
            cursor.stop();
            pipeline.stop().await;
            display.destroy().await;
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
