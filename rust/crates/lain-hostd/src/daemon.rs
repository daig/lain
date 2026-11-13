//! The running host: `lain-host`'s session, the Wi-Fi listener and its ad, the setup watch and the status log,
//! over any `Platform`. Swift: `HostController` (`Apps/Host/LainHostApp.swift`) and the Wi-Fi ownership of
//! `HostSession`.

use std::sync::Arc;
use std::time::Duration;

use lain_host::{HostConfig, HostSession, HostStatus};
use lain_media::HostVideoStats;
use lain_platform::{Advertiser, DisplayBackend, Platform, SetupSource};
use lain_usbmux::UsbMuxClient;
use lain_wifi::{WiFiListenerOptions, WiFiStatus};
use tokio::sync::{broadcast, mpsc, oneshot, watch};
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};

use crate::setup::SetupRefresh;
use crate::status::{log_status, video_lines};
use crate::wifi::{Command, OFF_IN_CONFIG, OFF_NO_IDENTITY, WifiActor, WifiControlError};

/// How the daemon runs, beyond `lain-host`'s [`HostConfig`].
#[derive(Debug, Clone)]
pub struct DaemonOptions {
    /// Start the Wi-Fi listener (config `wifi`). Without a host id Wi-Fi stays off whatever this says.
    pub wifi: bool,
    /// The listener's options: the wildcard by default; tests pass `WiFiListenerOptions::loopback()`.
    pub listener: WiFiListenerOptions,
    /// How often the setup is polled (Start at Login asked again); a change of the monitors is noticed at once.
    /// Swift polls every second.
    pub setup_poll: Duration,
    /// How often the video error and the peer's version note are checked for the log (Swift: every second).
    pub status_poll: Duration,
    /// How often a connected session's video numbers are logged.
    pub video_log_interval: Duration,
    /// How long a cancelled listener may take to say it stopped.
    pub wifi_stop_timeout: Duration,
    /// How long the Wi-Fi half of the shutdown (the listener cancelled, the ad withdrawn) may take before the
    /// Wi-Fi actor is aborted, so that a slow or wedged Avahi never keeps the session from stopping within
    /// main's budget. Longer than `wifi_stop_timeout`.
    pub wifi_shutdown_timeout: Duration,
    /// How long the first Start at Login read may take before the session starts anyway.
    pub setup_timeout: Duration,
}

impl Default for DaemonOptions {
    fn default() -> Self {
        Self {
            wifi: true,
            listener: WiFiListenerOptions::default(),
            setup_poll: Duration::from_secs(2),
            status_poll: Duration::from_secs(1),
            video_log_interval: Duration::from_secs(10),
            wifi_stop_timeout: Duration::from_secs(1),
            wifi_shutdown_timeout: Duration::from_millis(1500),
            setup_timeout: Duration::from_secs(3),
        }
    }
}

/// A cheap handle on the running daemon: what 4b's D-Bus service, CLI and tray read and control. Clone it
/// freely.
pub struct DaemonHandle<P: Platform> {
    session: Arc<HostSession<P>>,
    setup: P::Setup,
    wifi_status: watch::Receiver<WiFiStatus>,
    wifi_enabled: watch::Receiver<bool>,
    commands: mpsc::UnboundedSender<Command>,
}

impl<P: Platform> Clone for DaemonHandle<P> {
    fn clone(&self) -> Self {
        Self {
            session: self.session.clone(),
            setup: self.setup.clone(),
            wifi_status: self.wifi_status.clone(),
            wifi_enabled: self.wifi_enabled.clone(),
            commands: self.commands.clone(),
        }
    }
}

impl<P: Platform> DaemonHandle<P> {
    /// The session's status (Swift: `HostController.status`).
    pub fn status(&self) -> HostStatus {
        self.session.status()
    }

    pub fn status_watch(&self) -> watch::Receiver<HostStatus> {
        self.session.status_watch()
    }

    /// Every status change, in order.
    pub fn status_changes(&self) -> broadcast::Receiver<HostStatus> {
        self.session.status_changes()
    }

    /// The Wi-Fi listener's status (Swift: `HostController.wifiLine`, as `WiFiStatus::title()`). It follows
    /// whichever listener is current across runtime switches.
    pub fn wifi_status(&self) -> watch::Receiver<WiFiStatus> {
        self.wifi_status.clone()
    }

    /// Whether Wi-Fi is switched on (config, then [`set_wifi`](Self::set_wifi)). Always `false` without a host id.
    pub fn wifi_enabled(&self) -> watch::Receiver<bool> {
        self.wifi_enabled.clone()
    }

