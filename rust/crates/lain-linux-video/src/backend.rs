//! The `VideoBackend` on GNOME (decision L7): [`LinuxVideo`] starts a [`LinuxVideoSession`] on a [`GnomeSource`],
//! with the video thread ([`crate::engine`]) on the real GPU pipeline ([`crate::gpu`]) and the PipeWire consumer
//! ([`crate::capture`]). Swift: `HostVideoPipeline`'s start of `FrameSource` and `VideoEncoder` (behaviour).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use lain_gnome::{DisplayEnd, GnomeSource};
use lain_platform::{
    Chroma, ColorTags, EncodeConfig, EncodeRequest, PlatformError, Result, StreamInfo, VideoBackend, VideoEvent,
    VideoSession,
};
use tokio::sync::{mpsc, oneshot, watch};

use crate::capture::{Capture, CaptureConfig};
use crate::encoder::EncoderSettings;
use crate::engine::{Engine, EngineConfig, EngineStats, Gpu, Inbox};
use crate::gbm::MUTTER_MODIFIER;
use crate::gpu::{GpuPipeline, GpuSettings};

/// The smallest picture the iGPU's encoder (VCN) codes: it encodes nothing below 192×128 (found making
/// `lain-media`'s fixtures, 2026-10-31).
pub const MIN_SIZE: (u32, u32) = (192, 128);

/// How video is set up.
#[derive(Debug, Clone, Default)]
pub struct LinuxVideoConfig {
    /// A render node to use instead of the automatic choice (it must still be AMD); `None` reads
    /// `LAIN_RENDER_NODE`, else chooses from sysfs.
    pub render_node: Option<String>,
    pub engine: EngineConfig,
}

/// The video backend: capture of lain's display and HEVC encoding on the AMD iGPU. A cheap handle.
#[derive(Debug, Clone, Default)]
pub struct LinuxVideo {
    config: LinuxVideoConfig,
}

impl LinuxVideo {
    pub fn new(config: LinuxVideoConfig) -> Self {
        Self { config }
    }

    /// What the process environment must hold for video to start ([`crate::env::required_environment`]):
    /// `lain-hostd` re-execs itself with these when they are missing.
    pub fn required_environment() -> Result<Vec<(String, String)>> {
        crate::env::required_environment()
    }
}

/// What the encoder produces for `config`: always HEVC 4:2:0 8-bit, full-range sRGB (decision L3), whatever the
/// client could decode; the size as asked.
pub fn stream_info(config: &EncodeConfig) -> StreamInfo {
    StreamInfo {
        width: config.width,
        height: config.height,
        chroma: Chroma::Yuv420,
        bit_depth: 8,
        color: ColorTags::SRGB_FULL_RANGE,
    }
}

/// Checks a start request against its source: the encode size is the display's (no scaling), even, and at least
/// [`MIN_SIZE`]; the frame rate and bitrate are set.
pub fn check_config(source_size: (u32, u32), config: &EncodeConfig) -> Result<()> {
    let size = (config.width, config.height);
    if size != source_size {
        return Err(PlatformError::Failed(format!(
            "the encode size {}×{} isn't lain's display's {}×{} (video doesn't scale)",
            size.0, size.1, source_size.0, source_size.1
        )));
    }
    if !size.0.is_multiple_of(2) || !size.1.is_multiple_of(2) || size.0 < MIN_SIZE.0 || size.1 < MIN_SIZE.1 {
        return Err(PlatformError::Failed(format!(
            "{}×{} can't be encoded: 4:2:0 needs an even size, and the encoder at least {}×{}",
            size.0, size.1, MIN_SIZE.0, MIN_SIZE.1
        )));
    }
    if config.frame_rate == 0 || config.bitrate == 0 {
        return Err(PlatformError::Failed("a frame rate and a bitrate are needed".into()));
    }
    Ok(())
}

impl VideoBackend for LinuxVideo {
    type Source = GnomeSource;
    type Session = LinuxVideoSession;

    async fn start(
        &self,
        source: &GnomeSource,
        config: EncodeConfig,
    ) -> Result<(LinuxVideoSession, mpsc::UnboundedReceiver<VideoEvent>)> {
        check_config((source.pixel_width, source.pixel_height), &config)?;
        // Before libEGL can load (on the video thread): Mesa's vendor library only.
        crate::env::check_environment()?;
        let node = crate::device::select_system_render_node(self.config.render_node.as_deref())?;
        let settings = GpuSettings {
            encoder: EncoderSettings {
                width: config.width,
                height: config.height,
                fps: config.frame_rate,
                bitrate: config.bitrate,
            },
            modifier: MUTTER_MODIFIER,
        };
        let capture = CaptureConfig::new(
            source.node_id,
            source.pixel_width,
            source.pixel_height,
            source.refresh_hz.max(1),
            source.cursor.clone(),
        );
        let (session, events, _) = start_session(
            move || GpuPipeline::new(&node, settings),
            stream_info(&config),
            source.ended.clone(),
            self.config.engine,
            Some(capture),
        )
        .await?;
        Ok((session, events))
    }
}

