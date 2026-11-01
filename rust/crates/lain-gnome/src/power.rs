//! Keeping the desktop awake: `org.gnome.SessionManager.Inhibit` (Swift: `IOPMPowerAssertions`, whose
//! `PreventUserIdleDisplaySleep` assertion this replaces).

use lain_platform::PowerBackend;
use tokio::sync::mpsc;
use zbus::Connection;

use crate::bus;

/// What lain tells gnome-session (and so GNOME Settings' list of inhibitors) while an iPad is connected.
pub const REASON: &str = "An iPad is connected";

/// The power backend. `set_awake(true)` takes one inhibitor of suspend and idle (so the screen neither blanks
/// nor locks), `set_awake(false)` releases it; the core counts sessions, so the calls alternate. The calls are
/// queued for a task, so neither blocks. gnome-session drops the inhibitor if lain leaves the bus.
///
/// `user_activity` does nothing: injected input already resets Mutter's idle monitor (decision L8; spike B,
/// §7). Swift declares user activity with `IOPMAssertionDeclareUserActivity`.
#[derive(Debug, Clone)]
pub struct GnomePower {
    tx: mpsc::UnboundedSender<bool>,
}

impl GnomePower {
    pub(crate) fn spawn(conn: Connection) -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        tokio::spawn(run(conn, rx));
        Self { tx }
    }
}

impl PowerBackend for GnomePower {
    fn set_awake(&self, awake: bool) {
        let _ = self.tx.send(awake);
    }

    fn user_activity(&self) {}
}

async fn run(conn: Connection, mut rx: mpsc::UnboundedReceiver<bool>) {
    let proxy = match bus::proxy(&conn, bus::SESSION_MANAGER, bus::SESSION_MANAGER_PATH, bus::SESSION_MANAGER).await {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!("gnome-session isn't reachable; the screen may blank while an iPad is connected: {e}");
            return;
        }
    };
    let mut cookie: Option<u32> = None;
    while let Some(awake) = rx.recv().await {
        match (awake, cookie) {
            (true, None) => match proxy.call::<_, _, u32>("Inhibit", &bus::inhibit_args(REASON)).await {
                Ok(c) => {
                    tracing::debug!(cookie = c, "inhibiting suspend and idle");
                    cookie = Some(c);
                }
                Err(e) => tracing::warn!("SessionManager.Inhibit: {e}"),
            },
            (false, Some(c)) => {
                if let Err(e) = proxy.call::<_, _, ()>("Uninhibit", &(c,)).await {
                    tracing::warn!("SessionManager.Uninhibit: {e}");
                }
                cookie = None;
            }
            _ => {}
        }
    }
    if let Some(c) = cookie {
        let _ = proxy.call::<_, _, ()>("Uninhibit", &(c,)).await;
    }
}
