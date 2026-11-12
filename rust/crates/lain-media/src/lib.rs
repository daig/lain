//! Video and cursor stream logic: the frame gate, idle refinement, the pipeline driving a
//! `VideoSession`, HEVC bitstream utilities, the cursor shape tracker (wave 2).
//!
//! Swift reference: `Packages/LainKit/Sources/LainMedia/{FrameGate,HEVC,VideoEncoder}.swift`,
//! `LainHostCore/Video/{HostVideoPipeline,CursorMonitor}.swift`, `LainTransport/FrameAckWindow.swift`,
//! `LainTelemetry/RollingPercentiles.swift`. Brief: `docs/LINUX-HOST-PLAN.md`, `lain-media`.
//!
//! Everything here is sans-IO: [`VideoPipeline`] and [`CursorMonitor`] are state machines their owner
//! (`lain-host`) drives with events, client messages and timer calls, and they hand every message to send
//! to an output callback as an [`Outbound`], tagged with the connection it goes on. Time comes from
//! `lain_platform::Clock`. Nothing touches a channel, a socket or a runtime.

pub mod bitrate;
pub mod cursor;
pub mod gate;
pub mod hevc;
pub mod pipeline;
pub mod stats;

pub use bitrate::{BitrateConfig, BitrateController};
pub use cursor::{CursorMonitor, CursorShapeTracker};
pub use gate::{FrameGate, GateStats, IdleRefiner};
pub use hevc::{AccessUnit, HevcError};
pub use pipeline::{PipelineOptions, VideoEnd, VideoPipeline, encode_config};
pub use stats::{Ack, FrameAckWindow, HostVideoStats, RateMeter, RollingPercentiles};

use lain_proto::{HeaderFlags, Message};

/// The connection of a link a message goes on. Video: `VideoConfig` and `VideoFrame` (Swift's
/// `HostVideoPipeline` sends on its video channel); realtime: `CursorShape` and `CursorSelect` (Swift's
/// `CursorMonitor`, bound to `sendRealtime`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Connection {
    Realtime,
    Video,
}

/// One message to send, with the header flags to frame it with. Pass `flags` explicitly to
/// `MessageCodec::lower`: a `VideoFrame`'s `REFINEMENT` flag isn't implied by its payload.
#[derive(Debug, Clone, PartialEq)]
pub struct Outbound {
    pub connection: Connection,
    pub message: Message,
    pub flags: HeaderFlags,
}
