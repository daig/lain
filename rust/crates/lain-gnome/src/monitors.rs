//! The task that owns `DisplayConfig`: it reads `GetCurrentState` at start and on every `MonitorsChanged`,
//! publishes the desktop, keeps [`CursorState`]'s geometry current, and runs the arrangement rules (re-apply,
//! re-scale, record), applying with method 1 only. Swift's counterpart is `DisplayLayoutProvider` over
//! `CGGetActiveDisplayList`, which never applies anything.

use std::sync::Arc;

use futures::StreamExt;
use lain_platform::{Monitor, PlatformError};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;
use zbus::{Connection, Proxy};

use crate::arrangement::{self, Apply, Decision, Store, Tracker, View};
use crate::bus;
use crate::cursor::{CursorState, StreamGeometry};
use crate::desktop::{self, Desktop, IdMap};
use crate::display_config::{self, DisplayState, RawState, apply_args, config_with, logical_size, parse_state};

/// What the display tells the desktop task.
#[derive(Debug)]
pub enum Command {
    /// lain's display is `connector`, to be kept at `spec_scale`: mark it, and arrange it now.
    SetLain { connector: String, spec_scale: u32 },
    /// lain's display is gone (destroyed, or ended by Mutter): unmark it at once.
    ClearLain,
}

/// The desktop as published, and the way to tell the task about lain's display.
#[derive(Debug, Clone)]
pub struct DesktopHandle {
    pub desktop: watch::Receiver<Arc<Desktop>>,
    pub monitors: watch::Receiver<Vec<Monitor>>,
    commands: mpsc::UnboundedSender<Command>,
}

impl DesktopHandle {
    pub fn send(&self, command: Command) {
        let _ = self.commands.send(command);
    }
}

struct Lain {
    connector: String,
    spec_scale: u32,
}

struct Task {
    config: Proxy<'static>,
    ids: IdMap,
    tracker: Tracker,
    store: Option<Store>,
    lain: Option<Lain>,
    state: Option<DisplayState>,
    wake: Option<Instant>,
    cursor: Arc<CursorState>,
    desktop: watch::Sender<Arc<Desktop>>,
    monitors: watch::Sender<Vec<Monitor>>,
}

async fn current_state(config: &Proxy<'_>) -> zbus::Result<DisplayState> {
    let raw: RawState = config.call("GetCurrentState", &()).await?;
    Ok(parse_state(raw))
}

/// Starts the task, with the desktop read once before it returns.
pub async fn spawn(
    conn: &Connection,
    cursor: Arc<CursorState>,
    store: Option<Store>,
) -> Result<DesktopHandle, PlatformError> {
    let config = bus::proxy(conn, bus::DISPLAY_CONFIG, bus::DISPLAY_CONFIG_PATH, bus::DISPLAY_CONFIG)
        .await
        .map_err(|e| PlatformError::Unavailable(format!("Mutter's DisplayConfig: {e}")))?;
    // Subscribed before the first read, so no change falls between the two.
    let changed = config
        .receive_signal("MonitorsChanged")
        .await
        .map_err(|e| PlatformError::Unavailable(format!("MonitorsChanged: {e}")))?;
    let state = current_state(&config)
        .await
        .map_err(|e| PlatformError::Unavailable(format!("DisplayConfig.GetCurrentState: {e}")))?;
    if state.layout_mode == display_config::LayoutMode::Physical {
        tracing::warn!("Mutter is in physical layout mode: global coordinates are device pixels, not logical ones");
    }
    let stored = store.as_ref().and_then(Store::load);
    let mut ids = IdMap::default();
    let first = desktop::build(&state, None, &mut ids);
    let (desktop_tx, desktop_rx) = watch::channel(Arc::new(first.clone()));
    let (monitors_tx, monitors_rx) = watch::channel(first.contract_monitors());
    let (commands, rx) = mpsc::unbounded_channel();
    let task = Task {
        config,
        ids,
        tracker: Tracker::new(stored),
        store,
        lain: None,
        state: Some(state),
        wake: None,
        cursor,
        desktop: desktop_tx,
        monitors: monitors_tx,
    };
    tokio::spawn(task.run(changed, rx));
    Ok(DesktopHandle { desktop: desktop_rx, monitors: monitors_rx, commands })
}