struct Inner {
    info: StreamInfo,
    inbox: Arc<Inbox>,
    capture_stop: Arc<AtomicBool>,
    capture: Mutex<Option<Capture>>,
    engine_done: watch::Receiver<bool>,
}

impl Drop for Inner {
    fn drop(&mut self) {
        self.inbox.stop();
        self.capture_stop.store(true, Ordering::Release);
    }
}

/// One running session (`VideoSession`): a handle; clones share it.
#[derive(Clone)]
pub struct LinuxVideoSession {
    inner: Arc<Inner>,
}

impl LinuxVideoSession {
    /// The video thread's counters.
    pub fn stats(&self) -> EngineStats {
        self.inner.inbox.stats()
    }
}

impl VideoSession for LinuxVideoSession {
    fn info(&self) -> StreamInfo {
        self.inner.info
    }

    fn encode(&self, request: EncodeRequest) {
        self.inner.inbox.push_request(request);
    }

    async fn stop(&self) {
        self.inner.inbox.stop();
        self.inner.capture_stop.store(true, Ordering::Release);
        let mut engine = self.inner.engine_done.clone();
        let _ = engine.wait_for(|done| *done).await;
        let capture = self.inner.capture.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(capture) = capture {
            let mut done = capture.done();
            drop(capture);
            let _ = done.wait_for(|done| *done).await;
        }
    }
}

