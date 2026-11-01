//! The session engine (Swift: `LainHostCore/Session/HostSession.swift`, `HostSession`).

use std::collections::{HashMap, HashSet};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, MutexGuard, Weak};

use lain_link::{
    AcceptedLink, AcceptorOptions, ByteStream, HostLink, Link, LinkAcceptor, LinkTransport, Pairing, TransportError,
    VersionGap,
};
use lain_media::{HostVideoStats, VideoEnd};
use lain_platform::{Platform, SettingsSource, SetupSource};
use lain_proto::{
    AudioEncoding, ChromaFormat, DisplayMode, ErrorCode, ErrorMessage, Hello, HelloAck, Message, ProtocolFeature,
    VideoCodec,
};
use lain_usbmux::{UsbMuxClient, UsbMuxDevice, UsbMuxError, UsbMuxEvent};
use tokio::sync::{broadcast, mpsc, watch};
use tokio::time::Instant;
use tracing::{debug, error, info, warn};

use crate::config::HostConfig;
use crate::connection::{HostConnection, host_setup};
use crate::keeper::DisplayKeeper;
use crate::status::HostStatus;
use crate::util::{Cancel, Power, UsbMuxDialer};
use crate::video::{SessionVideo, StartError, Streaming, display_spec};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// The streams of TLS-authenticated network connections the daemon hands in from `lain-wifi`'s listener.
/// Each has `pairing_secret()` set and `link_transport()` = `Network { interface, peer_to_peer: false }`.
pub type WifiStreams = mpsc::Receiver<Box<dyn ByteStream>>;

/// Who owns the live session (§7.7 D29 decision 8): a USB connect loop or an accepted network link,
/// numbered from the one generation counter, so a stale owner can't claim or end a session. Swift:
/// `HostSession.Owner`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Owner {
    Usb(u64),
    Wifi(u64),
}

struct DeviceLoop {
    id: u32,
    generation: u64,
    cancel: Cancel,
}

struct Live<P: Platform> {
    owner: Owner,
    connection: Arc<HostConnection<P>>,
    transport: LinkTransport,
    /// The iPad: its USB serial, the account its secret is stored under.
    peer: String,
}

/// What a claim returns: the displaced session, and every earlier session's video still being torn down.
type Claimed<P> = (Option<Arc<HostConnection<P>>>, Vec<Arc<SessionVideo>>);

/// Swift: `HostSession.State`; each field says the same as there.
struct State<P: Platform> {
    status: HostStatus,
    stopped: bool,
    /// The USB device being dialed or connected; its generation identifies its connect loop.
    device: Option<DeviceLoop>,
    /// The one counter behind USB connect loops and accepted network links.
    generation: u64,
    /// Every USB device usbmuxd reports, in attach order. Only `device` is dialed.
    attached: Vec<UsbMuxDevice>,
    /// When each attached device's USB attempt began (the USB preference window).
    usb_since: HashMap<u32, Instant>,
    /// Attached devices not dialed since their attach.
    undialed: HashSet<u32>,
    live: Option<Live<P>>,
    /// The live session's device model once its `HelloAck` went out: the status says connected.
    live_model: Option<String>,
    /// The newest accepted network link's task: its `Hello` wait, then its session.
    wifi: Option<(u64, Cancel)>,
    /// The latest session's video, for the status.
    video: Option<Arc<SessionVideo>>,
    /// Every claimed session's video until that session has waited out its teardown.
    retiring: Vec<Arc<SessionVideo>>,
    /// Why the latest session has no video.
    video_error: Option<String>,
    capture_failures: u32,
    capture_backoff_until: Option<Instant>,
    capture_failed_peer: Option<String>,
    /// The USB connect loop (its generation) waiting out the capture backoff.
    backing_off: Option<u64>,
    /// usbmuxd failed (other than not running or going away, which is normal on Linux); cleared by the next
    /// attach.
    usbmux_down: bool,
    /// lain on the iPad shares no protocol version with this one.
    peer_gap: Option<VersionGap>,
}

impl<P: Platform> State<P> {
    fn new() -> Self {
        Self {
            status: HostStatus::WaitingForIPad,
            stopped: false,
            device: None,
            generation: 0,
            attached: Vec::new(),
            usb_since: HashMap::new(),
            undialed: HashSet::new(),
            live: None,
            live_model: None,
            wifi: None,
            video: None,
            retiring: Vec::new(),
            video_error: None,
            capture_failures: 0,
            capture_backoff_until: None,
            capture_failed_peer: None,
            backing_off: None,
            usbmux_down: false,
            peer_gap: None,
        }
    }

    /// The status is derived, never pushed (decision 8): connected only while the session whose `HelloAck`
    /// went out is live; otherwise what the USB side is doing.
    fn derived_status(&self, config: &HostConfig) -> HostStatus {
        if let (Some(live), Some(model)) = (&self.live, &self.live_model) {
            return HostStatus::Connected { device_model: model.clone(), via: live.transport.clone() };
        }
        if self.usbmux_down {
            return HostStatus::Error("usbmuxd unavailable".into());
        }
        if let Some(gap) = &self.peer_gap {
            return HostStatus::version_gap(gap, &config.versions);
        }
        match &self.device {
            None => HostStatus::WaitingForIPad,
            Some(d) if self.backing_off == Some(d.generation) => HostStatus::capture_backing_off(),
            Some(_) => HostStatus::Connecting,
        }
    }

    /// Registers `connection` as the live session for `owner` (Swift: `State.claim`). Refused (`None`) when
    /// stopped, cancelled, or the owner is stale. A USB claim displaces a live network session; a network
    /// claim displaces an older network session (the same iPad's). The displaced session's video stops here.
    fn claim(
        &mut self,
        connection: &Arc<HostConnection<P>>,
        owner: Owner,
        transport: LinkTransport,
        peer: String,
        cancelled: bool,
    ) -> Option<Claimed<P>> {
        if self.stopped || cancelled {
            return None;
        }
        match owner {
            Owner::Usb(g) => {
                if self.device.as_ref().map(|d| d.generation) != Some(g) {
                    return None;
                }
            }
            Owner::Wifi(g) => {
                if self.wifi.as_ref().map(|w| w.0) != Some(g) {
                    return None;
                }
                if matches!(self.live.as_ref().map(|l| l.owner), Some(Owner::Usb(_))) {
                    return None;
                }
            }
        }
        let displaced = self.live.take().map(|l| l.connection);
        if let Some(d) = &displaced {
            d.video.stop(); // now, not once the claimer finishes it
        }
        self.live = Some(Live { owner, connection: connection.clone(), transport, peer });
        self.live_model = None;
        let previous = self.retiring.clone();
        self.retiring.push(connection.video.clone());
        self.video = Some(connection.video.clone());
        self.video_error = None;
        Some((displaced, previous))
    }