    /// Switches Wi-Fi on (a new listener, refreshed; the ad once it listens) or off (the listener cancelled, its
    /// status `Off("stopped")`; the ad withdrawn). Returns once applied. Idempotent.
    pub async fn set_wifi(&self, on: bool) -> Result<(), WifiControlError> {
        let (reply, answer) = oneshot::channel();
        self.commands.send(Command::Set(on, reply)).map_err(|_| WifiControlError::Stopped)?;
        answer.await.map_err(|_| WifiControlError::Stopped)?
    }

    /// Video back after a stop on the desktop ([`lain_host::HostSession::resume_video`]).
    pub fn resume_video(&self) -> bool {
        self.session.resume_video()
    }

    pub fn resume_after_stop(&self) -> bool {
        self.session.resume_after_stop()
    }

    pub fn set_resume_after_stop(&self, on: bool) {
        self.session.set_resume_after_stop(on)
    }

    /// Whether the computer's sound plays on the iPad ([`lain_host::HostSession::sound`]).
    pub fn sound(&self) -> bool {
        self.session.sound()
    }

    /// Changes it at run time.
    pub fn set_sound(&self, on: bool) {
        self.session.set_sound(on)
    }

    /// How long lain's display outlives the iPad leaving ([`lain_host::HostSession::display_keep_alive`]).
    pub fn display_keep_alive(&self) -> Duration {
        self.session.display_keep_alive()
    }

    /// Changes it at run time.
    pub fn set_display_keep_alive(&self, keep_for: Duration) {
        self.session.set_display_keep_alive(keep_for)
    }

    /// The live session's video numbers.
    pub fn video_stats(&self) -> Option<HostVideoStats> {
        self.session.video_stats()
    }

    /// Why the latest session has no video.
    pub fn video_error(&self) -> Option<String> {
        self.session.video_error()
    }

    /// What updating lain on the iPad would add, while it runs an older protocol.
    pub fn peer_version_note(&self) -> Option<String> {
        self.session.peer_version_note()
    }

    /// Swift's `HostController.videoLines`: `None` unless connected.
    pub fn video_lines(&self) -> Option<Vec<String>> {
        video_lines(&self.session.status(), self.session.video_stats(), self.session.video_error())
    }

    /// Resends the setup as it is cached now (Swift: `HostSession.setupChanged`). The Start at Login item is a
    /// cache: after switching autostart, call [`refresh_setup`](Self::refresh_setup) instead.
    pub fn setup_changed(&self) {
        self.session.setup_changed()
    }

    /// Asks the setup source again (Start at Login from systemd), then tells the session, so the iPad hears the
    /// new state at once rather than at the next poll. For 4b's `lain autostart on|off`, which may switch the
    /// unit through an `Autostart` of its own, whose cache isn't the daemon's.
    pub async fn refresh_setup(&self)
    where
        P::Setup: SetupRefresh,
    {
        self.setup.refresh().await;
        self.session.setup_changed();
    }
}

/// The running daemon. Swift: `HostController`, minus the menu.
///
/// Stop it with [`shutdown`](Self::shutdown). Dropped without one, it still stops: its tasks are aborted (the
/// listener with them, its port closed) and the session stops at once (input and power released, lain's display
/// removed without being awaited), but the ad isn't withdrawn (Avahi drops it when its connection closes).
pub struct Daemon<P: Platform> {
    handle: DaemonHandle<P>,
    tasks: Vec<JoinHandle<()>>,
    wifi_task: Option<JoinHandle<()>>,
    wifi_shutdown_timeout: Duration,
}

impl<P: Platform> Daemon<P>
where
    P::Setup: SetupRefresh,
{
    /// Starts the host (Swift: `HostController.init`): reads the setup once, starts the session with the
    /// Wi-Fi intake, the listener when `options.wifi` and there is a host id (Swift: `wifi: identity.map { ...
    /// }`), the ad following it when there is an advertiser, the setup watch and the status log. Must run
    /// inside a tokio runtime.
    pub async fn start<A: Advertiser>(
        platform: P,
        config: HostConfig,
        usbmux: UsbMuxClient,
        advertiser: Option<A>,
        options: DaemonOptions,
    ) -> Self {
        if tokio::time::timeout(options.setup_timeout, platform.setup().refresh()).await.is_err() {
            warn!("setup: Start at Login didn't answer within {:?}; asking again later", options.setup_timeout);
        }
        let identity = config.identity.clone();
        let versions = config.versions.versions();
        let secrets = platform.secrets().clone();
        let setup = platform.setup().clone();
        let monitors = platform.display().monitors();
        let (intake, streams) = mpsc::channel(16);
        let session = Arc::new(HostSession::start(platform, config, usbmux, Some(streams)));

        let initial = match (&identity, options.wifi) {
            (None, _) => WiFiStatus::Off(OFF_NO_IDENTITY.into()),
            (Some(_), false) => WiFiStatus::Off(OFF_IN_CONFIG.into()),
            (Some(_), true) => WiFiStatus::Starting,
        };
        let (status_tx, wifi_status) = watch::channel(initial);
        let (enabled_tx, wifi_enabled) = watch::channel(false);
        if identity.is_none() {
            warn!("Wi-Fi: off: {OFF_NO_IDENTITY}; USB only");
        }
        let mut actor = WifiActor {
            secrets,
            options: options.listener.clone(),
            intake,
            identity: identity.clone(),
            versions,
            advertiser,
            status: status_tx,
            enabled: enabled_tx,
            secrets_changed: session.secrets_changed(),
            stop_timeout: options.wifi_stop_timeout,
            listener: None,
            advertised: None,
        };
        if options.wifi && identity.is_some() {
            let _ = actor.start_listener();
        }
        let (commands, receiver) = mpsc::unbounded_channel();
        let wifi_task = tokio::spawn(actor.run(receiver));

        let handle = DaemonHandle { session, setup: setup.clone(), wifi_status, wifi_enabled, commands };
        let tasks = vec![
            tokio::spawn(watch_setup(handle.session.clone(), setup, monitors, options.setup_poll)),
            tokio::spawn(log_status(handle.clone(), options.status_poll, options.video_log_interval)),
        ];
        Self { handle, tasks, wifi_task: Some(wifi_task), wifi_shutdown_timeout: options.wifi_shutdown_timeout }
    }
}

