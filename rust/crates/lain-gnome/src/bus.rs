//! Mutter's and gnome-session's D-Bus names, the arguments lain sends them, and a RemoteDesktop session with
//! its linked ScreenCast session (spike B, `mutter.py`'s `Session`). No Swift counterpart.
//!
//! Every component shares one session-bus connection ([`crate::Gnome::connect`]). Mutter ends a
//! RemoteDesktop or ScreenCast session when the connection that created it closes, and gnome-session drops an
//! inhibitor when its owner leaves the bus, so whatever lain leaves behind goes with the process.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use futures::StreamExt;
use zbus::proxy::{CacheProperties, SignalStream};
use zbus::zvariant::{OwnedObjectPath, Value};
use zbus::{Connection, Proxy};

use crate::input_map::InputCall;

pub const SCREEN_CAST: &str = "org.gnome.Mutter.ScreenCast";
pub const SCREEN_CAST_PATH: &str = "/org/gnome/Mutter/ScreenCast";
pub const SCREEN_CAST_SESSION: &str = "org.gnome.Mutter.ScreenCast.Session";
pub const SCREEN_CAST_STREAM: &str = "org.gnome.Mutter.ScreenCast.Stream";
pub const REMOTE_DESKTOP: &str = "org.gnome.Mutter.RemoteDesktop";
pub const REMOTE_DESKTOP_PATH: &str = "/org/gnome/Mutter/RemoteDesktop";
pub const REMOTE_DESKTOP_SESSION: &str = "org.gnome.Mutter.RemoteDesktop.Session";
pub const DISPLAY_CONFIG: &str = "org.gnome.Mutter.DisplayConfig";
pub const DISPLAY_CONFIG_PATH: &str = "/org/gnome/Mutter/DisplayConfig";
pub const SESSION_MANAGER: &str = "org.gnome.SessionManager";
pub const SESSION_MANAGER_PATH: &str = "/org/gnome/SessionManager";
pub const DCONF_WRITER: &str = "ca.desrt.dconf.Writer";

/// ScreenCast `cursor-mode`: metadata (the cursor travels beside the picture, spike B §6).
pub const CURSOR_MODE_METADATA: u32 = 2;

/// `org.gnome.SessionManager.Inhibit` flags: suspending the machine (4) and the session being marked idle
/// (8), which is what blanks and locks the screen (Swift: `PreventUserIdleDisplaySleep`).
pub const INHIBIT_SUSPEND: u32 = 4;
pub const INHIBIT_IDLE: u32 = 8;

/// `ScreenCast.CreateSession`'s properties: linked to the RemoteDesktop session `id`.
pub fn screen_cast_session_props(id: &str) -> HashMap<&'static str, Value<'_>> {
    HashMap::from([("remote-desktop-session-id", Value::from(id))])
}

/// `RecordVirtual`'s and `RecordMonitor`'s properties: cursor metadata.
pub fn record_props() -> HashMap<&'static str, Value<'static>> {
    HashMap::from([("cursor-mode", Value::from(CURSOR_MODE_METADATA))])
}

/// `Inhibit(s app_id, u toplevel_xid, s reason, u flags)`.
pub fn inhibit_args(reason: &str) -> (&'static str, u32, &str, u32) {
    ("lain", 0, reason, INHIBIT_SUSPEND | INHIBIT_IDLE)
}

/// A proxy that caches no properties (they're read explicitly, and Mutter's session objects have few).
pub async fn proxy(
    conn: &Connection,
    destination: &'static str,
    path: impl TryInto<zbus::zvariant::ObjectPath<'static>, Error: Into<zbus::Error>>,
    interface: &'static str,
) -> zbus::Result<Proxy<'static>> {
    zbus::proxy::Builder::new(conn)
        .destination(destination)?
        .path(path)?
        .interface(interface)?
        .cache_properties(CacheProperties::No)
        .build()
        .await
}

/// Sends one input call without waiting for a reply (the D-Bus no-reply flag), so nothing waits on Mutter.
pub async fn notify(session: &Proxy<'_>, call: &InputCall) -> zbus::Result<()> {
    let method = call.method();
    match call {
        InputCall::MotionAbsolute { stream, x, y } => session.call_noreply(method, &(stream.as_str(), *x, *y)).await,
        InputCall::Key { code, down } => session.call_noreply(method, &(*code, *down)).await,
        InputCall::Button { code, down } => session.call_noreply(method, &(*code, *down)).await,
        InputCall::Axis { dx, dy, flags } => session.call_noreply(method, &(*dx, *dy, *flags)).await,
    }
}

/// A RemoteDesktop session and the ScreenCast session linked to it (spike B, §1).
#[derive(Debug, Clone)]
pub struct RemoteSession {
    pub remote: Proxy<'static>,
    pub cast: Proxy<'static>,
    conn: Connection,
    /// `Start` succeeded: Mutter refuses `Stop` before it ("Session not started", Mutter 50.1 `handle_stop`).
    started: Arc<AtomicBool>,
}

/// Ends the RemoteDesktop session at `remote`, which may never have been started. Mutter refuses `Stop` on an
/// unstarted session and keeps it (and its linked ScreenCast session and streams) until lain's connection
/// closes, so an unstarted one is started first, then stopped (review L2). Starting it briefly runs whatever
/// streams it already has, consumer-less: a monitor stream's PipeWire node, and a virtual stream, which makes
/// no monitor without a consumer (spike B, §1). Failures are logged; then the session stays until the
/// connection closes.
async fn end(remote: &Proxy<'_>, started: bool) {
    if !started && let Err(e) = remote.call::<_, _, ()>("Start", &()).await {
        tracing::debug!(path = %remote.path(), "Start (to stop an unstarted session): {e}");
    }
    if let Err(e) = remote.call::<_, _, ()>("Stop", &()).await {
        tracing::warn!(path = %remote.path(), "can't stop a RemoteDesktop session; it stays until lain exits: {e}");
    }
}