    /// The live connection if `owner` owns it, taken out (Swift: `takeLive(ownedBy:)`).
    fn take_live(&mut self, owner: Owner) -> Option<Arc<HostConnection<P>>> {
        if self.live.as_ref().map(|l| l.owner) != Some(owner) {
            return None;
        }
        self.live_model = None;
        self.live.take().map(|l| l.connection)
    }

    /// Why a network link from `peer` may not start a session now (answered `Error(busy)`), or `None`
    /// (Swift: `State.wifiBusy`). USB wins; the capture backoff holds every transport; one iPad at a time.
    fn wifi_busy(&self, peer: &str, now: Instant, preference: std::time::Duration) -> Option<&'static str> {
        if matches!(self.live.as_ref().map(|l| l.owner), Some(Owner::Usb(_))) {
            return Some("a USB session is live");
        }
        if let Some(until) = self.capture_backoff_until
            && now < until
        {
            return Some(HostStatus::CAPTURE_BACKING_OFF);
        }
        for d in self.attached.iter().filter(|d| d.serial_number == peer) {
            if let Some(since) = self.usb_since.get(&d.device_id)
                && now.saturating_duration_since(*since) < preference
            {
                return Some("this iPad is on USB");
            }
        }
        if let Some(live) = &self.live
            && live.peer != peer
        {
            return Some("another iPad is connected");
        }
        None
    }

    /// The session-wide capture backoff, when `peer`'s session has ended (Swift: `sessionEnded`).
    fn session_ended(&mut self, peer: &str, capture_failed: bool, retry: std::time::Duration) {
        if !capture_failed {
            self.capture_failures = 0;
            self.capture_failed_peer = None;
            return;
        }
        self.capture_failures += 1;
        self.capture_failed_peer = Some(peer.to_owned());
        if self.capture_failures <= 1 {
            return;
        }
        let factor = 1u32 << (self.capture_failures - 2).min(5);
        self.capture_backoff_until = Some(Instant::now() + retry * factor);
    }

    /// The owner plugged in the iPad whose sessions kept failing capture (Swift: `resetCaptureBackoff`).
    fn reset_capture_backoff(&mut self) {
        self.capture_failures = 0;
        self.capture_backoff_until = None;
        self.capture_failed_peer = None;
    }
}

/// usbmuxd isn't running, or closed the connection under us (exiting after the last unplug, or starting):
/// on Linux that means no iOS device is attached (SL4), not that usbmuxd is broken. Intended difference from
/// Swift, which reports every usbmuxd failure as an error (the Mac's daemon never exits). Protocol errors, a
/// non-zero `Result`, a timeout and other socket errors still are.
fn daemon_went_away(e: &UsbMuxError) -> bool {
    match e {
        UsbMuxError::Unavailable { .. } | UsbMuxError::Closed => true,
        UsbMuxError::Io { source, .. } => matches!(
            source.kind(),
            std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::BrokenPipe | std::io::ErrorKind::UnexpectedEof
        ),
        _ => false,
    }
}

struct Inner<P: Platform> {
    platform: Arc<P>,
    config: HostConfig,
    usbmux: UsbMuxClient,
    power: Arc<Power<P::Power>>,
    state: Mutex<State<P>>,
    status: watch::Sender<HostStatus>,
    statuses: broadcast::Sender<HostStatus>,
    secrets_changed: watch::Sender<u64>,
    acceptor: Mutex<Option<LinkAcceptor<P::Secrets>>>,
    /// Ends the usbmuxd watcher and the network intake.
    run: Cancel,
    /// lain's display between sessions ([`HostConfig::display_keep_alive`]).
    keeper: Arc<DisplayKeeper<P::Display>>,
    /// [`HostConfig::resume_after_stop`], changeable at run time.
    resume_after_stop: std::sync::atomic::AtomicBool,
    /// When video was last resumed by itself after a stop on the desktop.
    last_auto_resume: Mutex<Option<Instant>>,
}

/// The video error after the owner stopped lain's display on the desktop.
const STOPPED_ON_THE_DESKTOP: &str = "capture stopped on the desktop";

/// The least time between two automatic resumes after a stop on the desktop ([`HostConfig::resume_after_stop`]):
/// a second stop within it stays stopped (input only) until `resume_video`.
pub const RESUME_AFTER_STOP_MIN_GAP: std::time::Duration = std::time::Duration::from_secs(10);

