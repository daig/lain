//! The daemon's control interface on the session bus: `dev.sub.lain.Host1` at [`OBJECT_PATH`], on the name the
//! daemon owns ([`crate::BUS_NAME`]). The `lain` CLI and the tray use it. Swift has no counterpart: the Mac
//! host's menu reads `HostController` in-process.
//!
//! Properties (each emits `PropertiesChanged` when it changes): `Status` (the status title, Swift's
//! `HostStatus.title`), `WifiStatus` (`WiFiStatus::title`), `WifiEnabled`, `VideoLines` (Swift's
//! `HostController.videoLines`; empty unless connected), `VideoProblem`, `PeerVersionNote`.
//! Methods: `SetWifi(b)` switches Wi-Fi at run time and writes `wifi` into `config.toml`, so it holds after a
//! restart; `RefreshSetup()` asks Start at Login again (the CLI calls it after `lain autostart on|off`).

use std::future::Future;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use lain_host::HostStatus;
use lain_platform::Platform;
use lain_wifi::WiFiStatus;
use tokio::sync::watch;
use tracing::{info, warn};

use crate::config::set_top_level_bool;
use crate::daemon::DaemonHandle;
use crate::setup::SetupRefresh;
use crate::wifi::WifiControlError;

/// Where the interface lives.
pub const OBJECT_PATH: &str = "/dev/sub/lain/Host";
/// Its name.
pub const INTERFACE: &str = "dev.sub.lain.Host1";

type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// What the interface and the tray read and control: a [`DaemonHandle`] over any platform, as a trait object.
pub trait Control: Send + Sync + 'static {
    fn status_watch(&self) -> watch::Receiver<HostStatus>;
    fn wifi_status(&self) -> watch::Receiver<WiFiStatus>;
    fn wifi_enabled(&self) -> watch::Receiver<bool>;
    fn video_lines(&self) -> Vec<String>;
    fn video_problem(&self) -> String;
    fn peer_version_note(&self) -> String;
    fn set_wifi(&self, on: bool) -> BoxFuture<'_, Result<(), WifiControlError>>;
    fn refresh_setup(&self) -> BoxFuture<'_, ()>;
    fn keep_alive_seconds(&self) -> u32;
    fn set_keep_alive_seconds(&self, seconds: u32);
    /// The scale setting (`None`: the iPad's own). Platforms without one say `None` and ignore changes.
    fn scale_setting(&self) -> Option<f64> {
        None
    }
    /// lain's display's scale now, if it exists.
    fn applied_scale(&self) -> Option<f64> {
        None
    }
    /// The scales the desktop offers for lain's display (empty without a display).
    fn scale_options(&self) -> Vec<f64> {
        Vec::new()
    }
    fn set_scale(&self, _scale: Option<f64>) {}
}

impl<P: Platform> Control for DaemonHandle<P>
where
    P::Setup: SetupRefresh,
{
    fn status_watch(&self) -> watch::Receiver<HostStatus> {
        DaemonHandle::status_watch(self)
    }
    fn wifi_status(&self) -> watch::Receiver<WiFiStatus> {
        DaemonHandle::wifi_status(self)
    }
    fn wifi_enabled(&self) -> watch::Receiver<bool> {
        DaemonHandle::wifi_enabled(self)
    }
    fn video_lines(&self) -> Vec<String> {
        DaemonHandle::video_lines(self).unwrap_or_default()
    }
    fn video_problem(&self) -> String {
        DaemonHandle::video_error(self).unwrap_or_default()
    }
    fn peer_version_note(&self) -> String {
        DaemonHandle::peer_version_note(self).unwrap_or_default()
    }
    fn set_wifi(&self, on: bool) -> BoxFuture<'_, Result<(), WifiControlError>> {
        Box::pin(DaemonHandle::set_wifi(self, on))
    }
    fn refresh_setup(&self) -> BoxFuture<'_, ()> {
        Box::pin(DaemonHandle::refresh_setup(self))
    }
    fn keep_alive_seconds(&self) -> u32 {
        self.display_keep_alive().as_secs().try_into().unwrap_or(u32::MAX)
    }
    fn set_keep_alive_seconds(&self, seconds: u32) {
        self.set_display_keep_alive(Duration::from_secs(u64::from(seconds)))
    }
}

