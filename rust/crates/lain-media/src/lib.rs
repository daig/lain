//! Video and cursor stream logic: the frame gate, idle refinement, the pipeline driving a
//! `VideoSession`, HEVC bitstream utilities, the cursor shape tracker (wave 2).
//!
//! Swift reference: `Packages/LainKit/Sources/LainMedia/`, `LainHostCore/Video/{HostVideoPipeline,CursorMonitor}.swift`,
//! `LainTransport/FrameAckWindow.swift`. Brief: `docs/LINUX-HOST-PLAN.md`, `lain-media`.