/// The host runtime (Swift: `HostSession`, §5.7): watches usbmuxd, dials lain on an attached iPad, admits
/// the network links the daemon hands in, and runs one session at a time: the virtual display and its video,
/// `HelloAck`, the desktop's `DisplayLayout` (right after `HelloAck`, and on every change), `HostSetup` at v4
/// and later, input into the platform, `Pong`s, cursor warps, and the platform kept awake while connected.
/// It reconnects on its own when the client comes back (app relaunched, cable replugged).
///
/// One session at a time, owned by a USB connect loop or a network link; USB wins (§7.7 D29 decision 8): a
/// USB session takes over from a network one, a network link while USB is live or preferred is answered
/// `Error(busy)`, and the same iPad's newer network link takes over from its older one.
///
/// Invariants 3 and 4: input is handled synchronously in the realtime reader's task; every session end (link
/// close, USB detach, a takeover, [`stop`](Self::stop)) releases all input exactly once, after the last input
/// of that session.
///
/// Intended differences from Swift:
/// - Generic over a [`Platform`] (static dispatch) instead of `Dependencies`' existentials. The network side
///   is a stream of already-authenticated streams ([`WifiStreams`]): `lain-wifi`'s listener, wired by the
///   daemon, owns TLS, its PSKs and their refresh. This engine owns the one [`LinkAcceptor`] (as Swift's
///   `HostSession` does) and signals [`secrets_changed`](Self::secrets_changed) where Swift calls
///   `wifiListener.refresh()`.
/// - usbmuxd not running ([`UsbMuxError::Unavailable`]), closing the connection under us and its event
///   stream ending are "no iPad", not an error: on Linux the daemon exits after the last iOS device is
///   unplugged (SL4). It is polled for every
///   [`Tuning::usbmux_retry_interval`](crate::Tuning::usbmux_retry_interval).
/// - The virtual display is made for the client's `Hello` ([`display_spec`](crate::display_spec)).
/// - The status is a watch ([`status_watch`](Self::status_watch)) plus every change in order
///   ([`status_changes`](Self::status_changes)), for Swift's `onStatus`.
/// - `stop` does Swift's synchronous part (input released, power dropped) when called, and returns a future
///   that waits until the session's display is gone.
pub struct HostSession<P: Platform> {
    inner: Arc<Inner<P>>,
}

impl<P: Platform> HostSession<P> {
    /// Starts watching usbmuxd and, given `wifi`, admitting the network links it carries (Swift: `init`
    /// followed by `start()`). Must be called inside a tokio runtime.
    pub fn start(platform: P, config: HostConfig, usbmux: UsbMuxClient, wifi: Option<WifiStreams>) -> Self {
        let power = Arc::new(Power::new(platform.power().clone()));
        let (statuses, _) = broadcast::channel(256);
        let keeper = DisplayKeeper::new(platform.display().clone(), config.display_keep_alive);
        let resume_after_stop = std::sync::atomic::AtomicBool::new(config.resume_after_stop);
        let inner = Arc::new(Inner {
            keeper,
            resume_after_stop,
            last_auto_resume: Mutex::new(None),
            platform: Arc::new(platform),
            config,
            usbmux,
            power,
            state: Mutex::new(State::new()),
            status: watch::Sender::new(HostStatus::WaitingForIPad),
            statuses,
            secrets_changed: watch::Sender::new(0),
            acceptor: Mutex::new(None),
            run: Cancel::new(),
        });
        if let Some(streams) = wifi {
            inner.start_wifi(streams);
        }
        let watcher = inner.clone();
        tokio::spawn(async move { watcher.watch_usb().await });
        Self { inner }
    }

    pub fn status(&self) -> HostStatus {
        self.inner.status.borrow().clone()
    }

    /// The status, as a watch (the latest value).
    pub fn status_watch(&self) -> watch::Receiver<HostStatus> {
        self.inner.status.subscribe()
    }

    /// Every status change from now on, in order (Swift: `onStatus`). A receiver that falls 256 changes
    /// behind loses the oldest.
    pub fn status_changes(&self) -> broadcast::Receiver<HostStatus> {
        self.inner.statuses.subscribe()
    }

    /// A counter bumped after every USB link-up (which may have paired, here or in another process) and every
    /// pairing, even one whose loop was cancelled as it completed: the daemon re-reads the Wi-Fi listener's
    /// PSKs then (Swift: `wifiListener.refresh()`).
    pub fn secrets_changed(&self) -> watch::Receiver<u64> {
        self.inner.secrets_changed.subscribe()
    }

    /// The live session's video numbers (`None` when no session streams).
    pub fn video_stats(&self) -> Option<HostVideoStats> {
        let s = lock(&self.inner.state);
        s.live.as_ref()?;
        s.video.as_ref()?.stats()
    }

    /// Why the latest session streams no video, if it failed to start or the owner stopped it.
    /// Video back after the owner stopped it on the desktop: closes the live session's link, and the iPad's
    /// reconnect starts a fresh session with a new display. `false` if there is no session, or its video wasn't
    /// stopped on the desktop. New in the port (the tray's and `lain resume`'s control).
    pub fn resume_video(&self) -> bool {
        self.inner.resume_video()
    }

    pub fn resume_after_stop(&self) -> bool {
        self.inner.resume_after_stop.load(Ordering::Relaxed)
    }

    /// [`HostConfig::resume_after_stop`] at run time.
    pub fn set_resume_after_stop(&self, on: bool) {
        self.inner.resume_after_stop.store(on, Ordering::Relaxed);
    }

    /// How long lain's display outlives a session whose link went away ([`HostConfig::display_keep_alive`]).
    pub fn display_keep_alive(&self) -> std::time::Duration {
        self.inner.keeper.keep_for()
    }

    /// Changes it at run time (the daemon's `lain keep-alive`); a display kept now keeps its time.
    pub fn set_display_keep_alive(&self, keep_for: std::time::Duration) {
        self.inner.keeper.set_keep_for(keep_for);
    }

    pub fn video_error(&self) -> Option<String> {
        lock(&self.inner.state).video_error.clone()
    }

    /// The live session runs an older protocol than this host's newest: a line naming what updating lain on
    /// the iPad adds (PROTOCOL-VERSIONING §8). `None` otherwise.
    pub fn peer_version_note(&self) -> Option<String> {
        let connection = lock(&self.inner.state).live.as_ref()?.connection.clone();
        let missing = connection.older_peer_misses();
        if missing.is_empty() {
            return None;
        }
        let what: Vec<_> = missing.iter().map(|f| f.summary()).collect();
        Some(format!("lain on the iPad is older (protocol v{}): update it for {}", connection.version, what.join(", ")))
    }

    /// The setup changed (autostart toggled, a monitor attached): the live session's iPad hears about it if
    /// its version has `HostSetup`. Cheap when nothing changed.
    pub fn setup_changed(&self) {
        let connection = lock(&self.inner.state).live.as_ref().map(|l| l.connection.clone());
        if let Some(connection) = connection {
            self.inner.send_setup(&connection);
        }
    }

    /// Diagnostics (Swift: the tests' `usbDeviceDialed`): the USB device whose connect loop runs.
    pub fn usb_device_dialed(&self) -> Option<u32> {
        lock(&self.inner.state).device.as_ref().map(|d| d.id)
    }

