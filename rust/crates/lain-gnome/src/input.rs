//! Input injection through `RemoteDesktop.Notify*` (decision L8, lead's decision 1; Swift: the `InputSink`
//! injector posting CGEvents).
//!
//! Input has a RemoteDesktop session of its own, independent of lain's display, holding a consumer-less
//! `RecordMonitor` stream of every monitor, lain's `Meta-*` included: `NotifyPointerMotionAbsolute` needs a
//! stream of the monitor it moves on (spike B §4). So input keeps working without lain's display, after
//! `destroy`, and after Mutter ends the display's session.
//!
//! [`InputBackend::apply`] never blocks: actions go onto an unbounded channel, and one task sends the calls in
//! order with the no-reply flag. Setting a session up is bounded by [`SETUP_TIMEOUT`], so a stalled Mutter
//! holds the queue for seconds at most; the actions that queued meanwhile are sent with each run of pointer
//! moves cut to its last one, so a stall replays no stale motion. Keys, buttons and scrolls are never dropped.
//!
//! The session exists only while input flows: the first actions build it (they wait in the channel meanwhile,
//! tens of milliseconds), and it stops after [`IDLE`] without any. A RemoteDesktop session with streams shows
//! GNOME Shell's screen-sharing indicator, which shouldn't stay up while no iPad uses lain. New in the port:
//! macOS needs no session to post events.
//!
//! Mutter closes a monitor stream whenever its logical monitor's rectangle changes (Mutter 50.1,
//! `meta-screen-cast-monitor-stream.c` `update_monitor`), leaving the session without it. So when any
//! monitor's connector, rectangle or scale changes, the task builds a new session with a stream of each,
//! switches to it, and then stops the old one, because adding a `RecordMonitor` to a started session was
//! verified for libei only, not for D-Bus motion (spike B, "Recommended design"). A rebuild that fails is
//! retried on the next actions, after the backoff. **Difference:** a key or button held across that switch is
//! released by Mutter when the old session stops (its virtual devices go with it). If the session closes on
//! its own (the sharing indicator's Stop ends every session), the next actions rebuild it, no sooner than a
//! backoff after the last attempt.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use futures::StreamExt;
use lain_platform::{InputAction, InputBackend};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;
use zbus::Connection;
use zbus::proxy::SignalStream;

use crate::bus::{self, RemoteSession};
use crate::cursor::CursorState;
use crate::desktop::Desktop;
use crate::display_config::{IRect, LayoutMode};
use crate::input_map::{Barrier, Mapper, Target};

const BACKOFF_MIN: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(30);
/// How long input's session outlives the last action.
pub const IDLE: Duration = Duration::from_secs(300);
/// The most a session's setup (`CreateSession` … `Start`) may take; past it, it counts as failed (and is
/// stopped if it completes later). Spike B's took tens of milliseconds.
pub const SETUP_TIMEOUT: Duration = Duration::from_secs(5);
/// The most lain waits on one `Stop`.
const STOP_TIMEOUT: Duration = Duration::from_secs(2);

/// The input backend.
#[derive(Debug, Clone)]
pub struct GnomeInput {
    tx: mpsc::UnboundedSender<Vec<InputAction>>,
    /// The current layout's keys, for typed text (v6 `TextInput`); empty until [`with_text_keys`](Self::with_text_keys).
    text_keys: crate::settings::SharedTextKeys,
}

impl InputBackend for GnomeInput {
    fn apply(&self, actions: &[InputAction]) {
        if !actions.is_empty() && self.tx.send(actions.to_vec()).is_err() {
            tracing::debug!("input task gone; dropping {} actions", actions.len());
        }
    }

    fn text_key(&self, c: char) -> Option<lain_platform::TextKey> {
        self.text_keys.read().unwrap_or_else(|e| e.into_inner()).get(c)
    }
}

