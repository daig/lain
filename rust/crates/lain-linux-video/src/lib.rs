//! PipeWire capture and VA-API HEVC encoding on the AMD iGPU, as one `VideoBackend` (wave 3).
//! Never touches an NVIDIA device (decision L3).
//!
//! Brief: `docs/LINUX-HOST-PLAN.md`, `lain-linux-video`; technology chosen by spike A.

pub mod bitstream;
pub mod device;
pub mod env;
mod ffi;
pub mod va;