    /// Diagnostics: that connect loop's generation (a re-attach or a usbmuxd restart starts a new one).
    pub fn usb_connect_loop(&self) -> Option<u64> {
        lock(&self.inner.state).device.as_ref().map(|d| d.generation)
    }

    /// Diagnostics: an accepted network link is waiting for its `Hello` or running a session. The live
    /// network session counts even once a newer link has taken the network slot and ended (refused busy,
    /// timed out before its `Hello`, closed).
    pub fn has_wifi_link(&self) -> bool {
        let s = lock(&self.inner.state);
        s.wifi.is_some() || matches!(s.live.as_ref().map(|l| l.owner), Some(Owner::Wifi(_)))
    }

    /// Ends everything: releases all input (invariant 4) and the power assertion, and stops admitting network
    /// links, before it returns (as Swift's synchronous `stop()`); the future it returns waits until the
    /// session's display is gone. Idempotent.
    pub fn stop(&self) -> impl Future<Output = ()> + Send + 'static {
        let videos = self.inner.stop_now();
        let keeper = self.inner.keeper.clone();
        async move {
            for video in videos {
                video.wait_until_stopped().await;
            }
            keeper.clear().await;
        }
    }
}

impl<P: Platform> Drop for HostSession<P> {
    /// Dropping the session stops it, without waiting for the display's removal.
    fn drop(&mut self) {
        self.inner.stop_now();
        // A display kept for a return that won't come: removed in the background, as the session's own is.
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            let keeper = self.inner.keeper.clone();
            runtime.spawn(async move { keeper.clear().await });
        }
    }
}

impl<P: Platform> Inner<P> {
    // MARK: Status

    /// Applies `update` and publishes the derived status if it changed, under the lock, so changes go out
    /// in order. Once stopped, only `WaitingForIPad` is taken.
    fn update_status<R>(&self, update: impl FnOnce(&mut State<P>) -> R) -> R {
        let mut s = lock(&self.state);
        let r = update(&mut s);
        self.refresh_status(&mut s);
        r
    }

    fn refresh_status(&self, s: &mut State<P>) {
        let new = s.derived_status(&self.config);
        if s.status == new || (s.stopped && new != HostStatus::WaitingForIPad) {
            return;
        }
        s.status = new.clone();
        debug!(status = %new.title(), "status");
        self.status.send_replace(new.clone());
        let _ = self.statuses.send(new);
    }

    fn resume_video(&self) -> bool {
        let connection = {
            let s = lock(&self.state);
            match (&s.live, &s.video_error) {
                (Some(live), Some(e)) if e == STOPPED_ON_THE_DESKTOP => live.connection.clone(),
                _ => return false,
            }
        };
        info!("resuming video: closing the link so that the iPad reconnects");
        connection.close_link();
        true
    }

    fn stop_now(&self) -> Vec<Arc<SessionVideo>> {
        let (device, connection, wifi, videos) = {
            let mut s = lock(&self.state);
            if s.stopped {
                return s.retiring.clone();
            }
            s.stopped = true;
            self.keeper.close();
            let device = s.device.take();
            let connection = s.live.take().map(|l| l.connection);
            s.live_model = None;
            s.attached.clear();
            s.usb_since.clear();
            s.undialed.clear();
            let wifi = s.wifi.take();
            s.peer_gap = None;
            s.usbmux_down = false;
            s.backing_off = None;
            self.refresh_status(&mut s);
            (device, connection, wifi, s.retiring.clone())
        };
        self.run.cancel();
        if let Some(d) = device {
            d.cancel.cancel();
        }
        if let Some((_, cancel)) = wifi {
            cancel.cancel(); // a link waiting for its Hello is closed by the cancellation
        }
        if let Some(acceptor) = lock(&self.acceptor).take() {
            acceptor.cancel();
        }
        if let Some(connection) = connection {
            connection.finish();
        }
        videos
    }

    // MARK: usbmuxd

    async fn watch_usb(self: Arc<Self>) {
        while !self.run.is_cancelled() {
            match self.usbmux.listen().await {
                Ok(mut events) => loop {
                    let next = tokio::select! {
                        () = self.run.cancelled() => return,
                        next = events.next() => next,
                    };
                    match next {
                        Ok(Some(UsbMuxEvent::Attached(device))) => self.attached(device),
                        Ok(Some(UsbMuxEvent::Detached { device_id })) => self.detached(device_id),
                        // The daemon closed the stream: it restarted, or (Linux) exited after the last unplug.
                        Ok(None) => break,
                        Err(e) if daemon_went_away(&e) => {
                            debug!("usbmuxd went away: {e}");
                            break;
                        }
                        Err(e) => {
                            error!("usbmuxd events failed: {e}");
                            self.update_status(|s| s.usbmux_down = true);
                            break;
                        }
                    }
                },
                // Linux: no daemon running means no iOS device attached (SL4), and one exiting or starting may
                // close the connection before it answers. Neither is an error.
                Err(e) if daemon_went_away(&e) => {
                    debug!("usbmuxd not there: {e}");
                    self.update_status(|s| s.usbmux_down = false);
                }
                Err(e) => {
                    if self.run.is_cancelled() {
                        return;
                    }
                    error!("usbmuxd: {e}");
                    self.update_status(|s| s.usbmux_down = true);
                }
            }
            if self.run.is_cancelled() {
                return;
            }
            // The daemon went away (restart, exit): forget the devices; their events will be replayed.
            let active = {
                let mut s = lock(&self.state);
                s.attached.clear();
                s.usb_since.clear();
                s.undialed.clear();
                s.device.as_ref().map(|d| d.id)
            };
            if let Some(active) = active {
                self.detached(active);
            }
            if !self.run.sleep(self.config.tuning.usbmux_retry_interval).await {
                return;
            }
        }
    }