impl<P: Platform> Daemon<P> {
    pub fn handle(&self) -> DaemonHandle<P> {
        self.handle.clone()
    }

    /// Stops everything, in order (Swift: `session.stop()` on `willTerminate`): the listener cancelled and the ad
    /// withdrawn, then the session stopped (input released, power released, lain's display destroyed; awaited),
    /// then the watch and log tasks. Returns once all of it is done.
    ///
    /// The Wi-Fi half is bounded by [`DaemonOptions::wifi_shutdown_timeout`]: past it the Wi-Fi actor is aborted
    /// (the listener dropped, its port closed; the ad left to Avahi, which drops it with the connection), so that
    /// the session's release, the part that matters (invariant 4), always runs within main's budget.
    pub async fn shutdown(mut self) {
        let handle = self.handle.clone();
        if let Some(mut wifi_task) = self.wifi_task.take() {
            let (reply, done) = oneshot::channel();
            let sent = handle.commands.send(Command::Shutdown(reply)).is_ok();
            let wifi = async {
                if sent {
                    let _ = done.await;
                }
                let _ = (&mut wifi_task).await;
            };
            if tokio::time::timeout(self.wifi_shutdown_timeout, wifi).await.is_err() {
                warn!(
                    "Wi-Fi: the listener and the ad didn't stop within {:?} (Avahi slow?); dropped them",
                    self.wifi_shutdown_timeout
                );
                wifi_task.abort();
                let _ = wifi_task.await;
            }
        }
        handle.session.stop().await;
        let tasks = std::mem::take(&mut self.tasks);
        for task in &tasks {
            task.abort();
        }
        for task in tasks {
            let _ = task.await;
        }
        info!("shutdown complete");
    }
}

impl<P: Platform> Drop for Daemon<P> {
    /// A daemon dropped without [`shutdown`](Daemon::shutdown) stops anyway. Its tasks hold the session (and the
    /// log task a command sender), so without this nothing would ever end.
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
        if let Some(wifi_task) = &self.wifi_task {
            wifi_task.abort();
        }
        // The synchronous part: input and power released, links closed; the display's removal isn't awaited.
        drop(self.handle.session.stop());
    }
}

/// Polls the setup source (Start at Login) every `poll`, and looks again at once when the monitors change (the
/// other-display check); tells the session when the report changed. Swift: `session.setupChanged()` every
/// second.
async fn watch_setup<P: Platform>(
    session: Arc<HostSession<P>>,
    setup: P::Setup,
    mut monitors: watch::Receiver<Vec<lain_platform::Monitor>>,
    poll: Duration,
) where
    P::Setup: SetupRefresh,
{
    let mut last = setup.setup();
    debug!(?last, "setup");
    let mut ticks = tokio::time::interval(poll);
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    ticks.tick().await;
    let mut monitors_open = true;
    loop {
        tokio::select! {
            _ = ticks.tick() => setup.refresh().await,
            changed = monitors.changed(), if monitors_open => {
                if changed.is_err() {
                    monitors_open = false;
                    continue;
                }
            }
        }
        let now = setup.setup();
        if now != last {
            info!(
                "setup: start at login {:?}, other display {}",
                now.items.iter().find(|(r, _)| *r == lain_platform::Requirement::StartAtLogin).map(|(_, s)| *s),
                now.has_other_display
            );
            last = now;
            session.setup_changed();
        }
    }
}
