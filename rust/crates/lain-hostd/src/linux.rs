//! The GNOME platform: `lain-gnome`'s parts, `lain-linux-video`, the system secret store and the daemon's setup
//! source, as one `lain_platform::Platform`. Built only by the binary (and its `#[ignore]`d live tests): its
//! parts talk to the real desktop.

use std::sync::Arc;

use lain_gnome::{Gnome, GnomeCursor, GnomeDisplay, GnomeInput, GnomePower, GnomeSettings, GnomeSetup};
use lain_linux_audio::PipeWireAudio;
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
    pub audio: PipeWireAudio,
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
            audio: PipeWireAudio::default(),
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
    type Audio = PipeWireAudio;

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
    fn audio(&self) -> &PipeWireAudio {
        &self.audio
    }
}

/// The daemon's control on GNOME: [`crate::DaemonHandle`]'s, plus lain's display's scale, which `lain-gnome` owns.
pub struct LinuxControl {
    pub handle: crate::DaemonHandle<LinuxPlatform>,
    pub display: GnomeDisplay,
}

impl crate::Control for LinuxControl {
    fn status_watch(&self) -> tokio::sync::watch::Receiver<lain_host::HostStatus> {
        self.handle.status_watch()
    }
    fn wifi_status(&self) -> tokio::sync::watch::Receiver<lain_wifi::WiFiStatus> {
        self.handle.wifi_status()
    }
    fn wifi_enabled(&self) -> tokio::sync::watch::Receiver<bool> {
        self.handle.wifi_enabled()
    }
    fn video_lines(&self) -> Vec<String> {
        crate::Control::video_lines(&self.handle)
    }
    fn video_problem(&self) -> String {
        crate::Control::video_problem(&self.handle)
    }
    fn peer_version_note(&self) -> String {
        crate::Control::peer_version_note(&self.handle)
    }
    fn set_wifi(
        &self,
        on: bool,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), crate::WifiControlError>> + Send + '_>> {
        crate::Control::set_wifi(&self.handle, on)
    }
    fn refresh_setup(&self) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + '_>> {
        crate::Control::refresh_setup(&self.handle)
    }
    fn keep_alive_seconds(&self) -> u32 {
        crate::Control::keep_alive_seconds(&self.handle)
    }
    fn set_keep_alive_seconds(&self, seconds: u32) {
        crate::Control::set_keep_alive_seconds(&self.handle, seconds)
    }
    fn resume_video(&self) -> bool {
        crate::Control::resume_video(&self.handle)
    }
    fn resume_after_stop(&self) -> bool {
        crate::Control::resume_after_stop(&self.handle)
    }
    fn set_resume_after_stop(&self, on: bool) {
        crate::Control::set_resume_after_stop(&self.handle, on)
    }
    fn sound(&self) -> bool {
        crate::Control::sound(&self.handle)
    }
    fn set_sound(&self, on: bool) {
        crate::Control::set_sound(&self.handle, on)
    }
    fn scale_setting(&self) -> Option<f64> {
        self.display.scale_setting()
    }
    fn applied_scale(&self) -> Option<f64> {
        self.display.applied_scale()
    }
    fn scale_options(&self) -> Vec<f64> {
        self.display.scale_options()
    }
    fn set_scale(&self, scale: Option<f64>) {
        self.display.set_scale(scale)
    }
}
