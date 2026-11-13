//! lain's display on GNOME: `ScreenCast.RecordVirtual` in a ScreenCast session linked to a RemoteDesktop
//! session (decision L8; Swift: `VirtualStreamedDisplayProvider`, `StreamedDisplayProvider`).

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use futures::StreamExt;
use lain_platform::{DisplayBackend, DisplaySpec, Monitor, PlatformError, PointF, Result, StreamedDisplay};
use tokio::sync::{Mutex, oneshot, watch};
use zbus::Connection;
use zbus::fdo::DBusProxy;
use zbus::zvariant::OwnedValue;

use crate::bus::{self, RemoteSession};
use crate::cursor::CursorState;
use crate::display_config::MonitorSpec;
use crate::monitors::{Command, DesktopHandle};
use crate::negotiate::{self, NegotiatedFormat};

/// `RecordVirtual` → `PipeWireStreamAdded`: 24 ms in spike B.
const NODE_TIMEOUT: Duration = Duration::from_secs(5);
/// The consumer's format, then the new monitor in `GetCurrentState`: 30–60 ms in spike B.
const MONITOR_TIMEOUT: Duration = Duration::from_secs(5);
/// The arrangement and scale taking effect: 16–26 ms in spike B.
const ARRANGE_TIMEOUT: Duration = Duration::from_secs(2);
/// `Stop` → the monitor gone: about 12 ms in spike B.
const REMOVAL_TIMEOUT: Duration = Duration::from_secs(2);

/// Why lain's display's session ended, for `lain-linux-video` to report (`VideoEvent::StoppedByUser` or
/// `VideoEvent::Failed`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DisplayEnd {
    /// Mutter closed the session on its own (its `Closed` signal while lain wasn't stopping it): the owner
    /// pressed Stop on GNOME Shell's sharing indicator. Which `Closed` that Stop emits is still to be checked
    /// with the developer present (spike B, "Not tested"), so any unasked `Closed` counts as the owner's.
    StoppedByUser,
    /// Mutter left the session bus (gnome-shell restarted or crashed), or lain's connection to it was lost.
    Failed(String),
    /// lain destroyed it (`DisplayBackend::destroy`). New in the port: Swift's capture just stops.
    Destroyed,
}

/// What `lain-linux-video` needs to capture lain's display (the contract's `DisplayBackend::Source`).
#[derive(Debug, Clone)]
pub struct GnomeSource {
    /// The PipeWire node of the `RecordVirtual` stream, in the user's PipeWire daemon. Connect to it with the
    /// same size and `maxFramerate` as `pixel_width × pixel_height` at `refresh_hz` (the monitor keeps the mode
    /// the negotiating consumer fixed, spike B exp8).
    pub node_id: u32,
    /// The stream's `mapping-id` (its `Parameters`), the id libei regions carry for it.
    pub mapping_id: Option<String>,
    /// The ScreenCast stream object.
    pub stream_path: String,
    /// lain's monitor's connector (`Meta-<n>`).
    pub connector: String,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub refresh_hz: u32,
    /// Where the stream's cursor metadata goes (the same state for every display of a run).
    pub cursor: Arc<CursorState>,
    /// `None` while the session runs; then why it ended.
    pub ended: watch::Receiver<Option<DisplayEnd>>,
}

struct Active {
    session: RemoteSession,
    connector: String,
    ended: watch::Receiver<Option<DisplayEnd>>,
    end_tx: watch::Sender<Option<DisplayEnd>>,
    /// Set before lain's own `Stop`, so its `Closed` reads as `Destroyed`.
    destroying: Arc<std::sync::atomic::AtomicBool>,
    watcher: tokio::task::JoinHandle<()>,
}

