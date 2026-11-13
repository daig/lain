//! The desktop's sound for the client (protocol v6 `AudioConfig`, `AudioPacket`): `lain_platform::AudioBackend`
//! on PipeWire. Swift: the audio half of `ScreenCaptureFrameSource` (ScreenCaptureKit's `capturesAudio`).
//!
//! - One capture stream per [`PipeWireAudio::start`], on its own thread running a PipeWire main loop (as
//!   `lain-linux-video`'s `capture.rs`). The stream sets `stream.capture.sink = "true"` and no `target.object`:
//!   WirePlumber then links it to the *default sink's monitor* and moves it when the default output changes
//!   (PipeWire 1.6 here; the property pipewire-pulse sets for a capture of a `.monitor` source).
//! - It asks for exactly the session's format (S16LE interleaved, the rate and channel count asked for, mono or
//!   FL/FR positions); PipeWire's adapter converts and resamples. `node.latency` is one chunk
//!   (`chunk_frames/rate`, "480/24000" for 20 ms), a request the graph may round to its quantum, so buffers are
//!   re-cut into exact chunks by [`chunk::Chunker`], whose docs say how capture times are derived (the buffer's
//!   arrival on `CLOCK_MONOTONIC` minus its length, on one continuous timeline).
//! - Chunks go to the bounded channel with `try_send` ([`chunk::Delivery`]): the PipeWire thread never waits.
//! - `start` returns once the stream is Paused or Streaming, and fails (with nothing left running) if there's no
//!   PipeWire daemon or the stream doesn't get there within [`START_TIMEOUT`].
//! - Dropping the [`PipeWireCapture`] sends a message on a `pw::channel` attached to the loop, which wakes it at
//!   once; the thread disconnects the stream and ends, dropping the chunk sender, so the session's channel closes.
//!   The dropping thread doesn't wait. A stream error or a lost daemon ends the thread the same way.

mod chunk;

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::{Duration, Instant};

use lain_platform::{AUDIO_QUEUE_CHUNKS, AudioBackend, AudioChunk, AudioFormat, PlatformError, Result};
use pipewire as pw;
use pw::spa;
use pw::spa::param::audio::{AudioFormat as SpaAudioFormat, AudioInfoRaw, AudioInfoRawFlags};
use pw::spa::pod::{Object, Pod, Value, serialize::PodSerializer};
use pw::spa::utils::SpaTypes;
use tokio::sync::{mpsc, oneshot};

pub use chunk::{Chunker, Delivery, chunk_frames};

/// How long the stream may take to connect.
pub const START_TIMEOUT: Duration = Duration::from_secs(2);

/// Captures the default output's monitor through PipeWire.
#[derive(Debug, Clone, Default)]
pub struct PipeWireAudio;

/// A running capture; dropping it stops the capture (without waiting for its thread).
pub struct PipeWireCapture {
    stop: pw::channel::Sender<()>,
}

impl std::fmt::Debug for PipeWireCapture {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PipeWireCapture").finish_non_exhaustive()
    }
}

impl Drop for PipeWireCapture {
    fn drop(&mut self) {
        // Fails only if the thread already ended (and dropped the receiver).
        let _ = self.stop.send(());
    }
}

impl AudioBackend for PipeWireAudio {
    type Capture = PipeWireCapture;

    async fn start(&self, format: AudioFormat, chunk_ms: u32) -> Result<(PipeWireCapture, mpsc::Receiver<AudioChunk>)> {
        if format.sample_rate == 0 || format.channels == 0 || chunk_ms == 0 {
            return Err(PlatformError::Failed(format!("can't capture {format:?} in {chunk_ms} ms chunks")));
        }
        let (tx, rx) = mpsc::channel(AUDIO_QUEUE_CHUNKS);
        let (stop, stop_rx) = pw::channel::channel::<()>();
        let (ready_tx, ready_rx) = oneshot::channel();
        std::thread::Builder::new()
            .name("lain-pw-audio".into())
            .spawn(move || {
                let mut ready = Some(ready_tx);
                let outcome = run(format, chunk_ms, tx, stop_rx, &mut ready);
                // Every PipeWire object is gone by now: a failed start leaves nothing behind.
                match (outcome, ready.take()) {
                    (Err(e), Some(ready)) => {
                        let _ = ready.send(Err(e));
                    }
                    (Err(e), None) => tracing::warn!("sound capture ended: {e}"),
                    (Ok(()), _) => tracing::info!("sound capture stopped"),
                }
            })
            .map_err(|e| PlatformError::Failed(format!("can't start the PipeWire sound thread: {e}")))?;
        match ready_rx.await {
            Ok(Ok(())) => Ok((PipeWireCapture { stop }, rx)),
            Ok(Err(e)) => Err(PlatformError::Unavailable(e)),
            Err(_) => Err(PlatformError::Failed("the PipeWire sound thread ended unexpectedly".into())),
        }
    }
}