    fn attached(self: &Arc<Self>, device: UsbMuxDevice) {
        let now = Instant::now();
        let (replaced, ahead) = {
            let mut s = lock(&self.state);
            if s.stopped {
                return;
            }
            s.usbmux_down = false;
            s.attached.retain(|d| d.device_id != device.device_id);
            s.attached.push(device.clone());
            s.usb_since.insert(device.device_id, now);
            s.undialed.insert(device.device_id);
            // Plugging in the iPad whose sessions kept failing capture is the owner's reset, even when it waits
            // its turn. Automatic redials, the next device in line and network links still wait it out.
            let owners_reset = s.capture_failed_peer.as_deref() == Some(device.serial_number.as_str());
            if owners_reset {
                s.reset_capture_backoff();
            }
            // One iPad at a time: another device waits its turn; the same one re-attaching replaces itself. The
            // owner's reset goes ahead of a device whose loop is only waiting the backoff out.
            let mut ahead = None;
            if let Some(current) = &s.device
                && current.id != device.device_id
            {
                if !(owners_reset && s.backing_off == Some(current.generation)) {
                    self.refresh_status(&mut s);
                    drop(s);
                    info!(device = device.device_id, "device attached; waiting its turn (another device is in use)");
                    return;
                }
                ahead = Some(current.id);
            }
            let previous = s.device.take().map(|d| {
                let connection = s.take_live(Owner::Usb(d.generation));
                (d.cancel, connection)
            });
            self.dial(&device, &mut s);
            self.refresh_status(&mut s);
            (previous, ahead)
        };
        if let Some((cancel, connection)) = replaced {
            cancel.cancel();
            if let Some(connection) = connection {
                connection.finish(); // before the new loop can connect
            }
        }
        match ahead {
            Some(ahead) => info!(
                device = device.device_id,
                "iPad attached; dialed ahead of device {ahead} (waiting out the capture backoff)"
            ),
            None => info!(device = device.device_id, "iPad attached"),
        }
    }

    fn detached(self: &Arc<Self>, id: u32) {
        let (cancel, connection, next) = {
            let mut s = lock(&self.state);
            s.attached.retain(|d| d.device_id != id);
            s.usb_since.remove(&id);
            s.undialed.remove(&id);
            let Some(current) = s.device.take_if(|d| d.id == id) else { return };
            // Only this loop's session ends; a network session goes on (§7.7 D29 decision 8).
            let connection = s.take_live(Owner::Usb(current.generation));
            s.peer_gap = None;
            let mut next = None;
            if !s.stopped
                && let Some(first) = s.attached.first().cloned()
            {
                self.dial(&first, &mut s);
                next = Some(first.device_id);
            }
            self.refresh_status(&mut s);
            (current.cancel, connection, next)
        };
        info!(device = id, "iPad detached");
        cancel.cancel();
        if let Some(connection) = connection {
            connection.finish(); // release now; don't wait for the socket to notice
        }
        if let Some(next) = next {
            info!(device = next, "trying the next device");
        }
    }

    /// Starts the connect loop for `device` (under the lock). Its first dial since its attach restarts its
    /// USB preference window; a hand-over back to it doesn't.
    fn dial(self: &Arc<Self>, device: &UsbMuxDevice, s: &mut State<P>) {
        s.generation += 1;
        let generation = s.generation;
        if s.undialed.remove(&device.device_id) {
            s.usb_since.insert(device.device_id, Instant::now());
        }
        let cancel = Cancel::new();
        s.device = Some(DeviceLoop { id: device.device_id, generation, cancel: cancel.clone() });
        let this = self.clone();
        let device = device.clone();
        tokio::spawn(async move { this.connect_loop(device, generation, cancel).await });
    }

    /// lain didn't answer on the current device: if another device is attached, dial that one instead (this
    /// one goes to the back of the line). Returns whether it handed off.
    fn hand_off(self: &Arc<Self>, device: &UsbMuxDevice, generation: u64) -> bool {
        let mut s = lock(&self.state);
        if s.stopped
            || s.device.as_ref().map(|d| d.generation) != Some(generation)
            || s.attached.len() < 2
            || !s.attached.iter().any(|d| d.device_id == device.device_id)
        {
            return false;
        }
        let i = s.attached.iter().position(|d| d.device_id == device.device_id).expect("checked");
        let this = s.attached.remove(i);
        s.attached.push(this);
        let first = s.attached[0].clone();
        self.dial(&first, &mut s);
        self.refresh_status(&mut s);
        true
    }

    // MARK: USB connection

    async fn connect_loop(self: Arc<Self>, device: UsbMuxDevice, generation: u64, cancel: Cancel) {
        let tuning = &self.config.tuning;
        let mut failures = 0u32;
        let mut closed_in_a_row = 0u32;
        while !cancel.is_cancelled() {
            // No session starts inside the session-wide capture backoff, whatever its transport.
            self.wait_out_capture_backoff(generation, &cancel).await;
            if cancel.is_cancelled() {
                return;
            }
            let dialer = UsbMuxDialer { client: self.usbmux.clone(), device_id: device.device_id };
            let host_id = self.config.identity.as_ref().map(|i| i.id.as_str()).unwrap_or("");
            // Biased towards the link: a pairing that completes as the loop is cancelled still signals below.
            let opened = tokio::select! {
                biased;
                opened = HostLink::open(
                    dialer,
                    self.platform.secrets(),
                    &device.serial_number,
                    true,
                    host_id,
                    &self.config.versions,
                ) => opened,
                () = cancel.cancelled() => return,
            };
            match opened {
                Ok((link, hello, paired)) => {
                    // A pairing stored a new secret on both sides: the Wi-Fi listener hears about it even if
                    // the loop was cancelled meanwhile (Swift checks the cancel first and so misses it).
                    if paired {
                        self.secrets_changed.send_modify(|n| *n = n.wrapping_add(1));
                    }
                    if cancel.is_cancelled() {
                        link.close();
                        return;
                    }
                    failures = 0;
                    closed_in_a_row = 0;
                    info!(model = %hello.device_model, "link up ({})", if paired { "paired" } else { "authenticated" });
                    self.update_status(|s| s.peer_gap = None);
                    // A pairing by another process may have changed the stored secrets: the Wi-Fi listener
                    // re-reads them after every USB link-up (§7.7 D29 decision 9); this loop's own pairing
                    // signalled above.
                    if !paired {
                        self.secrets_changed.send_modify(|n| *n = n.wrapping_add(1));
                    }
                    let served = self.run_usb(link, hello, generation, &device.serial_number, &cancel).await;
                    // USB answered: the preference window restarts. A session restarted it as it ended; a link
                    // turned away before serving restarts it here.
                    if !served {
                        let mut s = lock(&self.state);
                        if s.device.as_ref().map(|d| d.generation) == Some(generation) {
                            s.usb_since.insert(device.device_id, Instant::now());
                        }
                    }
                }
                Err(e) => {
                    if cancel.is_cancelled() {
                        return;
                    }
                    failures += 1;
                    closed_in_a_row = self.note_usb_failure(&e, closed_in_a_row);
                    if failures == tuning.fast_retries + 1 {
                        warn!(device = device.device_id, "still can't reach lain on the device: {e}");
                    } else {
                        debug!(device = device.device_id, "USB link failed: {e}");
                    }
                    if failures > tuning.fast_retries && self.hand_off(&device, generation) {
                        return;
                    }
                    let wait = if failures <= tuning.fast_retries {
                        tuning.fast_retry_interval
                    } else {
                        tuning.slow_retry_interval
                    };
                    if !cancel.sleep(wait).await {
                        return;
                    }
                }
            }
        }
    }

