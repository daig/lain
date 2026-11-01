//! Input injection through `RemoteDesktop.Notify*` (decision L8, lead's decision 1; Swift: the `InputSink`
//! injector posting CGEvents).
//!
//! Input has a RemoteDesktop session of its own, independent of lain's display, holding a consumer-less
//! `RecordMonitor` stream of every monitor, lain's `Meta-*` included: `NotifyPointerMotionAbsolute` needs a
//! stream of the monitor it moves on (spike B §4). So input keeps working without lain's display, after
//! `destroy`, and after Mutter ends the display's session.
//!
//! [`InputBackend::apply`] never blocks: actions go onto an unbounded channel, and one task sends the calls in
//! order with the no-reply flag.
//!
//! When the set of monitors changes, the task builds a new session with a stream of each, switches to it, and
//! then stops the old one, because adding a `RecordMonitor` to a started session was verified for libei only,
//! not for D-Bus motion (spike B, "Recommended design"). **Difference:** a key or button held across that
//! switch is released by Mutter when the old session stops (its virtual devices go with it). The input
//! session closing on its own (the sharing indicator's Stop ends every session) is answered by rebuilding it
//! after a backoff.

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
use crate::input_map::{Barrier, Mapper, Target};

const BACKOFF_MIN: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(30);

/// The input backend.
#[derive(Debug, Clone)]
pub struct GnomeInput {
    tx: mpsc::UnboundedSender<Vec<InputAction>>,
}

impl InputBackend for GnomeInput {
    fn apply(&self, actions: &[InputAction]) {
        if !actions.is_empty() && self.tx.send(actions.to_vec()).is_err() {
            tracing::debug!("input task gone; dropping {} actions", actions.len());
        }
    }
}

impl GnomeInput {
    pub(crate) fn spawn(
        conn: Connection,
        desktop: watch::Receiver<Arc<Desktop>>,
        cursor: Arc<CursorState>,
        barrier: Barrier,
    ) -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        let task = Task { conn, desktop, cursor, mapper: Mapper::new(barrier), session: None };
        tokio::spawn(task.run(rx));
        Self { tx }
    }
}

struct Session {
    remote: RemoteSession,
    /// connector → its stream's object path.
    streams: HashMap<String, String>,
    connectors: Vec<String>,
}

struct Task {
    conn: Connection,
    desktop: watch::Receiver<Arc<Desktop>>,
    cursor: Arc<CursorState>,
    mapper: Mapper,
    session: Option<Session>,
}

async fn build(conn: &Connection, connectors: &[String]) -> zbus::Result<(Session, SignalStream<'static>)> {
    let remote = RemoteSession::create(conn).await?;
    let made = async {
        let closed = remote.closed().await?;
        let mut streams = HashMap::new();
        for c in connectors {
            let path = remote.record_monitor(c).await?;
            streams.insert(c.clone(), path.to_string());
        }
        remote.start().await?;
        Ok::<_, zbus::Error>((closed, streams))
    }
    .await;
    match made {
        Ok((closed, streams)) => Ok((Session { remote, streams, connectors: connectors.to_vec() }, closed)),
        Err(e) => {
            let _ = remote.stop().await;
            Err(e)
        }
    }
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
            })
        })
        .collect()
}

impl Task {
    async fn run(mut self, mut rx: mpsc::UnboundedReceiver<Vec<InputAction>>) {
        let mut backoff = BACKOFF_MIN;
        let mut retry_at = Some(Instant::now());
        // The current session's `Closed`, apart from `self` so the other arms can borrow it.
        let mut closed_signal: Option<SignalStream<'static>> = None;
        loop {
            let closed = async {
                match closed_signal.as_mut() {
                    Some(s) => s.next().await.is_some(),
                    None => std::future::pending().await,
                }
            };
            tokio::select! {
                actions = rx.recv() => {
                    let Some(actions) = actions else { break };
                    self.perform(&actions).await;
                }
                changed = self.desktop.changed() => {
                    if changed.is_err() {
                        break;
                    }
                    let connectors = self.desktop.borrow().connectors();
                    if self.session.as_ref().is_none_or(|s| s.connectors != connectors) {
                        retry_at = Some(Instant::now());
                    }
                    self.retarget();
                }
                still = closed => {
                    tracing::warn!(lost = !still, "input's RemoteDesktop session closed; rebuilding it");
                    self.session = None;
                    closed_signal = None;
                    self.retarget();
                    retry_at = Some(Instant::now() + backoff);
                    backoff = (backoff * 2).min(BACKOFF_MAX);
                }
                _ = tokio::time::sleep_until(retry_at.unwrap_or_else(Instant::now)), if retry_at.is_some() => {
                    retry_at = None;
                    let connectors = self.desktop.borrow().connectors();
                    match build(&self.conn, &connectors).await {
                        Ok((new, closed)) => {
                            tracing::debug!(?connectors, path = new.remote.path(), "input session ready");
                            closed_signal = Some(closed);
                            if let Some(old) = self.session.replace(new) {
                                tokio::spawn(async move {
                                    let _ = old.remote.stop().await;
                                });
                            }
                            self.retarget();
                            backoff = BACKOFF_MIN;
                        }
                        Err(e) => {
                            tracing::warn!("can't set up input's RemoteDesktop session: {e}");
                            retry_at = Some(Instant::now() + backoff);
                            backoff = (backoff * 2).min(BACKOFF_MAX);
                        }
                    }
                }
            }
        }
        if let Some(s) = self.session.take() {
            let _ = s.remote.stop().await;
        }
    }

    fn retarget(&mut self) {
        let targets = match &self.session {
            Some(s) => targets(&self.desktop.borrow(), &s.streams),
            None => Vec::new(),
        };
        self.mapper.set_targets(targets);
    }

    async fn perform(&mut self, actions: &[InputAction]) {
        let Some(session) = &self.session else {
            tracing::debug!("no input session yet; dropping {} actions", actions.len());
            return;
        };
        for action in actions {
            for call in self.mapper.map(action, self.cursor.location()) {
                if let Err(e) = bus::notify(&session.remote.remote, &call).await {
                    tracing::debug!(method = call.method(), "input call: {e}");
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop::{IdMap, build};
    use crate::display_config::{parse_state, tests::reference_raw};
    use lain_platform::RectF;

    #[test]
    fn targets_follow_the_streams_that_exist() {
        let d = build(&parse_state(reference_raw(2.0)), Some("Meta-0"), &mut IdMap::default());
        let mut streams = HashMap::from([("HDMI-1".to_owned(), "/s/1".to_owned())]);
        assert_eq!(
            targets(&d, &streams),
            vec![Target { bounds: RectF::new(0.0, 0.0, 3840.0, 2160.0), stream: "/s/1".into(), primary: true }]
        );
        streams.insert("Meta-0".into(), "/s/2".into());
        let t = targets(&d, &streams);
        assert_eq!(
            t[1],
            Target { bounds: RectF::new(3840.0, 0.0, 1376.0, 1032.0), stream: "/s/2".into(), primary: false }
        );
    }
}