fn serialize(value: Value) -> Vec<u8> {
    PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &value).expect("a pod always serializes").0.into_inner()
}

/// The one `EnumFormat` offered: raw S16LE interleaved at `format`'s rate and channels (mono, or FL/FR for
/// stereo; unpositioned beyond).
pub fn format_pod(format: AudioFormat) -> Vec<u8> {
    let mut info = AudioInfoRaw::new();
    info.set_format(SpaAudioFormat::S16LE);
    info.set_rate(format.sample_rate);
    info.set_channels(u32::from(format.channels));
    let mut position = [0; spa::sys::SPA_AUDIO_MAX_CHANNELS as usize];
    match format.channels {
        1 => position[0] = spa::sys::SPA_AUDIO_CHANNEL_MONO,
        2 => {
            position[0] = spa::sys::SPA_AUDIO_CHANNEL_FL;
            position[1] = spa::sys::SPA_AUDIO_CHANNEL_FR;
        }
        _ => info.set_flags(AudioInfoRawFlags::UNPOSITIONED),
    }
    info.set_position(position);
    serialize(Value::Object(Object {
        type_: SpaTypes::ObjectParamFormat.as_raw(),
        id: spa::param::ParamType::EnumFormat.as_raw(),
        properties: info.into(),
    }))
}

/// `node.latency` for one chunk: "480/24000" for 20 ms at 24 kHz.
pub fn node_latency(format: AudioFormat, chunk_ms: u32) -> String {
    format!("{}/{}", chunk_frames(format, chunk_ms), format.sample_rate)
}

/// What the loop's callbacks tell the loop.
#[derive(Default)]
struct Shared {
    /// The stream reached Paused or Streaming.
    connected: bool,
    /// The format PipeWire settled on is the one asked for.
    format_ok: bool,
    /// Why the capture must end.
    ended: Option<String>,
}