impl GnomeInput {
    /// Starts the input task on `conn`, following the monitors in `desktop`. No session exists until the first
    /// [`apply`](InputBackend::apply).
    pub fn spawn(
        conn: Connection,
        desktop: watch::Receiver<Arc<Desktop>>,
        cursor: Arc<CursorState>,
        barrier: Barrier,
    ) -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        let task = Task { conn, desktop, cursor, mapper: Mapper::new(barrier), session: None, stale: false };
        tokio::spawn(task.run(rx));
        Self { tx, text_keys: Default::default() }
    }

    /// Types text with `keys`, the settings' table ([`GnomeSettings::text_keys`](crate::GnomeSettings::text_keys)).
    pub fn with_text_keys(mut self, keys: crate::settings::SharedTextKeys) -> Self {
        self.text_keys = keys;
        self
    }
}

/// What a session's streams were made for: each monitor's connector, rectangle and scale, in order. Mutter
/// keeps a monitor stream only while its monitor's rectangle stays the same.
pub type Layout = Vec<(String, IRect, f64)>;

/// The layout `desktop` shows.
pub fn layout(desktop: &Desktop) -> Layout {
    desktop.monitors.iter().map(|m| (m.spec.connector.clone(), m.rect, m.scale)).collect()
}

struct Session {
    remote: RemoteSession,
    /// connector → its stream's object path.
    streams: HashMap<String, String>,
    layout: Layout,
}

struct Task {
    conn: Connection,
    desktop: watch::Receiver<Arc<Desktop>>,
    cursor: Arc<CursorState>,
    mapper: Mapper,
    session: Option<Session>,
    /// The session's streams no longer match the desktop and rebuilding it failed: retry on the next actions.
    stale: bool,
}

async fn build(conn: Connection, layout: Layout) -> zbus::Result<(Session, SignalStream<'static>)> {
    let remote = RemoteSession::create(&conn).await?;
    let made = async {
        let closed = remote.closed().await?;
        let mut streams = HashMap::new();
        for (c, _, _) in &layout {
            let path = remote.record_monitor(c).await?;
            streams.insert(c.clone(), path.to_string());
        }
        remote.start().await?;
        Ok::<_, zbus::Error>((closed, streams))
    }
    .await;
    match made {
        Ok((closed, streams)) => Ok((Session { remote, streams, layout }, closed)),
        Err(e) => {
            remote.discard().await;
            Err(e)
        }
    }
}

/// [`build`] within [`SETUP_TIMEOUT`]. It runs on a task of its own, so a setup that completes after the
/// timeout is still stopped.
async fn build_in_time(conn: &Connection, layout: Layout) -> zbus::Result<(Session, SignalStream<'static>)> {
    let mut task = tokio::spawn(build(conn.clone(), layout));
    match tokio::time::timeout(SETUP_TIMEOUT, &mut task).await {
        Ok(Ok(made)) => made,
        Ok(Err(e)) => Err(zbus::Error::Failure(format!("input's session setup: {e}"))),
        Err(_) => {
            tokio::spawn(async move {
                if let Ok(Ok((late, _))) = task.await {
                    late.remote.discard().await;
                }
            });
            Err(zbus::Error::Failure(format!("input's session setup took over {SETUP_TIMEOUT:?}")))
        }
    }
}

/// Stops `session` without waiting on it.
fn stop_later(session: Session) {
    tokio::spawn(async move {
        if tokio::time::timeout(STOP_TIMEOUT, session.remote.stop()).await.is_err() {
            tracing::debug!(path = session.remote.path(), "Stop of input's old session timed out");
        }
    });
}

/// The monitors input can reach: those in `desktop` with a stream in `streams`.
pub fn targets(desktop: &Desktop, streams: &HashMap<String, String>) -> Vec<Target> {
    desktop
        .monitors
        .iter()
        .filter_map(|m| {
            Some(Target {
                bounds: m.monitor.bounds,
                stream: streams.get(&m.spec.connector)?.clone(),
                primary: m.monitor.primary,
                scale: match desktop.layout_mode {
                    LayoutMode::Logical => m.scale,
                    LayoutMode::Physical => 1.0,
                },
            })
        })
        .collect()
}

