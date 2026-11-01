//! The session engine, generic over `lain_platform::Platform`: the USB device loop, admission of the network
//! links the daemon hands in, the live session, power and status.
//!
//! Swift reference: `Packages/LainKit/Sources/LainHostCore/Session/{HostSession,HostEnvironment,
//! CursorWarpDetector,HostSetupProbe}.swift`, `LainHostCore/HostStatus.swift`, and the lifecycle part of
//! `LainHostCore/Video/HostVideoPipeline.swift`. Brief: `docs/LINUX-HOST-PLAN.md`, `lain-host`.
//!
//! ```no_run
//! # async fn demo(platform: lain_platform::fake::FakePlatform) {
//! use lain_host::{HostConfig, HostSession};
//! let (wifi_tx, wifi_rx) = tokio::sync::mpsc::channel(16); // lain-wifi's listener sends on `wifi_tx`
//! # drop(wifi_tx);
//! let session = HostSession::start(platform, HostConfig::default(), lain_usbmux::UsbMuxClient::default(), Some(wifi_rx));
//! let mut status = session.status_watch();
//! let mut secrets = session.secrets_changed(); // re-read the listener's PSKs on every change
//! # let _ = (&mut status, &mut secrets);
//! session.stop().await;
//! # }
//! ```
//!
//! - [`HostSession`]: one session at a time, over USB (the host dials through usbmuxd) or the network (the
//!   iPad dialed `lain-wifi`'s TLS-PSK listener); USB wins.
//! - [`HostStatus`]: what the status shows, derived from the session's state.
//! - [`HostConfig`], [`Tuning`], [`WifiAdmission`]: Swift's `Dependencies`, `Tuning` and `HostWiFiConfig`'s
//!   admission part.
//! - [`CursorWarpDetector`], [`PowerCount`]: the pure parts, as in Swift.

mod config;
mod connection;
mod session;
mod status;
mod util;
mod video;
mod warp;

pub use config::{HostConfig, Hook, Tuning, WifiAdmission};
pub use session::{HostSession, WifiStreams};
pub use status::{HostStatus, menu_name};
pub use util::PowerCount;
pub use video::display_spec;
pub use warp::CursorWarpDetector;