/// The capture thread: sets up the stream, reports the start through `ready`, then runs until stopped, the
/// session's receiver goes, or the stream ends. Returns why it ended, if not by request.
fn run(
    format: AudioFormat,
    chunk_ms: u32,
    tx: mpsc::Sender<AudioChunk>,
    stop_rx: pw::channel::Receiver<()>,
    ready: &mut Option<oneshot::Sender<std::result::Result<(), String>>>,
) -> std::result::Result<(), String> {
    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None).map_err(|e| format!("PipeWire main loop: {e}"))?;
    let context = pw::context::ContextRc::new(&mainloop, None).map_err(|e| format!("PipeWire context: {e}"))?;
    let core = context.connect_rc(None).map_err(|e| format!("connecting to PipeWire: {e}"))?;
    let shared = Rc::new(RefCell::new(Shared::default()));

    let core_shared = shared.clone();
    let _core_listener = core
        .add_listener_local()
        .error(move |id, _seq, res, message| {
            if id == pw::core::PW_ID_CORE {
                core_shared.borrow_mut().ended.get_or_insert(format!("PipeWire connection error {res}: {message}"));
            }
        })
        .register();

    let stopped = Rc::new(Cell::new(false));
    let stop_flag = stopped.clone();
    let _stop = stop_rx.attach(mainloop.loop_(), move |()| stop_flag.set(true));

    let latency = node_latency(format, chunk_ms);
    let mut props = pw::properties::PropertiesBox::new();
    props.insert(*pw::keys::MEDIA_TYPE, "Audio");
    props.insert(*pw::keys::MEDIA_CATEGORY, "Capture");
    props.insert(*pw::keys::MEDIA_ROLE, "Screen");
    props.insert(*pw::keys::NODE_NAME, "lain-audio");
    props.insert(*pw::keys::NODE_DESCRIPTION, "lain: sound for the client");
    props.insert(*pw::keys::APP_NAME, "lain");
    // The default sink's monitor, following the default (no target.object).
    props.insert(*pw::keys::STREAM_CAPTURE_SINK, "true");
    props.insert(*pw::keys::NODE_LATENCY, latency.as_str());
    let stream = pw::stream::StreamRc::new(core, "lain-audio", props).map_err(|e| format!("PipeWire stream: {e}"))?;

    let fmt_shared = shared.clone();
    let state_shared = shared.clone();
    let proc_shared = shared.clone();
    let mut chunker = Chunker::new(format, chunk_ms);
    let mut delivery = Delivery::new(tx.clone());
    let _listener = stream
        .add_local_listener_with_user_data(())
        .param_changed(move |_, _, id, param| {
            let Some(param) = param else { return };
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            let mut info = AudioInfoRaw::new();
            if info.parse(param).is_err() {
                return;
            }
            let got = (info.format(), info.rate(), info.channels());
            let want = (SpaAudioFormat::S16LE, format.sample_rate, u32::from(format.channels));
            let mut s = fmt_shared.borrow_mut();
            if got == want {
                tracing::info!(rate = info.rate(), channels = info.channels(), latency = %latency, "sound format: S16LE");
                s.format_ok = true;
            } else {
                s.format_ok = false;
                s.ended.get_or_insert(format!("PipeWire negotiated {got:?}, not {want:?}"));
            }
        })
        .state_changed(move |_, _, old, new| {
            tracing::debug!(?old, ?new, "sound capture stream");
            let mut s = state_shared.borrow_mut();
            match new {
                pw::stream::StreamState::Error(e) => {
                    s.ended.get_or_insert(format!("PipeWire stream error: {e}"));
                }
                pw::stream::StreamState::Streaming | pw::stream::StreamState::Paused => s.connected = true,
                pw::stream::StreamState::Unconnected if s.connected => {
                    s.ended.get_or_insert("the PipeWire stream was disconnected".into());
                }
                _ => {}
            }
        })
        .process(move |stream, _| {
            let format_ok = proc_shared.borrow().format_ok;
            while let Some(mut buffer) = stream.dequeue_buffer() {
                let arrival = lain_platform::clock::now_ns();
                if !format_ok {
                    continue;
                }
                let Some(data) = buffer.datas_mut().first_mut() else { continue };
                let (offset, size) = (data.chunk().offset() as usize, data.chunk().size() as usize);
                if let Some(bytes) = data.data() {
                    let end = offset.saturating_add(size).min(bytes.len());
                    let start = offset.min(end);
                    chunker.push(&bytes[start..end], arrival, |c| {
                        delivery.deliver(c);
                    });
                }
            }
        })
        .register()
        .map_err(|e| format!("PipeWire listener: {e}"))?;

    let pod = format_pod(format);
    let mut params: Vec<&Pod> = Pod::from_bytes(&pod).into_iter().collect();
    stream
        .connect(
            spa::utils::Direction::Input,
            None,
            pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
            &mut params,
        )
        .map_err(|e| format!("connecting the sound capture: {e}"))?;

    let deadline = Instant::now() + START_TIMEOUT;
    let outcome = loop {
        mainloop.loop_().iterate(pw::loop_::Timeout::Finite(Duration::from_millis(100)));
        if stopped.get() {
            break Ok(());
        }
        if let Some(why) = shared.borrow_mut().ended.take() {
            break Err(why);
        }
        if ready.is_some() {
            if shared.borrow().connected {
                tracing::info!(?format, chunk_ms, "capturing the default output's sound");
                if let Some(ready) = ready.take()
                    && ready.send(Ok(())).is_err()
                {
                    // The caller gave up waiting.
                    break Ok(());
                }
            } else if Instant::now() >= deadline {
                break Err(format!("the sound capture didn't connect within {START_TIMEOUT:?}"));
            }
        } else if tx.is_closed() {
            break Ok(());
        }
    };
    let _ = stream.disconnect();
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use pw::spa::pod::deserialize::PodDeserializer;

    #[test]
    fn format_pod_asks_for_s16le_mono() {
        let bytes = format_pod(AudioFormat::SESSION);
        let pod = Pod::from_bytes(&bytes).unwrap();
        let mut info = AudioInfoRaw::new();
        info.parse(pod).unwrap();
        assert_eq!((info.format(), info.rate(), info.channels()), (SpaAudioFormat::S16LE, 24_000, 1));
        assert_eq!(info.position()[0], spa::sys::SPA_AUDIO_CHANNEL_MONO);
        let (_, Value::Object(obj)) = PodDeserializer::deserialize_any_from(&bytes).unwrap() else { panic!() };
        assert_eq!(obj.id, spa::param::ParamType::EnumFormat.as_raw());
        let stereo = format_pod(AudioFormat { sample_rate: 48_000, channels: 2 });
        info.parse(Pod::from_bytes(&stereo).unwrap()).unwrap();
        assert_eq!(&info.position()[..2], &[spa::sys::SPA_AUDIO_CHANNEL_FL, spa::sys::SPA_AUDIO_CHANNEL_FR]);
    }

    #[test]
    fn latency_is_one_chunk() {
        assert_eq!(node_latency(AudioFormat::SESSION, 20), "480/24000");
        assert_eq!(node_latency(AudioFormat { sample_rate: 48_000, channels: 2 }, 10), "480/48000");
    }
}