/// Starts a session: the video thread builds its GPU with `make_gpu` (so the GL context is current there), then
/// runs the engine; once the GPU is ready, the PipeWire consumer starts (if `capture` is given; the tests feed
/// the returned inbox themselves).
pub(crate) async fn start_session<G: Gpu + 'static>(
    make_gpu: impl FnOnce() -> Result<G, String> + Send + 'static,
    info: StreamInfo,
    ended: watch::Receiver<Option<DisplayEnd>>,
    cfg: EngineConfig,
    capture: Option<CaptureConfig>,
) -> Result<(LinuxVideoSession, mpsc::UnboundedReceiver<VideoEvent>, Arc<Inbox>)> {
    let inbox = Inbox::new();
    let capture_stop = Arc::new(AtomicBool::new(false));
    let (events_tx, events) = mpsc::unbounded_channel();
    let (ready_tx, ready) = oneshot::channel::<Result<(), String>>();
    let (done_tx, engine_done) = watch::channel(false);
    let thread_inbox = inbox.clone();
    let stop = capture_stop.clone();
    std::thread::Builder::new()
        .name("lain-video".into())
        .spawn(move || {
            let gpu = match make_gpu() {
                Ok(gpu) => gpu,
                Err(e) => {
                    let _ = ready_tx.send(Err(e));
                    let _ = done_tx.send(true);
                    return;
                }
            };
            if ready_tx.send(Ok(())).is_err() {
                // The start was abandoned: tear the GPU down here, where it was made.
                drop(gpu);
                let _ = done_tx.send(true);
                return;
            }
            let stop_capture = Box::new(move || stop.store(true, Ordering::Release));
            Engine::new(gpu, cfg, thread_inbox, events_tx, ended, stop_capture).run();
            let _ = done_tx.send(true);
        })
        .map_err(|e| PlatformError::Failed(format!("can't start the video thread: {e}")))?;
    let started = ready.await.map_err(|_| PlatformError::Failed("the video thread died while starting".into()))?;
    started.map_err(|e| PlatformError::Unavailable(format!("video can't start on the GPU: {e}")))?;
    let capture = match capture {
        Some(c) => match Capture::start(c, inbox.clone(), capture_stop.clone()) {
            Ok(c) => Some(c),
            Err(e) => {
                inbox.stop();
                return Err(PlatformError::Failed(e));
            }
        },
        None => None,
    };
    let session = LinuxVideoSession {
        inner: Arc::new(Inner { info, inbox: inbox.clone(), capture_stop, capture: Mutex::new(capture), engine_done }),
    };
    Ok((session, events, inbox))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::CaptureFrame;
    use crate::engine::tests::{FakeGpu, Outcome, fast_config, picture};
    use std::time::Duration;

    fn config(width: u32, height: u32) -> EncodeConfig {
        EncodeConfig { width, height, frame_rate: 120, bitrate: 60_000_000, chroma: Chroma::Yuv444, bit_depth: 10 }
    }

    #[test]
    fn config_checks_and_info() {
        assert_eq!(check_config((2752, 2064), &config(2752, 2064)), Ok(()));
        assert!(check_config((2752, 2064), &config(2064, 1548)).unwrap_err().to_string().contains("doesn't scale"));
        assert!(check_config((191, 128), &config(191, 128)).is_err());
        assert!(check_config((190, 128), &config(190, 128)).is_err(), "below 192 wide");
        assert!(check_config((192, 128), &config(192, 128)).is_ok());
        assert!(check_config((2752, 2064), &EncodeConfig { frame_rate: 0, ..config(2752, 2064) }).is_err());
        // 4:4:4 10-bit asked, 4:2:0 8-bit produced (L3).
        let info = stream_info(&config(2752, 2064));
        assert_eq!((info.chroma, info.bit_depth, info.color), (Chroma::Yuv420, 8, ColorTags::SRGB_FULL_RANGE));
        assert_eq!((info.width, info.height), (2752, 2064));
    }

    async fn recv(events: &mut mpsc::UnboundedReceiver<VideoEvent>) -> Option<VideoEvent> {
        tokio::time::timeout(Duration::from_secs(2), events.recv()).await.expect("an event within 2 s")
    }

    #[tokio::test]
    async fn the_session_contract_on_fakes() {
        let gpu = FakeGpu::default();
        let probe = gpu.clone();
        let (_ended_tx, ended) = watch::channel(None);
        let info = stream_info(&config(2752, 2064));
        let (session, mut events, inbox) =
            start_session(move || Ok(gpu), info, ended, fast_config(), None).await.unwrap();
        assert_eq!(session.info(), info);
        session.encode(EncodeRequest { frame_id: 1, keyframe: true, refinement: false });
        assert_eq!(recv(&mut events).await, Some(VideoEvent::EncodeFailed { frame_id: 1 }));
        inbox.push_frame(CaptureFrame::new(picture(4), 99, None));
        assert_eq!(recv(&mut events).await, Some(VideoEvent::Captured { capture: 1, capture_ns: 99 }));
        session.encode(EncodeRequest { frame_id: 2, keyframe: true, refinement: false });
        let Some(VideoEvent::Encoded(f)) = recv(&mut events).await else { panic!("expected a frame") };
        assert_eq!((f.frame_id, f.capture, f.keyframe), (2, 1, true));
        assert_eq!(session.stats().encoded, 1);
        // An encode hanging when stop comes: stop returns, and nothing follows.
        probe.state().outcomes.push_back(Outcome::Hang);
        session.encode(EncodeRequest { frame_id: 3, keyframe: false, refinement: false });
        session.stop().await;
        assert_eq!(events.recv().await, None, "the channel closes with stop, and no event follows");
        session.stop().await; // idempotent
        session.encode(EncodeRequest { frame_id: 4, keyframe: false, refinement: false });
    }

    #[tokio::test]
    async fn end_reason_mapping_through_a_session() {
        for (end, want) in [
            (DisplayEnd::StoppedByUser, Some(VideoEvent::StoppedByUser)),
            (
                DisplayEnd::Failed("Mutter left".into()),
                Some(VideoEvent::Failed(PlatformError::Failed("lain's display failed: Mutter left".into()))),
            ),
        ] {
            let (ended_tx, ended) = watch::channel(None);
            let (session, mut events, _) =
                start_session(|| Ok(FakeGpu::default()), stream_info(&config(2752, 2064)), ended, fast_config(), None)
                    .await
                    .unwrap();
            ended_tx.send_replace(Some(end));
            assert_eq!(recv(&mut events).await, want);
            assert_eq!(recv(&mut events).await, None);
            session.stop().await;
        }
        // Destroyed: no event; the channel stays open until stop.
        let (ended_tx, ended) = watch::channel(None);
        let (session, mut events, _) =
            start_session(|| Ok(FakeGpu::default()), stream_info(&config(2752, 2064)), ended, fast_config(), None)
                .await
                .unwrap();
        ended_tx.send_replace(Some(DisplayEnd::Destroyed));
        assert!(tokio::time::timeout(Duration::from_millis(100), events.recv()).await.is_err());
        session.stop().await;
        assert_eq!(events.recv().await, None);
    }

    #[tokio::test]
    async fn a_gpu_that_fails_to_start_is_unavailable() {
        let (_tx, ended) = watch::channel(None);
        let err = start_session(
            || Err::<FakeGpu, _>("vaInitialize: unknown libva error".into()),
            stream_info(&config(2752, 2064)),
            ended,
            fast_config(),
            None,
        )
        .await
        .err()
        .unwrap();
        assert!(matches!(&err, PlatformError::Unavailable(m) if m.contains("vaInitialize")), "{err}");
    }

    #[tokio::test]
    async fn the_real_backend_refuses_a_bad_config_before_touching_anything() {
        let (_tx, ended) = watch::channel(None);
        let source = GnomeSource {
            node_id: 0,
            mapping_id: None,
            stream_path: "/org/gnome/Mutter/ScreenCast/Stream/u1".into(),
            connector: "Meta-0".into(),
            pixel_width: 2752,
            pixel_height: 2064,
            refresh_hz: 120,
            cursor: lain_gnome::CursorState::new(),
            ended,
        };
        let err = LinuxVideo::default().start(&source, config(1376, 1032)).await.err().unwrap();
        assert!(err.to_string().contains("doesn't scale"), "{err}");
    }
}
