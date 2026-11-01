//! Host input policy: the client's input messages in, [`InputAction`](lain_platform::InputAction)s out.
//!
//! Swift reference: `Packages/LainKit/Sources/LainHostCore/Input/` (`HostInputRouter`, `PinchZoomMapper`,
//! `InputInjector`), `LainInput/MacKeyCode.swift`. Brief: `docs/LINUX-HOST-PLAN.md`, `lain-input`.
//!
//! On the Mac, the router hands messages to `InputInjector`, which posts `CGEvent`s that carry modifier
//! flags and positions. Linux input events carry neither, so this crate decides everything the desktop sees
//! and tracks what it holds; the platform's `InputBackend` only performs the actions:
//! - [`keymap`]: HID usages → evdev codes, the kernel's own table for the whole keyboard page.
//! - [`ModifierMap`]: which desktop modifier each Mac modifier holds, pressed and released explicitly.
//! - [`scroll`]: phases and momentum → Wayland scrolls and stops, with one kinetic continuation.
//! - [`PinchZoomMapper`]: pinch → zoom steps, sent as [`ZoomAction`] says.
//! - [`InputRouter`]: all of it, plus key repeats dropped and release-all.
//!
//! A session's use: one [`InputRouter`] per link; for each realtime message, clear a reused buffer, call
//! [`InputRouter::handle`], and pass the buffer to `InputBackend::apply` if it isn't empty; when the link
//! ends, [`InputRouter::release_all`] the same way.

pub mod evdev;
pub mod keymap;
mod modifiers;
mod pinch;
mod router;
pub mod scroll;

pub use modifiers::{LinuxModifier, ModifierMap, ModifierSet};
pub use pinch::PinchZoomMapper;
pub use router::{InputConfig, InputRouter, Outcome, WHEEL_DETENT, ZoomAction};
pub use scroll::{Momentum, ScrollConfig};