impl Task {
    async fn run(
        mut self,
        mut changed: zbus::proxy::SignalStream<'static>,
        mut commands: mpsc::UnboundedReceiver<Command>,
    ) {
        loop {
            let wake = self.wake;
            tokio::select! {
                signal = changed.next() => {
                    if signal.is_none() {
                        tracing::warn!("MonitorsChanged ended: the session bus connection is gone");
                        break;
                    }
                    self.refresh().await;
                }
                command = commands.recv() => match command {
                    None => break,
                    Some(Command::SetLain { connector, spec_scale }) => {
                        self.lain = Some(Lain { connector, spec_scale });
                        self.tracker.reset();
                        self.wake = None;
                        self.refresh().await;
                    }
                    Some(Command::ClearLain) => {
                        self.lain = None;
                        self.wake = None;
                        self.publish();
                    }
                },
                _ = tokio::time::sleep_until(wake.unwrap_or_else(Instant::now)), if wake.is_some() => {
                    self.wake = None;
                    let decision = self.tracker.on_tick(Instant::now());
                    self.decide(decision).await;
                }
                _ = self.desktop.closed() => break,
            }
        }
    }

    async fn refresh(&mut self) {
        match current_state(&self.config).await {
            Ok(state) => self.state = Some(state),
            Err(e) => {
                tracing::warn!("DisplayConfig.GetCurrentState: {e}");
                return;
            }
        }
        self.publish();
        let Some(view) = self.view() else { return };
        let decision = self.tracker.on_layout(Instant::now(), view);
        self.decide(decision).await;
    }

    fn lain_connector(&self) -> Option<&str> {
        let lain = self.lain.as_ref()?;
        let state = self.state.as_ref()?;
        state.logical_of(&lain.connector).map(|_| lain.connector.as_str())
    }

    fn publish(&mut self) {
        let Some(state) = self.state.as_ref() else { return };
        let lain = self.lain_connector().map(str::to_owned);
        let desktop = desktop::build(state, lain.as_deref(), &mut self.ids);
        let geometry = desktop.lain().map(|m| StreamGeometry { bounds: m.monitor.bounds, scale: m.scale });
        self.cursor.set_geometry(geometry);
        let monitors = desktop.contract_monitors();
        self.monitors.send_if_modified(|m| {
            let changed = *m != monitors;
            if changed {
                *m = monitors;
            }
            changed
        });
        self.desktop.send_replace(Arc::new(desktop));
    }

    fn view(&self) -> Option<View> {
        let lain = self.lain.as_ref()?;
        let state = self.state.as_ref()?;
        let logical = state.logical_of(&lain.connector)?;
        let (others, rect) = arrangement::split(state, &lain.connector)?;
        Some(View {
            set: state.monitor_set(),
            scale: logical.scale,
            spec_scale: lain.spec_scale,
            current: arrangement::derive(&others, &rect),
        })
    }

    async fn decide(&mut self, decision: Decision) {
        match decision {
            Decision::Nothing => {}
            Decision::WakeAt(at) => self.wake = Some(at),
            Decision::Store(a) => {
                tracing::info!(?a, "recording the owner's arrangement of lain's display");
                if let Some(store) = &self.store
                    && let Err(e) = store.save(&a)
                {
                    tracing::warn!(path = %store.path().display(), "can't store the arrangement: {e}");
                }
            }
            Decision::Apply(kind) => self.apply(kind).await,
        }
    }

    /// Applies lain's arrangement at the spec's scale, with method 1 (`display_config::APPLY_METHOD`).
    async fn apply(&mut self, kind: Apply) {
        let (Some(lain), Some(state)) = (self.lain.as_ref(), self.state.as_ref()) else { return };
        let set = state.monitor_set();
        let planned = (|| {
            let logical = state.logical_of(&lain.connector)?;
            let mode = state.monitor(&lain.connector)?.current_mode()?;
            let size =
                logical_size(mode.width, mode.height, f64::from(lain.spec_scale), logical.transform, state.layout_mode);
            let (others, rect) = arrangement::split(state, &lain.connector)?;
            let stored = match kind {
                Apply::Stored => self.tracker.stored(),
                Apply::Scale => None,
            };
            let plan = arrangement::plan(stored, &others, &rect, size)?;
            let config = config_with(state, &lain.connector, plan.lain_at, f64::from(lain.spec_scale), plan.shift)?;
            Some((plan, config))
        })();
        let Some((plan, config)) = planned else {
            tracing::warn!(connector = lain.connector, "can't plan lain's display's arrangement");
            self.tracker.applied(set, None);
            return;
        };
        let args = apply_args(state.serial, &config);
        tracing::debug!(?kind, ?plan, "ApplyMonitorsConfig (temporary)");
        if let Err(e) = self.config.call::<_, _, ()>("ApplyMonitorsConfig", &args).await {
            tracing::warn!(?kind, "ApplyMonitorsConfig refused: {e}");
        }
        // Counted even when refused, so a layout Mutter won't take isn't retried until the monitors change.
        self.tracker.applied(set, Some(plan.arrangement));
    }
}