fn persist(config: Option<&PathBuf>, key: &str, value: Option<String>) -> Result<(), String> {
    match config {
        Some(path) => crate::config::set_top_level(path, key, value.as_deref())
            .map_err(|e| format!("{key} applied, but {} couldn't be updated: {e}", path.display())),
        None => Ok(()),
    }
}

/// Sets the scale (`None`: the iPad's own), now and in `config.toml`; refused out of bounds.
pub fn set_scale_persisted(control: &dyn Control, config: Option<&PathBuf>, scale: Option<f64>) -> Result<(), String> {
    if let Some(s) = scale {
        let (lo, hi) = crate::config::SCALE;
        if !(s.is_finite() && (lo..=hi).contains(&s)) {
            return Err(format!("the scale must be between {lo} and {hi}, not {s}"));
        }
    }
    control.set_scale(scale);
    persist(config, "scale", scale.map(|s| format!("{s:?}")))
}

/// Sets the display keep-alive, now and in `config.toml`; refused out of bounds.
pub fn set_keep_alive_persisted(control: &dyn Control, config: Option<&PathBuf>, seconds: u32) -> Result<(), String> {
    let (lo, hi) = crate::config::KEEP_ALIVE_SECONDS;
    if !(lo..=hi).contains(&seconds) {
        return Err(format!("the keep-alive must be between {lo} and {hi} seconds, not {seconds}"));
    }
    control.set_keep_alive_seconds(seconds);
    persist(config, "keep_alive_seconds", Some(seconds.to_string()))
}

/// Sets the bitrate in `config.toml`; it applies once the daemon restarts.
pub fn set_bitrate_persisted(config: Option<&PathBuf>, mbps: u32) -> Result<(), String> {
    let (lo, hi) = crate::config::BITRATE_MBPS;
    if !(lo..=hi).contains(&mbps) {
        return Err(format!("the bitrate must be between {lo} and {hi} Mb/s, not {mbps}"));
    }
    persist(config, "bitrate_mbps", Some(mbps.to_string()))
}

/// Switches Wi-Fi and records it in `config.toml` (when there is one to write: the daemon's own path).
pub async fn set_wifi_persisted(control: &dyn Control, config: Option<&PathBuf>, on: bool) -> Result<(), String> {
    control.set_wifi(on).await.map_err(|e| e.to_string())?;
    if let Some(path) = config
        && let Err(e) = set_top_level_bool(path, "wifi", on)
    {
        warn!(path = %path.display(), "Wi-Fi switched, but not written to the config: {e}");
        return Err(format!(
            "Wi-Fi is {}, but {} couldn't be updated: {e}",
            if on { "on" } else { "off" },
            path.display()
        ));
    }
    Ok(())
}

pub struct HostService {
    control: Arc<dyn Control>,
    config: Option<PathBuf>,
}

#[zbus::interface(name = "dev.sub.lain.Host1")]
impl HostService {
    #[zbus(property)]
    fn status(&self) -> String {
        self.control.status_watch().borrow().title()
    }

    #[zbus(property)]
    fn wifi_status(&self) -> String {
        self.control.wifi_status().borrow().title()
    }

    #[zbus(property)]
    fn wifi_enabled(&self) -> bool {
        *self.control.wifi_enabled().borrow()
    }

    #[zbus(property)]
    fn video_lines(&self) -> Vec<String> {
        self.control.video_lines()
    }

    #[zbus(property)]
    fn video_problem(&self) -> String {
        self.control.video_problem()
    }

    #[zbus(property)]
    fn peer_version_note(&self) -> String {
        self.control.peer_version_note()
    }

    /// Switches Wi-Fi now and in `config.toml`.
    async fn set_wifi(&self, on: bool) -> zbus::fdo::Result<()> {
        info!(on, "Wi-Fi switched over D-Bus");
        set_wifi_persisted(&*self.control, self.config.as_ref(), on).await.map_err(zbus::fdo::Error::Failed)
    }

    /// The scale setting; 0: the iPad's own.
    #[zbus(property)]
    fn scale(&self) -> f64 {
        self.control.scale_setting().unwrap_or(0.0)
    }

    /// lain's display's scale now; 0 without a display.
    #[zbus(property)]
    fn applied_scale(&self) -> f64 {
        self.control.applied_scale().unwrap_or(0.0)
    }

