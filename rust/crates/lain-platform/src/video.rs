//! Capture and encode, as one unit (decision L1; Swift: `FrameSource` + `VideoEncoder`).
//!
//! GPU frames never cross this boundary. The backend captures, keeps its newest frame, and reports each
//! capture; the core (`lain-media`) decides when to encode, and gets an encoded access unit back. The
//! core keeps the Swift pipeline's rules: a latest-wins slot, one frame in the encoder, a bounded number
//! of unacknowledged frames, idle refinement, and a keyframe on request.

use std::future::Future;

use tokio::sync::mpsc;

use crate::{PlatformError, Result};

/// Chroma subsampling of the encoded stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Chroma {
    Yuv420,
    Yuv444,
}

/// Colour description, as ITU-T H.273 code points (what `VideoConfig` carries).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ColorTags {
    pub full_range: bool,
    pub primaries: u8,
    pub transfer: u8,
    pub matrix: u8,
}

impl ColorTags {
    /// An sRGB desktop: BT.709 primaries (1), the sRGB transfer function (13), the BT.709 matrix (1),
    /// full range (decision L3). The Mac host tags Display P3 primaries (12) instead.
    pub const SRGB_FULL_RANGE: ColorTags = ColorTags { full_range: true, primaries: 1, transfer: 13, matrix: 1 };
}

/// What the core asks the encoder for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EncodeConfig {
    /// The streamed display's size in device pixels.
    pub width: u32,
    pub height: u32,
    pub frame_rate: u32,
    /// Average bits per second.
    pub bitrate: u32,
    pub chroma: Chroma,
    pub bit_depth: u8,
}

/// What the encoder produces, which may differ from what was asked (Swift's encoder falls back to 4:2:0
/// when the hardware won't do 4:4:4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamInfo {
    pub width: u32,
    pub height: u32,
    pub chroma: Chroma,
    pub bit_depth: u8,
    pub color: ColorTags,
}

/// One encode request (Swift: `VideoEncoder.encode(_:frameId:captureTimeNs:refinement:)` plus
/// `requestKeyframe`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EncodeRequest {
    /// Assigned by the core, increasing; echoed in the result.
    pub frame_id: u32,
    /// An IDR, with the parameter sets in the access unit.
    pub keyframe: bool,
    /// Idle refinement: re-encode the newest capture at higher quality.
    pub refinement: bool,
    /// Adaptive bitrate: the rate control's new target (bits per second) from this picture on; `None`: unchanged.
    pub bitrate: Option<u32>,
}

/// One encoded access unit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodedFrame {
    pub frame_id: u32,
    /// The capture this is (`VideoEvent::Captured::capture`).
    pub capture: u64,
    pub capture_ns: u64,
    /// When the encoder took the request.
    pub submit_ns: u64,
    pub encode_done_ns: u64,
    pub keyframe: bool,
    /// The access unit in Annex-B byte-stream format (start codes), as the encoder wrote it. A keyframe
    /// carries VPS, SPS and PPS. The core converts this to the wire's 4-byte length-prefixed NAL units
    /// and moves the parameter sets into `VideoConfig`.
    pub annexb: Vec<u8>,
}

/// What a video session reports, in order.
#[derive(Debug, Clone, PartialEq)]
pub enum VideoEvent {
    /// The display changed and a new frame was captured. `capture` counts captures from 1.
    Captured { capture: u64, capture_ns: u64 },
    /// The result of a request.
    Encoded(EncodedFrame),
    /// The request produced nothing: the encoder dropped or failed it, or produced an access unit the backend
    /// found corrupt. The session goes on, and the core makes its next request a keyframe, since the
    /// encoder's reference chain may now be broken.
    EncodeFailed { frame_id: u32 },
    /// Capture stopped on its own (the display went away, the compositor failed). Nothing follows.
    Failed(PlatformError),
    /// The owner stopped the capture from the desktop: the session goes on without video (Swift:
    /// `CaptureStoppedByUser`). Nothing follows.
    StoppedByUser,
}

/// Starts capture-and-encode sessions on what a [`DisplayBackend`](crate::DisplayBackend) created.
pub trait VideoBackend: Send + Sync + 'static {
    type Source: Clone + Send + Sync + 'static;
    type Session: VideoSession;

    /// Starts capturing `source` with an encoder set up for `config`. Events arrive on the receiver in
    /// order; it closes after [`VideoSession::stop`], `Failed` or `StoppedByUser`.
    fn start(
        &self,
        source: &Self::Source,
        config: EncodeConfig,
    ) -> impl Future<Output = Result<(Self::Session, mpsc::UnboundedReceiver<VideoEvent>)>> + Send;
}

/// One running capture-and-encode session.
pub trait VideoSession: Send + Sync + 'static {
    /// What the encoder produces.
    fn info(&self) -> StreamInfo;

    /// Encodes the newest frame captured so far, never an older one, so a request racing a new capture
    /// shows the new content. The newest capture stays available after it is encoded: a keyframe or a
    /// refinement on an idle desktop re-encodes it. Before the first capture there is nothing to encode:
    /// `EncodeFailed`.
    ///
    /// Never blocks: the result is exactly one `Encoded` or `EncodeFailed` event with the request's
    /// `frame_id`, within a bounded time. If the encoder yields nothing well within a second, the backend
    /// reports `EncodeFailed` itself, so the core never waits forever. The core keeps at most one request
    /// outstanding.
    fn encode(&self, request: EncodeRequest);

    /// Stops capture and encoding; no event follows once it returns. Idempotent.
    fn stop(&self) -> impl Future<Output = ()> + Send;
}