/// `actions` with each run of consecutive pointer moves cut to its last one.
pub fn coalesce_moves(actions: Vec<InputAction>) -> Vec<InputAction> {
    let mut out: Vec<InputAction> = Vec::with_capacity(actions.len());
    for a in actions {
        if matches!(a, InputAction::MoveTo(_))
            && let Some(last @ InputAction::MoveTo(_)) = out.last_mut()
        {
            *last = a;
        } else {
            out.push(a);
        }
    }
    out
}

impl Task {
    async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Vec<InputAction>>) {
        let mut backoff = BACKOFF_MIN;
        // No attempt before this (after a failure, or the session closing on its own).
        let mut not_before = Instant::now();
        let mut last_action = Instant::now();
        // The current session's `Closed`, apart from `self` so the other arms can borrow it.
        let mut closed_signal: Option<SignalStream<'static>> = None;
        loop {
            let closed = async {
                match closed_signal.as_mut() {
                    Some(s) => s.next().await.is_some(),
                    None => std::future::pending().await,
                }
            };
            let has_session = self.session.is_some();
            tokio::select! {
                actions = rx.recv() => {
                    let Some(mut actions) = actions else { break };
                    last_action = Instant::now();
                    if (self.session.is_none() || self.stale) && Instant::now() >= not_before {
                        match self.connect().await {
                            Ok(closed) => {
                                closed_signal = Some(closed);
                                backoff = BACKOFF_MIN;
                            }
                            Err(()) => {
                                not_before = Instant::now() + backoff;
                                backoff = (backoff * 2).min(BACKOFF_MAX);
                            }
                        }
                    }
                    // Whatever queued meanwhile (a setup, or a slow Mutter) goes now, without stale moves.
                    let mut queued = false;
                    while let Ok(more) = rx.try_recv() {
                        actions.extend(more);
                        queued = true;
                    }
                    if queued {
                        actions = coalesce_moves(actions);
                    }
                    self.perform(&actions).await;
                }
                changed = self.desktop.changed() => {
                    if changed.is_err() {
                        break;
                    }
                    let now = layout(&self.desktop.borrow());
                    if self.session.as_ref().is_some_and(|s| s.layout != now) {
                        match self.connect().await {
                            Ok(closed) => {
                                closed_signal = Some(closed);
                                backoff = BACKOFF_MIN;
                            }
                            Err(()) => {
                                self.stale = true;
                                not_before = Instant::now() + backoff;
                                backoff = (backoff * 2).min(BACKOFF_MAX);
                            }
                        }
                    }
                    self.retarget();
                }
                still = closed => {
                    tracing::warn!(lost = !still, "input's RemoteDesktop session closed; the next input rebuilds it");
                    self.session = None;
                    self.stale = false;
                    self.mapper.session_ended();
                    closed_signal = None;
                    self.retarget();
                    not_before = Instant::now() + backoff;
                    backoff = (backoff * 2).min(BACKOFF_MAX);
                }
                _ = tokio::time::sleep_until(last_action + IDLE), if has_session => {
                    tracing::debug!("no input for {IDLE:?}; stopping input's session");
                    closed_signal = None;
                    self.stale = false;
                    if let Some(s) = self.session.take() {
                        stop_later(s);
                    }
                    self.mapper.session_ended();
                    self.retarget();
                }
            }
        }
        if let Some(s) = self.session.take() {
            let _ = tokio::time::timeout(STOP_TIMEOUT, s.remote.stop()).await;
        }
    }

    /// Builds a session with a stream of every monitor now, switches to it, then stops the old one.
    async fn connect(&mut self) -> Result<SignalStream<'static>, ()> {
        let layout = layout(&self.desktop.borrow());
        match build_in_time(&self.conn, layout).await {
            Ok((new, closed)) => {
                tracing::debug!(layout = ?new.layout, path = new.remote.path(), "input session ready");
                if let Some(old) = self.session.replace(new) {
                    // Mutter releases what the old session's devices held.
                    self.mapper.buttons_released();
                    stop_later(old);
                }
                self.stale = false;
                self.retarget();
                Ok(closed)
            }
            Err(e) => {
                tracing::warn!("can't set up input's RemoteDesktop session: {e}");
                Err(())
            }
        }
    }

    fn retarget(&mut self) {
        let targets = match &self.session {
            Some(s) => targets(&self.desktop.borrow(), &s.streams),
            None => Vec::new(),
        };
        self.mapper.set_targets(targets);
    }

    /// Sends the calls for `actions`. Without a session they are still mapped, so the mapper's held buttons
    /// stay true (review L3), and the calls dropped.
    async fn perform(&mut self, actions: &[InputAction]) {
        let mut dropped = 0;
        for action in actions {
            let calls = self.mapper.map(action, self.cursor.location());
            let Some(session) = &self.session else {
                dropped += calls.len();
                continue;
            };
            for call in calls {
                if let Err(e) = bus::notify(&session.remote.remote, &call).await {
                    tracing::debug!(method = call.method(), "input call: {e}");
                }
            }
        }
        if dropped > 0 {
            tracing::debug!("no input session; dropped {dropped} calls");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop::{IdMap, build};
    use crate::display_config::{parse_state, tests::reference_raw};
    use lain_platform::{PointF, RectF};

    #[test]
    fn targets_follow_the_streams_that_exist() {
        let d = build(&parse_state(reference_raw(2.0)), Some("Meta-0"), &mut IdMap::default());
        let mut streams = HashMap::from([("HDMI-1".to_owned(), "/s/1".to_owned())]);
        assert_eq!(
            targets(&d, &streams),
            vec![Target {
                bounds: RectF::new(0.0, 0.0, 3840.0, 2160.0),
                stream: "/s/1".into(),
                primary: true,
                scale: 1.0
            }]
        );
        streams.insert("Meta-0".into(), "/s/2".into());
        let t = targets(&d, &streams);
        assert_eq!(
            t[1],
            Target {
                bounds: RectF::new(3840.0, 0.0, 1376.0, 1032.0),
                stream: "/s/2".into(),
                primary: false,
                scale: 2.0
            }
        );
        // Physical layout mode: global coordinates are device pixels already.
        let mut d = d;
        d.layout_mode = LayoutMode::Physical;
        assert_eq!(targets(&d, &streams)[1].scale, 1.0);
    }

    /// Review DB2: Mutter closes a monitor stream when its rectangle changes, so a change of position or scale
    /// with the same connectors must rebuild input's session.
    #[test]
    fn the_layout_changes_with_a_monitors_position_or_scale() {
        let at_one = layout(&build(&parse_state(reference_raw(1.0)), None, &mut IdMap::default()));
        let at_two = layout(&build(&parse_state(reference_raw(2.0)), None, &mut IdMap::default()));
        assert_ne!(at_one, at_two);
        let mut moved = parse_state(reference_raw(2.0));
        moved.logical[0].x = 1376;
        moved.logical[1].x = 0;
        assert_ne!(layout(&build(&moved, None, &mut IdMap::default())), at_two);
        assert_eq!(layout(&build(&parse_state(reference_raw(2.0)), Some("Meta-0"), &mut IdMap::default())), at_two);
    }

    #[test]
    fn queued_moves_are_cut_to_the_last_of_each_run() {
        let m = |x| InputAction::MoveTo(PointF::new(x, 0.0));
        let down = InputAction::Button { code: 0x110, down: true };
        let up = InputAction::Button { code: 0x110, down: false };
        let got = coalesce_moves(vec![m(1.0), m(2.0), m(3.0), down, m(4.0), m(5.0), up, m(6.0)]);
        assert_eq!(got, vec![m(3.0), down, m(5.0), up, m(6.0)]);
    }
}
