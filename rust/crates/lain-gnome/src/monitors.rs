//! The task that owns `DisplayConfig`: it reads `GetCurrentState` at start and on every `MonitorsChanged`,
//! publishes the desktop, keeps [`CursorState`]'s geometry current, and runs the arrangement rules (re-apply,
//! re-scale, record), applying with method 1 only. Swift's counterpart is `DisplayLayoutProvider` over
//! `CGGetActiveDisplayList`, which never applies anything.

use std::collections::HashSet;
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
use crate::display_config::{
    self, DisplayState, MonitorSpec, RawState, apply_args, config_with, logical_size, parse_state,
};

/// What the display tells the desktop task.
#[derive(Debug)]
pub enum Command {
    /// lain's display is being created; `known` are the monitors there before. Until `SetLain` or `ClearLain`,
    /// a new virtual monitor is kept out of `monitors()`, so it is never listed as an ordinary monitor before
    /// it is marked as lain's (review A5).
    Creating { known: HashSet<MonitorSpec> },
    /// lain's display is `connector`, to be kept at `spec_scale` (0 counts as 1): mark it, and arrange it now.
    SetLain { connector: String, spec_scale: u32 },
    /// lain's display is gone (destroyed, ended by Mutter, or its creation given up): its entry leaves
    /// `monitors()` at once, and stays out while Mutter still lists that monitor.
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
    /// While lain's display is being created: the monitors there before.
    creating: Option<HashSet<MonitorSpec>>,
    /// lain's former displays, kept out of `monitors()` until Mutter drops them.
    gone: HashSet<MonitorSpec>,
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
        creating: None,
        gone: HashSet::new(),
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
                    Some(Command::Creating { known }) => {
                        self.creating = Some(known);
                        self.publish();
                    }
                    Some(Command::SetLain { connector, spec_scale }) => {
                        self.creating = None;
                        self.lain = Some(Lain { connector, spec_scale: spec_scale.max(1) });
                        self.tracker.reset();
                        self.wake = None;
                        self.refresh().await;
                    }
                    Some(Command::ClearLain) => {
                        self.creating = None;
                        if let Some(lain) = self.lain.take()
                            && let Some(m) = self.state.as_ref().and_then(|s| s.monitor(&lain.connector))
                        {
                            self.gone.insert(m.spec.clone());
                        }
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
        self.gone.retain(|s| state.monitors.iter().any(|m| m.spec == *s));
        let lain = self.lain_connector().map(str::to_owned);
        let desktop = desktop::build(state, lain.as_deref(), &mut self.ids);
        let geometry = desktop.lain().map(|m| StreamGeometry { bounds: m.monitor.bounds, scale: m.scale });
        self.cursor.set_geometry(geometry);
        let monitors = listed(&desktop, self.creating.as_ref(), &self.gone);
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

    /// Applies lain's arrangement at the spec's scale, with method 1 (`display_config::APPLY_METHOD`). A refusal
    /// for a stale serial (a `MonitorsChanged` on its way) is retried once on a fresh `GetCurrentState`.
    async fn apply(&mut self, kind: Apply) {
        for attempt in 0..2 {
            let (Some(lain), Some(state)) = (self.lain.as_ref(), self.state.as_ref()) else { return };
            let set = state.monitor_set();
            let spec_scale = f64::from(lain.spec_scale);
            let planned = (|| {
                let logical = state.logical_of(&lain.connector)?;
                let mode = state.monitor(&lain.connector)?.current_mode()?;
                let size = logical_size(mode.width, mode.height, spec_scale, logical.transform, state.layout_mode);
                let (others, rect) = arrangement::split(state, &lain.connector)?;
                let stored = match kind {
                    Apply::Stored => self.tracker.stored(),
                    // Keeping lain's display where it is, unless that is Mutter's placement after a refusal.
                    Apply::Scale if self.tracker.refused() => self.tracker.stored(),
                    Apply::Scale => None,
                };
                let plan = arrangement::plan(stored, &others, &rect, size)?;
                let config = config_with(state, &lain.connector, plan.lain_at, spec_scale, &plan.others_at)?;
                Some((plan, config))
            })();
            let Some((plan, config)) = planned else {
                tracing::warn!(connector = lain.connector, "can't plan lain's display's arrangement");
                self.tracker.applied(set, None, false);
                return;
            };
            let args = apply_args(state, &config);
            tracing::debug!(?kind, ?plan, "ApplyMonitorsConfig (temporary)");
            match self.config.call::<_, _, ()>("ApplyMonitorsConfig", &args).await {
                Ok(()) => {
                    self.tracker.applied(set, plan.arrangement, true);
                    return;
                }
                Err(e) if attempt == 0 && is_stale(&e) => {
                    tracing::debug!(?kind, "ApplyMonitorsConfig: stale serial; re-reading the state");
                    match current_state(&self.config).await {
                        Ok(state) => {
                            self.state = Some(state);
                            self.publish();
                        }
                        Err(e) => {
                            tracing::warn!("DisplayConfig.GetCurrentState: {e}");
                            self.tracker.applied(set, plan.arrangement, false);
                            return;
                        }
                    }
                }
                Err(e) => {
                    tracing::warn!(?kind, "ApplyMonitorsConfig refused: {e}");
                    // Counted, so a layout Mutter won't take isn't retried until the monitors change.
                    self.tracker.applied(set, plan.arrangement, false);
                    return;
                }
            }
        }
    }
}

/// Mutter's refusal of a configuration made against an older serial ("The requested configuration is based on
/// stale information", Mutter 50.1 `handle_apply_monitors_config`).
fn is_stale(e: &zbus::Error) -> bool {
    e.to_string().contains("stale information")
}

/// The contract's monitors: every one but a new virtual monitor while lain's is being created, and lain's former
/// displays still listed by Mutter.
pub fn listed(desktop: &Desktop, creating: Option<&HashSet<MonitorSpec>>, gone: &HashSet<MonitorSpec>) -> Vec<Monitor> {
    desktop
        .monitors
        .iter()
        .filter(|m| !gone.contains(&m.spec))
        .filter(|m| !creating.is_some_and(|known| m.is_virtual && !m.monitor.lain && !known.contains(&m.spec)))
        .map(|m| m.monitor.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::display_config::tests::reference_raw;

    /// Review A5: Mutter still lists lain's display after `ClearLain`, and lists the new one before `SetLain`.
    #[test]
    fn lains_display_is_never_listed_as_an_ordinary_monitor() {
        let state = parse_state(reference_raw(2.0));
        let mut ids = IdMap::default();
        let unmarked = desktop::build(&state, None, &mut ids);
        let marked = desktop::build(&state, Some("Meta-0"), &mut ids);
        let meta = state.monitor("Meta-0").unwrap().spec.clone();
        let hdmi = state.monitor("HDMI-1").unwrap().spec.clone();
        let none = HashSet::new();
        assert_eq!(listed(&marked, None, &none).len(), 2);
        // Being created: the new virtual monitor is held back until it is marked.
        let known = HashSet::from([hdmi.clone()]);
        assert_eq!(listed(&unmarked, Some(&known), &none), vec![unmarked.monitors[0].monitor.clone()]);
        assert_eq!(listed(&marked, Some(&known), &none).len(), 2);
        // A virtual monitor that was there before (another client's) stays listed.
        let known = HashSet::from([hdmi, meta.clone()]);
        assert_eq!(listed(&unmarked, Some(&known), &none).len(), 2);
        // Gone: out while Mutter still lists it.
        let gone = HashSet::from([meta]);
        assert_eq!(listed(&unmarked, None, &gone), vec![unmarked.monitors[0].monitor.clone()]);
    }
}
