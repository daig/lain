//! The GNOME platform: `lain-gnome`'s parts, `lain-linux-video`, the system secret store and the daemon's setup
//! source, as one `lain_platform::Platform`. Built only by the binary (and its `#[ignore]`d live tests): its
//! parts talk to the real desktop.

use std::sync::Arc;

use lain_gnome::{Gnome, GnomeCursor, GnomeDisplay, GnomeInput, GnomePower, GnomeSettings, GnomeSetup};
use lain_linux_system::{Autostart, SystemSecretStore};
use lain_linux_video::LinuxVideo;
use lain_platform::{MonotonicClock, Platform};

use crate::setup::DaemonSetup;

/// The host's platform on GNOME. Swift: the `HostSession.Dependencies` that `HostController` builds
/// (`InputInjector`, `HostVideoPipeline.live()`, `probeSetup`), plus the parts `HostSession` makes itself.
#[derive(Clone)]
pub struct LinuxPlatform {
    pub display: GnomeDisplay,
    pub video: LinuxVideo,
    pub cursor: GnomeCursor,
    pub input: GnomeInput,
    pub power: GnomePower,
    pub settings: GnomeSettings,
    pub setup: DaemonSetup<GnomeSetup, Autostart>,
    /// One store, shared with the Wi-Fi listener.
    pub secrets: Arc<SystemSecretStore>,
    pub clock: MonotonicClock,
}

impl LinuxPlatform {
    pub fn new(gnome: Gnome, video: LinuxVideo, autostart: Autostart, secrets: Arc<SystemSecretStore>) -> Self {
        Self {
            display: gnome.display,
            video,
            cursor: gnome.cursor,
            input: gnome.input,
            power: gnome.power,
            settings: gnome.settings,
            setup: DaemonSetup::new(gnome.setup, autostart),
            secrets,
            clock: MonotonicClock,
        }
    }
}

impl Platform for LinuxPlatform {
    type Display = GnomeDisplay;
    type Video = LinuxVideo;
    type Cursor = GnomeCursor;
    type Input = GnomeInput;
    type Power = GnomePower;
    type Settings = GnomeSettings;
    type Setup = DaemonSetup<GnomeSetup, Autostart>;
    type Secrets = Arc<SystemSecretStore>;
    type Clock = MonotonicClock;

    fn display(&self) -> &GnomeDisplay {
        &self.display
    }
    fn video(&self) -> &LinuxVideo {
        &self.video
    }
    fn cursor(&self) -> &GnomeCursor {
        &self.cursor
    }
    fn input(&self) -> &GnomeInput {
        &self.input
    }
    fn power(&self) -> &GnomePower {
        &self.power
    }
    fn settings(&self) -> &GnomeSettings {
        &self.settings
    }
    fn setup(&self) -> &DaemonSetup<GnomeSetup, Autostart> {
        &self.setup
    }
    fn secrets(&self) -> &Arc<SystemSecretStore> {
        &self.secrets
    }
    fn clock(&self) -> &MonotonicClock {
        &self.clock
    }
}