/// The display backend (Swift: `VirtualStreamedDisplayProvider`).
#[derive(Clone)]
pub struct GnomeDisplay {
    conn: Connection,
    desktop: DesktopHandle,
    cursor: Arc<CursorState>,
    active: Arc<Mutex<Option<Active>>>,
    /// The owner's scale for lain's display; `None`: the iPad's own. Shared by clones, so a change reaches the
    /// display wherever it is made.
    scale: Arc<std::sync::Mutex<Option<f64>>>,
    /// The iPad's own scale, from the last `create`'s spec (what `None` means).
    own_scale: Arc<std::sync::Mutex<u32>>,
    /// The live display's scale was the client's choice (v7 `Hello.desiredScale`): the owner's setting then
    /// applies to the next display a client makes without choosing, not to this one.
    client_chose: Arc<std::sync::atomic::AtomicBool>,
}

fn failed(what: &str, e: impl std::fmt::Display) -> PlatformError {
    PlatformError::Failed(format!("{what}: {e}"))
}

impl GnomeDisplay {
    /// The display backend on `conn`, with the desktop task `monitors::spawn` started and the run's cursor state.
    pub fn new(conn: Connection, desktop: DesktopHandle, cursor: Arc<CursorState>) -> Self {
        Self {
            conn,
            desktop,
            cursor,
            active: Arc::new(Mutex::new(None)),
            scale: Arc::default(),
            own_scale: Arc::new(std::sync::Mutex::new(2)),
            client_chose: Arc::default(),
        }
    }

    /// Makes lain's display at `scale` (the closest Mutter supports) instead of the iPad's own. New in the port:
    /// GNOME's interface is larger than macOS's at the same scale, so the owner may want more room than 2×.
    pub fn with_scale(self, scale: Option<f64>) -> Self {
        *self.scale.lock().unwrap_or_else(|e| e.into_inner()) = scale;
        self
    }

