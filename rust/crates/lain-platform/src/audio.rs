//! The host's sound, for the client's speakers (protocol v6 `AudioConfig`, `AudioPacket`). Swift: `AudioSource`,
//! which the Mac's screen capture implements.

use std::future::Future;

use tokio::sync::mpsc;

use crate::Result;

/// Interleaved signed 16-bit little-endian PCM at this rate and channel count (the wire's `pcm16LE`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AudioFormat {
    pub sample_rate: u32,
    pub channels: u8,
}

impl AudioFormat {
    /// What the Mac host sends (Swift: `ScreenCaptureFrameSource.audioFormat`): 24 kHz mono, plenty for alerts
    /// and speech, and a quarter of the data of 48 kHz stereo, so a 20 ms packet fits one TCP segment and takes
    /// less of the radio from the video.
    pub const SESSION: Self = Self { sample_rate: 24_000, channels: 1 };

    /// Bytes per frame (one sample per channel).
    pub const fn frame_bytes(self) -> usize {
        2 * self.channels as usize
    }
}

/// A few milliseconds of sound, as captured.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioChunk {
    /// When the first frame was captured, on [`clock::now_ns`](crate::clock::now_ns)'s clock.
    pub capture_time_ns: u64,
    /// Whole frames in the capture's [`AudioFormat`].
    pub samples: Vec<u8>,
}

/// How many chunks wait unread before the capture drops new ones (about 1.3 s at 20 ms): sound that late is
/// no use, and the capture thread never waits for the session.
pub const AUDIO_QUEUE_CHUNKS: usize = 64;

/// Captures what the desktop plays: the mix sent to its default output, following that default as it changes.
pub trait AudioBackend: Send + Sync + 'static {
    /// The running capture; dropping it stops the capture (and closes the chunk channel) promptly, from any
    /// thread, without blocking.
    type Capture: Send + Sync + 'static;

    /// Starts capturing in `format` (the backend converts and resamples), with chunks of about `chunk_ms`
    /// milliseconds sent on the returned channel (bounded at [`AUDIO_QUEUE_CHUNKS`]: when it's full, new chunks
    /// are dropped). Silence is sent as silence, so the stream is continuous while nothing plays. Fails, leaving
    /// nothing behind, if no capture can be made (no sound server).
    fn start(
        &self,
        format: AudioFormat,
        chunk_ms: u32,
    ) -> impl Future<Output = Result<(Self::Capture, mpsc::Receiver<AudioChunk>)>> + Send;
}
