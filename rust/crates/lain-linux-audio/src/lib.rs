//! The desktop's sound for the client (protocol v6 `AudioConfig`, `AudioPacket`): `lain_platform::AudioBackend`
//! on PipeWire. Swift: the audio half of `ScreenCaptureFrameSource` (ScreenCaptureKit's `capturesAudio`).
//!
//! Stub: the capture is not implemented yet.

use lain_platform::{AudioBackend, AudioChunk, AudioFormat, PlatformError, Result};
use tokio::sync::mpsc;

/// Captures the default output's monitor through PipeWire.
#[derive(Debug, Clone, Default)]
pub struct PipeWireAudio {
    _stub: (),
}

/// A running capture; dropping it stops the capture.
#[derive(Debug)]
pub struct PipeWireCapture;

impl AudioBackend for PipeWireAudio {
    type Capture = PipeWireCapture;

    async fn start(
        &self,
        _format: AudioFormat,
        _chunk_ms: u32,
    ) -> Result<(PipeWireCapture, mpsc::Receiver<AudioChunk>)> {
        Err(PlatformError::Unavailable("sound capture isn't implemented yet".into()))
    }
}