    /// The owner's scale setting (`None`: the iPad's own).
    pub fn scale_setting(&self) -> Option<f64> {
        *self.scale.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Changes the scale setting, and applies it to lain's display now if there is one (the closest scale Mutter
    /// supports, as at `create`).
    pub fn set_scale(&self, scale: Option<f64>) {
        *self.scale.lock().unwrap_or_else(|e| e.into_inner()) = scale;
        if self.client_chose.load(std::sync::atomic::Ordering::Relaxed) {
            tracing::info!("lain's display: the client chose its scale; the setting applies to the next one");
            return;
        }
        let connector = self.desktop.desktop.borrow().lain().map(|m| m.spec.connector.clone());
        if let Some(connector) = connector {
            let own = *self.own_scale.lock().unwrap_or_else(|e| e.into_inner());
            let wanted = scale.unwrap_or_else(|| f64::from(own.max(1)));
            tracing::info!(wanted, "lain's display: new scale");
            self.desktop.send(Command::SetLain { connector, scale: wanted });
        }
    }

    /// lain's display's scale now, if it exists.
    pub fn applied_scale(&self) -> Option<f64> {
        self.desktop.desktop.borrow().lain().map(|m| m.scale)
    }

    /// The scales Mutter supports for lain's display's mode (empty without a display).
    pub fn scale_options(&self) -> Vec<f64> {
        self.desktop.desktop.borrow().lain().map(|m| m.supported_scales.clone()).unwrap_or_default()
    }

    /// `create`'s body, on a task of its own (review L1). Its result goes to `reply`; if nobody waits for it any
    /// more (the caller dropped `create`), the display it made is removed again, as Swift's start does when a
    /// `stop()` comes during it (`HostVideoPipeline.abandonStart`, D29). It holds `active`'s lock throughout, so
    /// a `destroy` meanwhile waits for it and then removes what it made.
    async fn create_owned(&self, spec: DisplaySpec, reply: oneshot::Sender<Result<(StreamedDisplay, GnomeSource)>>) {
        let mut active = self.active.lock().await;
        if active.is_some() {
            let _ = reply.send(Err(PlatformError::Failed("lain's display already exists; destroy it first".into())));
            return;
        }
        // Mutter reuses connector names (each session's monitor is `Meta-0` again), so lain's new monitor is
        // told apart by its full spec: its serial is new (spike B exp2; review L6).
        let known: HashSet<MonitorSpec> =
            self.desktop.desktop.borrow().monitors.iter().map(|m| m.spec.clone()).collect();
        self.desktop.send(Command::Creating { known: known.clone() });
        let session = match RemoteSession::create(&self.conn).await {
            Ok(s) => s,
            Err(e) => {
                self.desktop.send(Command::ClearLain);
                let _ = reply.send(Err(PlatformError::Unavailable(format!("Mutter's RemoteDesktop/ScreenCast: {e}"))));
                return;
            }
        };
        match self.bring_up(&session, spec, &known).await {
            Ok((display, source, closed)) => {
                let (end_tx, ended) = watch::channel(None);
                let destroying = Arc::new(std::sync::atomic::AtomicBool::new(false));
                let watcher = tokio::spawn(watch_end(
                    self.conn.clone(),
                    closed,
                    end_tx.clone(),
                    destroying.clone(),
                    self.desktop.clone(),
                    self.cursor.clone(),
                ));
                let made = Active {
                    session,
                    connector: source.connector.clone(),
                    ended: ended.clone(),
                    end_tx,
                    destroying,
                    watcher,
                };
                match reply.send(Ok((display, GnomeSource { ended, ..source }))) {
                    Ok(()) => *active = Some(made),
                    Err(_) => {
                        tracing::info!("create was given up; removing the display it made");
                        self.remove(made).await;
                    }
                }
            }
            Err(e) => {
                tracing::warn!("lain's display failed to come up: {e}");
                session.discard().await;
                // Until the monitor it may have made is gone, it stays out of `monitors()` (Creating).
                let mut desktop = self.desktop.desktop.clone();
                let new_virtual =
                    |d: &crate::desktop::Desktop| d.monitors.iter().any(|m| m.is_virtual && !known.contains(&m.spec));
                let gone = tokio::time::timeout(REMOVAL_TIMEOUT, desktop.wait_for(|d| !new_virtual(d))).await;
                if !matches!(gone, Ok(Ok(_))) {
                    tracing::warn!("a virtual monitor from the failed create is still listed");
                }
                self.desktop.send(Command::ClearLain);
                let _ = reply.send(Err(e));
            }
        }
    }

    /// Stops `active`'s session, reports the end, and waits for its monitor to leave (at most
    /// [`REMOVAL_TIMEOUT`]).
    async fn remove(&self, active: Active) {
        if active.ended.borrow().is_none() {
            active.destroying.store(true, std::sync::atomic::Ordering::Release);
            if let Err(e) = active.session.stop().await {
                tracing::debug!("Stop: {e}");
            }
        }
        let _ = tokio::time::timeout(REMOVAL_TIMEOUT, active.watcher).await;
        active.end_tx.send_if_modified(|e| {
            let first = e.is_none();
            if first {
                *e = Some(DisplayEnd::Destroyed);
            }
            first
        });
        self.desktop.send(Command::ClearLain);
        self.cursor.set_geometry(None);
        let connector = active.connector;
        let mut desktop = self.desktop.desktop.clone();
        let gone =
            tokio::time::timeout(REMOVAL_TIMEOUT, desktop.wait_for(|d| d.by_connector(&connector).is_none())).await;
        if !matches!(gone, Ok(Ok(_))) {
            tracing::warn!(connector, "lain's display is still listed after Stop");
        }
    }

    /// Everything between `CreateSession` and a display that is listed, arranged and scaled. `known`: the
    /// monitors there before.
    async fn bring_up(
        &self,
        session: &RemoteSession,
        spec: DisplaySpec,
        known: &HashSet<MonitorSpec>,
    ) -> Result<(StreamedDisplay, GnomeSource, zbus::proxy::SignalStream<'static>)> {
        let closed = session.closed().await.map_err(|e| failed("subscribing to Closed", e))?;
        let stream_path = session.record_virtual().await.map_err(|e| failed("RecordVirtual", e))?;
        let stream = session.stream(stream_path.clone()).await.map_err(|e| failed("the stream", e))?;
        let mut added =
            stream.receive_signal("PipeWireStreamAdded").await.map_err(|e| failed("PipeWireStreamAdded", e))?;
        session.start().await.map_err(|e| failed("Start", e))?;
        let node_id = tokio::time::timeout(NODE_TIMEOUT, bus::next_node_id(&mut added))
            .await
            .ok()
            .flatten()
            .ok_or_else(|| PlatformError::Failed("Mutter announced no PipeWire node".into()))?;
        let mapping_id = match stream.get_property::<std::collections::HashMap<String, OwnedValue>>("Parameters").await
        {
            Ok(p) => p.get("mapping-id").and_then(|v| String::try_from(v.clone()).ok()),
            Err(e) => {
                tracing::debug!("the stream's Parameters: {e}");
                None
            }
        };
        tracing::debug!(node_id, ?mapping_id, "lain's stream is up; negotiating its mode");

        // The monitor exists only once a consumer fixes the format (spike B, §1).
        let (negotiation, format) = negotiate::negotiate(node_id, spec.pixel_width, spec.pixel_height, spec.refresh_hz);
        let format: NegotiatedFormat = match tokio::time::timeout(MONITOR_TIMEOUT, format).await {
            Ok(Ok(Ok(f))) => f,
            Ok(Ok(Err(e))) => return Err(PlatformError::Failed(e)),
            Ok(Err(_)) => return Err(PlatformError::Failed("the PipeWire negotiation ended without a format".into())),
            Err(_) => return Err(PlatformError::Failed("PipeWire fixed no format in time".into())),
        };
        if (format.width, format.height) != (spec.pixel_width, spec.pixel_height) {
            return Err(PlatformError::Failed(format!(
                "Mutter fixed {}×{}, not {}×{}",
                format.width, format.height, spec.pixel_width, spec.pixel_height
            )));
        }
        let mut desktop = self.desktop.desktop.clone();
        let size = (spec.pixel_width as i32, spec.pixel_height as i32);
        // The new virtual monitor in the negotiated mode.
        let is_new = |m: &crate::desktop::DesktopMonitor| {
            m.is_virtual && !known.contains(&m.spec) && m.mode.is_some_and(|(w, h, _)| (w, h) == size)
        };
        let connector =
            match tokio::time::timeout(MONITOR_TIMEOUT, desktop.wait_for(|d| d.monitors.iter().any(is_new))).await {
                Ok(Ok(d)) => d.monitors.iter().find(|m| is_new(m)).map(|m| m.spec.connector.clone()),
                _ => None,
            };
        let connector = connector
            .ok_or_else(|| PlatformError::Failed("lain's virtual monitor never appeared in DisplayConfig".into()))?;
        // The monitor outlives its consumer (exp8); leave before re-scaling, as exp8's handover did.
        negotiation.finish().await;

        self.cursor.reset();
        // Scale 0 counts as 1, as in `DisplaySpec::logical_size` (review A4).
        *self.own_scale.lock().unwrap_or_else(|e| e.into_inner()) = spec.scale.max(1);
        // v7: the client's chosen scale wins (the core sized the display so Mutter can apply it exactly); else the
        // owner's setting, else the spec's own.
        let chose = spec.desired_scale > 0;
        self.client_chose.store(chose, std::sync::atomic::Ordering::Relaxed);
        let wanted = if chose {
            f64::from(spec.desired_scale) / 100.0
        } else {
            self.scale_setting().unwrap_or_else(|| f64::from(spec.scale.max(1)))
        };
        self.desktop.send(Command::SetLain { connector: connector.clone(), scale: wanted });
        let reached = |m: &crate::desktop::DesktopMonitor| {
            (m.scale - crate::display_config::nearest_scale(&m.supported_scales, wanted)).abs() < 1e-3
        };
        let arranged = tokio::time::timeout(
            ARRANGE_TIMEOUT,
            desktop.wait_for(|d| d.lain().is_some_and(|m| m.spec.connector == connector && reached(m))),
        )
        .await
        .is_ok_and(|r| r.is_ok());
        if !arranged {
            tracing::warn!(connector, "lain's display didn't reach scale {wanted} in time; going on at Mutter's");
        }
        let d = desktop.borrow().clone();
        let lain =
            d.by_connector(&connector).ok_or_else(|| PlatformError::Failed("lain's display went away".into()))?;
        let (w, h, hz) = lain.mode.unwrap_or((size.0, size.1, f64::from(spec.refresh_hz)));
        let refresh_hz = if hz > 0.0 { hz.round() as u32 } else { spec.refresh_hz };
        let streamed =
            StreamedDisplay { id: lain.monitor.id, pixel_width: w as u32, pixel_height: h as u32, refresh_hz };
        tracing::info!(connector, ?streamed, node_id, scale = lain.scale, "lain's display is up");
        let source = GnomeSource {
            node_id,
            mapping_id,
            stream_path: stream_path.to_string(),
            connector,
            pixel_width: streamed.pixel_width,
            pixel_height: streamed.pixel_height,
            refresh_hz,
            cursor: self.cursor.clone(),
            ended: watch::channel(None).1,
        };
        Ok((streamed, source, closed))
    }
}

/// Watches lain's session end: Mutter's `Closed`, Mutter leaving the bus, or the connection going away. Then
/// lain's entry leaves `monitors()` at once and the reason reaches video. Input has its own session and
/// carries on.
async fn watch_end(
    conn: Connection,
    mut closed: zbus::proxy::SignalStream<'static>,
    end_tx: watch::Sender<Option<DisplayEnd>>,
    destroying: Arc<std::sync::atomic::AtomicBool>,
    desktop: DesktopHandle,
    cursor: Arc<CursorState>,
) {
    let owner = async {
        let dbus = DBusProxy::new(&conn).await.ok()?;
        let mut changes = dbus.receive_name_owner_changed_with_args(&[(0, bus::SCREEN_CAST)]).await.ok()?;
        while let Some(change) = changes.next().await {
            if change.args().ok().is_some_and(|a| a.new_owner().is_none()) {
                return Some(());
            }
        }
        None
    };
    let end = tokio::select! {
        signal = closed.next() => match signal {
            Some(_) if destroying.load(std::sync::atomic::Ordering::Acquire) => DisplayEnd::Destroyed,
            Some(_) => DisplayEnd::StoppedByUser,
            None => DisplayEnd::Failed("the session bus connection was lost".into()),
        },
        Some(()) = owner => DisplayEnd::Failed("Mutter left the session bus".into()),
    };
    tracing::info!(?end, "lain's display's session ended");
    end_tx.send_if_modified(|e| {
        let first = e.is_none();
        if first {
            *e = Some(end);
        }
        first
    });
    cursor.set_geometry(None);
    cursor.set_invalid();
    desktop.send(Command::ClearLain);
}

impl DisplayBackend for GnomeDisplay {
    type Source = GnomeSource;

