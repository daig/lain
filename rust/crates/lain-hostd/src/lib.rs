//! The lain host daemon, wave 4a: the process that composes the GNOME platform (`lain-gnome`,
//! `lain-linux-video`, `lain-linux-system`), `lain-host`'s session, `lain-wifi`'s listener and the Avahi ad into
//! a running host, with its config file and its status in the log. Wave 4b adds the D-Bus control interface on
//! [`BUS_NAME`], the `lain` CLI, the tray and the install script, on [`DaemonHandle`].
//!
//! Swift reference (behaviour): `Apps/Host/LainHostApp.swift` (`LainHostEntry`, `HostController`),
//! `Packages/LainKit/Sources/LainHostCore/HostStatus.swift`. Brief: `docs/LINUX-HOST-PLAN.md`, `lain-hostd`.
//!
//! - [`Config`], the settings in `config.toml`.
//! - [`Daemon`] and [`DaemonHandle`]: the running host over any `Platform` (fakes in the tests).
//! - [`DaemonSetup`]: the `SetupSource`, the platform's report plus Start at Login.
//! - [`LinuxPlatform`]: the real composition's platform (built by the binary only).
//! - [`process`]: the video environment re-exec and the open-file limit, decided by pure functions.
//! - [`claim_bus_name`]: single instance.

mod bus;
pub mod config;
mod daemon;
mod linux;
pub mod process;
mod setup;
mod status;
mod wifi;

pub use bus::{BUS_NAME, claim_bus_name, claim_name};
pub use config::{CONFIG_FILE, Config, ConfigError};
pub use daemon::{Daemon, DaemonHandle, DaemonOptions};
pub use linux::LinuxPlatform;
pub use setup::{DaemonSetup, LoginItem, SetupRefresh};
pub use status::video_lines;
pub use wifi::{OFF_IN_CONFIG, OFF_NO_IDENTITY, WifiControlError};

/// The log filter when `RUST_LOG` isn't set: info for lain's crates, warn for the rest.
pub const DEFAULT_LOG_FILTER: &str = "warn,lain_hostd=info,lain_host=info,lain_wifi=info,lain_link=info,\
                                      lain_usbmux=info,lain_media=info,lain_input=info,lain_gnome=info,\
                                      lain_linux_video=info,lain_linux_system=info,lain_platform=info,\
                                      lain_proto=info";