    /// A failed USB link attempt: lain on the iPad shares no protocol version with this one if the handshake
    /// said so, or if it keeps closing realtime right after our `ChannelHello` (a v1 app can't parse it and
    /// closes without a word). Returns the updated count of such closes in a row.
    fn note_usb_failure(&self, e: &TransportError, closed_in_a_row: u32) -> u32 {
        if let Some(gap) = VersionGap::from_error(e, &self.config.versions) {
            error!("lain on the iPad shares no protocol version with this computer: {e}");
            self.update_status(|s| s.peer_gap = Some(gap));
            return 0;
        }
        match e {
            TransportError::Closed => {
                let count = closed_in_a_row + 1;
                let hint = self.config.tuning.closes_before_update_hint;
                if count == hint {
                    error!(
                        "lain on the iPad closed the link right after ChannelHello {count} times: another protocol?"
                    );
                }
                if count >= hint {
                    self.update_status(|s| s.peer_gap = Some(HostStatus::older_app_gap()));
                }
                count
            }
            _ => 0,
        }
    }

    /// Sleeps until the session-wide capture backoff is over. Meanwhile the status says so, for as long as
    /// this loop's device is the one dialed.
    async fn wait_out_capture_backoff(&self, generation: u64, cancel: &Cancel) {
        while !cancel.is_cancelled() {
            let until = self.update_status(|s| {
                let mine = s.device.as_ref().map(|d| d.generation) == Some(generation);
                match s.capture_backoff_until {
                    Some(u) if Instant::now() < u && mine => {
                        s.backing_off = Some(generation);
                        Some(u)
                    }
                    _ => {
                        if s.backing_off == Some(generation) {
                            s.backing_off = None;
                        }
                        None
                    }
                }
            });
            let Some(until) = until else { return };
            tokio::select! {
                () = cancel.cancelled() => {}
                () = tokio::time::sleep_until(until) => {}
            }
        }
        self.update_status(|s| {
            if s.backing_off == Some(generation) {
                s.backing_off = None;
            }
        });
    }

    /// One USB session; returns when it has ended and been torn down: true, or false if the link was turned
    /// away before serving.
    async fn run_usb(self: &Arc<Self>, link: Link, hello: Hello, generation: u64, peer: &str, cancel: &Cancel) -> bool {
        let transport = link.transport.clone();
        let connection = self.make_connection(link);
        let claimed = self.update_status(|s| {
            s.claim(&connection, Owner::Usb(generation), transport, peer.to_owned(), cancel.is_cancelled())
        });
        let Some((displaced, previous)) = claimed else {
            connection.close_link();
            return false;
        };
        if let Some(hook) = &self.config.tuning.after_registering {
            hook().await;
        }
        self.serve(connection, hello, peer, displaced, previous).await;
        true
    }

    // MARK: Wi-Fi connection