    /// Cancel-safe: once polled, the creation runs to its end on a task of its own; if this future is dropped
    /// first, the display it made is removed again ([`GnomeDisplay::create_owned`]), and a `destroy` issued
    /// meanwhile waits for that.
    fn create(&self, spec: DisplaySpec) -> impl Future<Output = Result<(StreamedDisplay, GnomeSource)>> + Send {
        let this = self.clone();
        async move {
            let (reply, result) = oneshot::channel();
            tokio::spawn(async move { this.create_owned(spec, reply).await });
            result.await.unwrap_or_else(|_| Err(PlatformError::Failed("lain's display's creation ended".into())))
        }
    }

    fn destroy(&self) -> impl Future<Output = ()> + Send {
        let this = self.clone();
        // On a task of its own, so the removal completes even if this future is dropped.
        let task = tokio::spawn(async move {
            let Some(active) = this.active.lock().await.take() else { return };
            this.remove(active).await;
        });
        async move {
            let _ = task.await;
        }
    }

    fn monitors(&self) -> watch::Receiver<Vec<Monitor>> {
        self.desktop.monitors.clone()
    }

    fn cursor_location(&self) -> Option<PointF> {
        self.cursor.location()
    }

    fn applied_scale(&self) -> Option<f64> {
        GnomeDisplay::applied_scale(self)
    }
}