impl RemoteSession {
    /// `RemoteDesktop.CreateSession`, its `SessionId`, then `ScreenCast.CreateSession` linked to it.
    pub async fn create(conn: &Connection) -> zbus::Result<Self> {
        let root = proxy(conn, REMOTE_DESKTOP, REMOTE_DESKTOP_PATH, REMOTE_DESKTOP).await?;
        let path: OwnedObjectPath = root.call("CreateSession", &()).await?;
        let remote = proxy(conn, REMOTE_DESKTOP, path, REMOTE_DESKTOP_SESSION).await?;
        let made = async {
            let id: String = remote.get_property("SessionId").await?;
            let cast_root = proxy(conn, SCREEN_CAST, SCREEN_CAST_PATH, SCREEN_CAST).await?;
            let cast_path: OwnedObjectPath =
                cast_root.call("CreateSession", &(screen_cast_session_props(&id),)).await?;
            proxy(conn, SCREEN_CAST, cast_path, SCREEN_CAST_SESSION).await
        }
        .await;
        match made {
            Ok(cast) => Ok(Self { remote, cast, conn: conn.clone(), started: Arc::new(AtomicBool::new(false)) }),
            Err(e) => {
                end(&remote, false).await;
                Err(e)
            }
        }
    }

    /// `RecordVirtual({cursor-mode: 2})`: the stream object's path.
    pub async fn record_virtual(&self) -> zbus::Result<OwnedObjectPath> {
        self.cast.call("RecordVirtual", &(record_props(),)).await
    }

    /// `RecordMonitor(connector, {cursor-mode: 2})`: the stream object's path.
    pub async fn record_monitor(&self, connector: &str) -> zbus::Result<OwnedObjectPath> {
        self.cast.call("RecordMonitor", &(connector, record_props())).await
    }

    /// A proxy for one of this session's streams.
    pub async fn stream(&self, path: OwnedObjectPath) -> zbus::Result<Proxy<'static>> {
        proxy(&self.conn, SCREEN_CAST, path, SCREEN_CAST_STREAM).await
    }

    /// The `Closed` signal, subscribed before anything can close it. The stream ends if the connection does.
    pub async fn closed(&self) -> zbus::Result<SignalStream<'static>> {
        self.remote.receive_signal("Closed").await
    }

    pub async fn start(&self) -> zbus::Result<()> {
        self.remote.call::<_, _, ()>("Start", &()).await?;
        self.started.store(true, Ordering::Release);
        Ok(())
    }

    /// `Stop`: Mutter removes the session's streams (and a virtual monitor) and emits `Closed`. Refused for a
    /// session that wasn't started: use [`discard`](Self::discard) where that is possible.
    pub async fn stop(&self) -> zbus::Result<()> {
        self.remote.call("Stop", &()).await
    }

    /// Ends the session whether or not it was started (see [`end`]); errors are logged.
    pub async fn discard(&self) {
        end(&self.remote, self.started.load(Ordering::Acquire)).await;
    }

    pub fn path(&self) -> String {
        self.remote.path().to_string()
    }
}

/// The node id from a stream's `PipeWireStreamAdded(u node_id)`.
pub async fn next_node_id(added: &mut SignalStream<'static>) -> Option<u32> {
    let msg = added.next().await?;
    msg.body().deserialize::<u32>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use zbus::zvariant::{DynamicType, Type};

    #[test]
    fn session_and_record_properties() {
        let p = screen_cast_session_props("abc");
        assert_eq!(p.get("remote-desktop-session-id"), Some(&Value::from("abc")));
        assert_eq!(<HashMap<&str, Value<'_>> as Type>::SIGNATURE.to_string(), "a{sv}");
        assert_eq!(record_props().get("cursor-mode"), Some(&Value::from(2u32)));
        // RecordMonitor(s connector, a{sv} properties).
        let args = ("HDMI-1", record_props());
        assert_eq!(args.signature().to_string(), "(sa{sv})");
    }

    #[test]
    fn inhibit_blocks_suspend_and_idle() {
        let args = inhibit_args("An iPad is connected");
        assert_eq!(args, ("lain", 0, "An iPad is connected", 12));
        assert_eq!(args.signature().to_string(), "(susu)");
    }

    #[test]
    fn input_calls_match_mutters_signatures() {
        // org.gnome.Mutter.RemoteDesktop.Session: NotifyPointerMotionAbsolute(sdd), NotifyKeyboardKeycode(ub),
        // NotifyPointerButton(ib), NotifyPointerAxis(ddu).
        assert_eq!(<(&str, f64, f64) as Type>::SIGNATURE.to_string(), "(sdd)");
        assert_eq!(<(u32, bool) as Type>::SIGNATURE.to_string(), "(ub)");
        assert_eq!(<(i32, bool) as Type>::SIGNATURE.to_string(), "(ib)");
        assert_eq!(<(f64, f64, u32) as Type>::SIGNATURE.to_string(), "(ddu)");
        let key = InputCall::Key { code: 42, down: true };
        assert_eq!(key.method(), "NotifyKeyboardKeycode");
        let InputCall::Key { code, down } = key else { unreachable!() };
        let _: (u32, bool) = (code, down);
        let InputCall::Button { code, .. } = (InputCall::Button { code: 0x110, down: true }) else { unreachable!() };
        let _: i32 = code;
    }
}
