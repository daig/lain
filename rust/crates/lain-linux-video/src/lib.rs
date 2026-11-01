//! PipeWire capture and VA-API HEVC encoding on the AMD iGPU, as one `VideoBackend` (wave 3).
//! Never touches an NVIDIA device (decision L3).
//!
//! Brief: `docs/LINUX-HOST-PLAN.md`, `lain-linux-video`; technology chosen by spike A.

pub mod au;
pub mod backend;
pub mod bitstream;
pub mod capture;
pub mod device;
pub mod egl;
pub mod encoder;
pub mod engine;
pub mod env;
mod ffi;
pub mod frame;
pub mod gbm;
pub mod gl;
pub mod gpu;
#[cfg(test)]
mod gpu_tests;
pub mod va;