    fn start_wifi(self: &Arc<Self>, mut streams: WifiStreams) {
        // One acceptor for the session's lifetime: candidates are every stored iPad secret (no primary
        // account), and a network link never pairs (D13).
        let options = AcceptorOptions {
            primary_account: None,
            pairing: Pairing::Refuse,
            label: "lain.host.wifi".into(),
            transport: None,
            versions: self.config.versions.clone(),
        };
        let (acceptor, mut events) = LinkAcceptor::new(self.platform.secrets().clone(), options);
        *lock(&self.acceptor) = Some(acceptor);
        let this = self.clone();
        tokio::spawn(async move {
            loop {
                let stream = tokio::select! {
                    () = this.run.cancelled() => return,
                    stream = streams.recv() => match stream { Some(s) => s, None => return },
                };
                match lock(&this.acceptor).as_ref() {
                    Some(acceptor) => acceptor.accept(stream),
                    None => return,
                }
            }
        });
        let this = self.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    () = this.run.cancelled() => return,
                    link = events.links.recv() => match link {
                        Some(accepted) => this.wifi_accepted(accepted),
                        None => return,
                    },
                    rejection = events.rejections.recv() => match rejection {
                        Some(error) => this.wifi_refused(&error),
                        None => return,
                    },
                }
            }
        });
    }

    /// A link the acceptor authenticated. The newest link takes the network slot: an older one still waiting
    /// for its `Hello` is dropped (closed); a live network session is left for the decision after this
    /// link's `Hello`.
    fn wifi_accepted(self: &Arc<Self>, accepted: AcceptedLink) {
        let started = {
            let mut s = lock(&self.state);
            if s.stopped {
                None
            } else {
                s.generation += 1;
                let generation = s.generation;
                if let Some((previous, cancel)) = &s.wifi
                    && s.live.as_ref().map(|l| l.owner) != Some(Owner::Wifi(*previous))
                {
                    cancel.cancel();
                }
                let cancel = Cancel::new();
                s.wifi = Some((generation, cancel.clone()));
                Some((generation, cancel))
            }
        };
        let Some((generation, cancel)) = started else {
            accepted.link.close();
            return;
        };
        info!(peer = %accepted.peer, via = %crate::status::menu_name(&accepted.link.transport), "network link");
        let this = self.clone();
        tokio::spawn(async move {
            this.wifi_session(accepted, generation, &cancel).await;
            let mut s = lock(&this.state);
            if s.wifi.as_ref().map(|w| w.0) == Some(generation) {
                s.wifi = None;
            }
        });
    }

    /// A connection the acceptor refused (after TLS, so a paired iPad): one on another protocol is worth
    /// telling the owner about.
    fn wifi_refused(&self, error: &TransportError) {
        if let Some(gap) = VersionGap::from_error(error, &self.config.versions) {
            self.update_status(|s| s.peer_gap = Some(gap));
        }
    }

    /// One accepted network link: the client's `Hello` within `hello_timeout`, then, under the lock, a close
    /// (stopped or superseded), `Error(busy)` or a claim, and its session.
    async fn wifi_session(self: &Arc<Self>, accepted: AcceptedLink, generation: u64, cancel: &Cancel) {
        let AcceptedLink { mut link, peer, .. } = accepted;
        let first = tokio::select! {
            () = cancel.cancelled() => {
                link.close();
                return;
            }
            first = link.realtime.recv_timeout(self.config.wifi.hello_timeout) => first,
        };
        let hello = match first {
            Ok(env) => match env.message {
                Message::Hello(hello) => hello,
                other => {
                    error!(%peer, "network link sent {:?} before Hello", other.ty());
                    link.close();
                    return;
                }
            },
            Err(e) => {
                if let Some(gap) = VersionGap::from_error(&e, &self.config.versions) {
                    self.update_status(|s| s.peer_gap = Some(gap));
                }
                info!(%peer, "network link ended before its Hello: {e}");
                link.close();
                return;
            }
        };

        enum Admission<P: Platform> {
            Refused,
            Busy(&'static str),
            Claimed(Claimed<P>),
        }
        let transport = link.transport.clone();
        let connection = self.make_connection(link);
        let now = Instant::now();
        let admission = self.update_status(|s| {
            if s.stopped {
                return Admission::Refused;
            }
            if let Some(why) = s.wifi_busy(&peer, now, self.config.wifi.usb_preference) {
                return Admission::Busy(why);
            }
            match s.claim(&connection, Owner::Wifi(generation), transport, peer.clone(), cancel.is_cancelled()) {
                None => Admission::Refused,
                Some(claimed) => {
                    s.peer_gap = None;
                    Admission::Claimed(claimed)
                }
            }
        });
        match admission {
            Admission::Refused => connection.close_link(),
            Admission::Busy(why) => {
                // Closed only after a short drain, so the client reads the error before the close (and backs
                // off as for busy, not as for a failed link).
                info!(%peer, "network link: busy ({why})");
                let _ = connection
                    .realtime
                    .send(&Message::Error(ErrorMessage { code: ErrorCode::BUSY, message: why.to_owned() }));
                cancel.sleep(self.config.wifi.busy_drain).await;
                connection.close_link();
            }
            Admission::Claimed((displaced, previous)) => {
                info!(%peer, model = %hello.device_model, "network session");
                self.serve(connection, hello, &peer, displaced, previous).await;
            }
        }
    }

    // MARK: Session

    fn make_connection(&self, link: Link) -> Arc<HostConnection<P>> {
        HostConnection::new(link, self.platform.clone(), self.power.clone(), &self.config)
    }

    /// A claimed session of `peer`, strictly in order (Swift: `serve`): the connection starts (it takes the
    /// power assertion before the displaced session drops its own), the displaced session is finished, the
    /// new client's keyboard type is set, every earlier session's display is waited out (one lain display at
    /// a time), then video, `HelloAck`, the first layout and `HostSetup`. Returns when the session has ended
    /// and been torn down.
    async fn serve(
        self: &Arc<Self>,
        connection: Arc<HostConnection<P>>,
        hello: Hello,
        peer: &str,
        displaced: Option<Arc<HostConnection<P>>>,
        previous: Vec<Arc<SessionVideo>>,
    ) {
        // A detach, stop or takeover from here on finishes `connection`; `start` then refuses, so the power
        // assertion is only taken by a connection that will also release it.
        let started = connection.start();
        if let Some(displaced) = displaced {
            displaced.finish();
        }
        connection.set_keyboard_type(hello.keyboard_type);
        if started {
            for video in previous.iter().filter(|v| !Arc::ptr_eq(v, &connection.video)) {
                video.wait_until_stopped().await;
            }
        }
        // Taken over (or stopped) while it waited: it never starts its video or answers.
        if started && !connection.is_finished() {
            let streaming = self.start_video(&connection, &hello).await;
            // HelloAck after video start, so it carries the virtual display's size and the chroma actually
            // streamed. The first frames may overtake it on the video connection; the client decodes them anyway.
            let ack = self.hello_ack(&connection, &hello, streaming);
            let _ = connection.realtime.send(&Message::HelloAck(ack));
            connection.send_layout_if_changed(); // the first one always goes
            // Only now may HostSetup go out (a change before this was held back; this one carries it).
            connection.open_setup();
            self.send_setup(&connection);
            let missing = connection.older_peer_misses();
            if !missing.is_empty() {
                let what: Vec<_> = missing.iter().map(|f| f.summary()).collect();
                info!(
                    "lain on the iPad runs protocol v{}, this computer {}: it works, without {}",
                    connection.version,
                    self.config.versions,
                    what.join(", ")
                );
            }
            self.update_status(|s| {
                if s.live.as_ref().is_some_and(|l| Arc::ptr_eq(&l.connection, &connection)) {
                    s.live_model = Some(hello.device_model.clone());
                }
            });
            connection.run().await;
        }
        connection.finish();
        let capture_failed = connection.capture_failed.load(Ordering::SeqCst);
        let retry = self.config.tuning.capture_retry_interval;
        self.update_status(|s| {
            if let Some(live) = &s.live
                && Arc::ptr_eq(&live.connection, &connection)
            {
                // A USB session's end restarts its iPad's USB preference window in the step that ends it, so a
                // network link decided after the session is gone always sees the new window.
                if let Owner::Usb(g) = live.owner
                    && let Some(d) = &s.device
                    && d.generation == g
                {
                    let id = d.id;
                    s.usb_since.insert(id, Instant::now());
                }
                s.live = None;
                s.live_model = None;
            }
            s.session_ended(peer, capture_failed, retry);
        });
        connection.video.wait_until_stopped().await;
        lock(&self.state).retiring.retain(|v| !Arc::ptr_eq(v, &connection.video));
        info!("session ended");
    }

    /// Starts the connection's video. Returns what streams, or `None`: a failure (no compositor session, say)
    /// leaves an input-only session.
    async fn start_video(self: &Arc<Self>, connection: &Arc<HostConnection<P>>, hello: &Hello) -> Option<Streaming> {
        let video = connection.video.clone();
        let weak_self: Weak<Self> = Arc::downgrade(self);
        let weak_connection = Arc::downgrade(connection);
        let on_end = move |end: VideoEnd| match end {
            VideoEnd::StoppedByUser => {
                // The owner stopped it: keep the session, input only, until the next attach.
                info!("video capture stopped by the owner; input only until the next attach");
                if let (Some(this), Some(connection)) = (weak_self.upgrade(), weak_connection.upgrade()) {
                    {
                        let mut s = lock(&this.state);
                        if s.video.as_ref().is_some_and(|v| Arc::ptr_eq(v, &connection.video)) {
                            s.video_error = Some(STOPPED_ON_THE_DESKTOP.into());
                        }
                    }
                    this.send_setup(&connection);
                    if this.resume_after_stop.load(Ordering::Relaxed) {
                        let due = {
                            let mut last = lock(&this.last_auto_resume);
                            let due = last.is_none_or(|t| t.elapsed() >= RESUME_AFTER_STOP_MIN_GAP);
                            if due {
                                *last = Some(Instant::now());
                            }
                            due
                        };
                        if due {
                            // A moment for the desktop to settle (the Stop also ended input's session).
                            let this = this.clone();
                            tokio::spawn(async move {
                                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                                this.resume_video();
                            });
                        } else {
                            warn!(
                                "stopped on the desktop again within {RESUME_AFTER_STOP_MIN_GAP:?}: staying input only"
                            );
                        }
                    }
                }
            }
            VideoEnd::Failed(e) => {
                // Capture stopped on its own: end the session; the reconnect starts afresh.
                error!("video capture stopped: {e}; ending the session");
                if let Some(connection) = weak_connection.upgrade() {
                    connection.capture_failed.store(true, Ordering::SeqCst);
                    connection.close_link();
                }
            }
        };
        let started = video
            .start(
                &*self.platform,
                hello,
                self.config.video,
                connection.realtime.clone(),
                connection.video_channel.clone(),
                on_end,
                &self.keeper,
            )
            .await;
        match started {
            Ok(streaming) => Some(streaming),
            Err(StartError::Stopped) => None,
            Err(StartError::Failed(e)) => {
                error!("video unavailable: {e}; input only");
                let mut s = lock(&self.state);
                if s.video.as_ref().is_some_and(|v| Arc::ptr_eq(v, &video)) {
                    s.video_error = Some(e.to_string());
                }
                None
            }
        }
    }

    /// The host's answer to `Hello` (Swift: `HelloAck.host`), with the Linux values: HEVC, 4:2:0 8-bit unless
    /// the encoder says otherwise (L3; Swift defaults to 4:4:4 10-bit), the display mode extend, the
    /// configured bitrate (60 Mbps), the refresh rate of the display (Swift: 120 always), audio 48 kHz / 2 /
    /// PCM16LE as Swift states, the platform's input settings and the host's id and name. The point size is
    /// the streamed display's, else the primary monitor's.
    fn hello_ack(&self, connection: &HostConnection<P>, hello: &Hello, streaming: Option<Streaming>) -> HelloAck {
        let settings = self.platform.settings().input_settings();
        let (width, height) =
            connection.target_monitor().map(|m| (m.bounds.width, m.bounds.height)).unwrap_or_default();
        let points = |v: f64| v.max(0.0).round() as u32;
        let (chroma, bit_depth) = match streaming {
            Some(s) => (s.chroma, s.bit_depth),
            None => (ChromaFormat::Yuv420, 8),
        };
        let refresh = streaming.map(|s| s.display.refresh_hz).unwrap_or_else(|| display_spec(hello).refresh_hz);
        let identity = self.config.identity.as_ref();
        HelloAck {
            codec: VideoCodec::Hevc,
            chroma,
            bit_depth,
            display_mode: DisplayMode::Extend,
            bitrate: self.config.video.average_bit_rate,
            refresh_rate: u16::try_from(refresh).unwrap_or(u16::MAX),
            display_point_width: points(width),
            display_point_height: points(height),
            audio_sample_rate: 48_000,
            audio_channels: 2,
            audio_encoding: AudioEncoding::Pcm16Le,
            double_click_interval_ms: settings.double_click_ms,
            key_repeat_delay_ms: settings.key_repeat_delay_ms,
            key_repeat_interval_ms: settings.key_repeat_interval_ms,
            mac_input_source: settings.input_source,
            host_id: identity.map(|i| i.id.clone()).unwrap_or_default(),
            host_name: identity.map(|i| i.name.clone()).unwrap_or_default(),
        }
    }

    /// The platform's setup, plus why there's no video, if the link's version has `HostSetup` (Swift:
    /// `sendSetup`).
    ///
    /// Intended difference: Swift adds a Local Network item from its Wi-Fi listener's state; Linux has no such
    /// permission, and the daemon's `SetupSource` decides every item.
    fn send_setup(&self, connection: &HostConnection<P>) {
        if !connection.supports(ProtocolFeature::HostSetup) {
            return;
        }
        let video_problem = {
            let s = lock(&self.state);
            match &s.video {
                Some(v) if Arc::ptr_eq(v, &connection.video) => s.video_error.clone(),
                _ => None,
            }
        };
        let report = self.platform.setup().setup();
        connection.send_setup_if_changed(host_setup(report, video_problem.unwrap_or_default()));
    }
}
