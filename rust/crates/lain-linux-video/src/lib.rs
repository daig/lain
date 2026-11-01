//! PipeWire capture and VA-API HEVC encoding on the AMD iGPU, as one `VideoBackend` (wave 3; decisions L3 and L7,
//! spikes SL2 and SL5). Never touches an NVIDIA device: no GStreamer, no CUDA, no Vulkan; libEGL loads only with
//! Mesa's vendor library pinned ([`env`]), and the one render node opened is the AMD one, chosen from sysfs
//! ([`device`]). Swift reference (behaviour): `LainMedia/VideoEncoder`, `LainHostCore/Video/FrameSource`.
//!
//! [`LinuxVideo`] starts a [`LinuxVideoSession`] on `lain-gnome`'s [`GnomeSource`](lain_gnome::GnomeSource):
//! - [`capture`]: a PipeWire consumer of lain's display's node on its own thread (DMA-BUF at Mutter's modifier,
//!   shared memory as the fallback; cursor metadata into `CursorState`);
//! - [`gl`]: BGRx → NV12, one GL compute pass through EGL on GBM ([`egl`], [`gbm`]), written straight into libva's
//!   exported NV12 surfaces;
//! - [`encoder`]: HEVC Main 4:2:0 8-bit with libva ([`va`]): CBR with a small HRD and bit stuffing off, an IDR on
//!   request, lain's own VPS/SPS/PPS as packed headers ([`bitstream`]), refinement at a lower QP;
//! - [`engine`]: the video thread that keeps the `VideoSession` contract, pipelined as SL5 found it must be, with
//!   every access unit checked ([`au`]); [`gpu`] is its real GPU, the tests' is a fake.
//!
//! Brief: `docs/LINUX-HOST-PLAN.md`, `lain-linux-video`.

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

pub use backend::{LinuxVideo, LinuxVideoConfig, LinuxVideoSession};
pub use env::{check_environment, required_environment};