    /// The scales the desktop offers for lain's display (empty without a display).
    #[zbus(property)]
    fn scale_options(&self) -> Vec<f64> {
        self.control.scale_options()
    }

    #[zbus(property)]
    fn keep_alive_seconds(&self) -> u32 {
        self.control.keep_alive_seconds()
    }

    /// Sets the scale now and in `config.toml`; 0: the iPad's own. The closest the desktop supports is applied.
    async fn set_scale(
        &self,
        scale: f64,
        #[zbus(signal_emitter)] emitter: zbus::object_server::SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        let scale = (scale > 0.0).then_some(scale);
        info!(?scale, "scale set over D-Bus");
        set_scale_persisted(&*self.control, self.config.as_ref(), scale).map_err(zbus::fdo::Error::Failed)?;
        let _ = self.scale_changed(&emitter).await;
        Ok(())
    }

    /// Sets the display keep-alive now and in `config.toml`.
    async fn set_keep_alive(
        &self,
        seconds: u32,
        #[zbus(signal_emitter)] emitter: zbus::object_server::SignalEmitter<'_>,
    ) -> zbus::fdo::Result<()> {
        info!(seconds, "keep-alive set over D-Bus");
        set_keep_alive_persisted(&*self.control, self.config.as_ref(), seconds).map_err(zbus::fdo::Error::Failed)?;
        let _ = self.keep_alive_seconds_changed(&emitter).await;
        Ok(())
    }

    /// Sets the bitrate in `config.toml`; it applies after a restart (`systemctl --user restart lain-hostd`).
    async fn set_bitrate(&self, mbps: u32) -> zbus::fdo::Result<()> {
        set_bitrate_persisted(self.config.as_ref(), mbps).map_err(zbus::fdo::Error::Failed)
    }

    /// Reads Start at Login again and tells the iPad if it changed.
    async fn refresh_setup(&self) {
        self.control.refresh_setup().await;
    }
}

/// Serves the interface on `conn` (which owns [`crate::BUS_NAME`]) until the connection closes, with change
/// notifications: status and Wi-Fi at once, the video lines every 2 s while they change.
pub async fn serve(conn: &zbus::Connection, control: Arc<dyn Control>, config: Option<PathBuf>) -> zbus::Result<()> {
    let server = conn.object_server();
    server.at(OBJECT_PATH, HostService { control: control.clone(), config }).await?;
    let iface = server.interface::<_, HostService>(OBJECT_PATH).await?;
    tokio::spawn(async move {
        let (mut status, mut wifi, mut enabled) =
            (control.status_watch(), control.wifi_status(), control.wifi_enabled());
        let mut tick = tokio::time::interval(Duration::from_secs(2));
        let mut last = (Vec::new(), String::new(), String::new());
        let mut last_scale = (None, Vec::new());
        loop {
            #[derive(PartialEq)]
            enum Changed {
                Status,
                Wifi,
                Enabled,
                Tick,
            }
            let changed = tokio::select! {
                Ok(()) = status.changed() => Changed::Status,
                Ok(()) = wifi.changed() => Changed::Wifi,
                Ok(()) = enabled.changed() => Changed::Enabled,
                _ = tick.tick() => Changed::Tick,
                else => break,
            };
            let emitter = iface.signal_emitter();
            let service = iface.get().await;
            match changed {
                Changed::Status => {
                    let _ = service.status_changed(emitter).await;
                }
                Changed::Wifi => {
                    let _ = service.wifi_status_changed(emitter).await;
                }
                Changed::Enabled => {
                    let _ = service.wifi_enabled_changed(emitter).await;
                }
                Changed::Tick => {
                    let now = (control.video_lines(), control.video_problem(), control.peer_version_note());
                    let scale = (control.applied_scale(), control.scale_options());
                    if scale != last_scale {
                        let _ = service.applied_scale_changed(emitter).await;
                        let _ = service.scale_options_changed(emitter).await;
                        last_scale = scale;
                    }
                    if now.0 != last.0 {
                        let _ = service.video_lines_changed(emitter).await;
                    }
                    if now.1 != last.1 {
                        let _ = service.video_problem_changed(emitter).await;
                    }
                    if now.2 != last.2 {
                        let _ = service.peer_version_note_changed(emitter).await;
                    }
                    last = now;
                }
            }
        }
    });
    Ok(())
}
