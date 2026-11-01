//! A fake Mutter on a private `dbus-daemon`, for the lifecycle tests: `RemoteDesktop`, `ScreenCast` and
//! `DisplayConfig` with just the behaviour lain depends on, as Mutter 50.1 has it (`Stop` refused before
//! `Start`, `Closed` on `Stop`). Its streams never announce a PipeWire node, so nothing here reaches PipeWire,
//! the real session bus, the desktop or a GPU. Without `dbus-daemon` the tests say so and pass.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lain_platform::{DisplayBackend, DisplaySpec, InputAction, InputBackend, PointF};
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

use crate::cursor::CursorState;
use crate::display::GnomeDisplay;
use crate::display_config::RawState;
use crate::display_config::tests::reference_raw;
use crate::input::GnomeInput;
use crate::input_map::Barrier;
use crate::monitors;

/// A private bus, killed on drop.
struct Bus {
    child: Child,
    address: String,
    _dir: tempfile::TempDir,
}

impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn bus() -> Option<Bus> {
    let dir = tempfile::tempdir().ok()?;
    let conf = dir.path().join("bus.conf");
    let socket_dir = dir.path().display().to_string();
    std::fs::write(
        &conf,
        format!(
            r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:dir={socket_dir}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"#
        ),
    )
    .ok()?;
    let child = Command::new("dbus-daemon")
        .args([&format!("--config-file={}", conf.display()), "--nofork", "--print-address=1", "--nopidfile"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => {
            eprintln!("no dbus-daemon ({e}): skipping");
            return None;
        }
    };
    let mut line = String::new();
    BufReader::new(child.stdout.take()?).read_line(&mut line).ok()?;
    Some(Bus { child, address: line.trim().to_owned(), _dir: dir })
}

/// The layout the fake's `GetCurrentState` reports.
#[derive(Debug, Clone, Copy)]
struct Layout {
    /// Meta-0 listed, at this scale.
    lain_scale: Option<f64>,
    /// HDMI-1's x (Meta-0 is right of it, or left of it when this isn't 0).
    hdmi_x: i32,
    serial: u32,
}

#[derive(Debug, Default)]
struct Rd {
    started: bool,
    stopped: bool,
}

#[derive(Debug)]
struct State {
    layout: Layout,
    sessions: Vec<Rd>,
    /// `RecordMonitor` of this connector fails.
    fail_record_monitor: Option<String>,
    /// `(session, stream, x, y)` of every `NotifyPointerMotionAbsolute`.
    motions: Vec<(usize, String, f64, f64)>,
}

#[derive(Clone)]
struct Fake(Arc<Mutex<State>>);

impl Fake {
    fn new(layout: Layout) -> Self {
        Fake(Arc::new(Mutex::new(State { layout, sessions: vec![], fail_record_monitor: None, motions: vec![] })))
    }

    fn with<T>(&self, f: impl FnOnce(&mut State) -> T) -> T {
        f(&mut self.0.lock().unwrap())
    }

    /// Sessions made and sessions still registered with "Mutter" (not stopped).
    fn sessions(&self) -> (usize, usize) {
        self.with(|s| (s.sessions.len(), s.sessions.iter().filter(|r| !r.stopped).count()))
    }
}

fn raw(layout: Layout) -> RawState {
    let mut raw = reference_raw(layout.lain_scale.unwrap_or(1.0));
    raw.0 = layout.serial;
    match layout.lain_scale {
        None => {
            raw.1.truncate(1);
            raw.2.truncate(1);
        }
        Some(_) => {
            raw.2[0].0 = layout.hdmi_x;
            if layout.hdmi_x != 0 {
                raw.2[1].0 = 0;
            }
        }
    }
    raw
}

struct RdRoot(Fake);

#[zbus::interface(name = "org.gnome.Mutter.RemoteDesktop")]
impl RdRoot {
    async fn create_session(&self, #[zbus(object_server)] server: &zbus::ObjectServer) -> OwnedObjectPath {
        let n = self.0.with(|s| {
            s.sessions.push(Rd::default());
            s.sessions.len() - 1
        });
        let path = format!("/org/gnome/Mutter/RemoteDesktop/Session/s{n}");
        server.at(path.as_str(), RdSession(self.0.clone(), n)).await.unwrap();
        OwnedObjectPath::try_from(path).unwrap()
    }
}

struct RdSession(Fake, usize);

#[zbus::interface(name = "org.gnome.Mutter.RemoteDesktop.Session")]
impl RdSession {
    #[zbus(property)]
    fn session_id(&self) -> String {
        format!("s{}", self.1)
    }

    fn start(&self) {
        self.0.with(|s| s.sessions[self.1].started = true);
    }

    /// As Mutter 50.1's `handle_stop`: refused before `Start`; else the session closes.
    async fn stop(&self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> zbus::fdo::Result<()> {
        let started = self.0.with(|s| s.sessions[self.1].started);
        if !started {
            return Err(zbus::fdo::Error::Failed("Session not started".into()));
        }
        self.0.with(|s| s.sessions[self.1].stopped = true);
        let _ = Self::closed(&emitter).await;
        Ok(())
    }

    fn notify_pointer_motion_absolute(&self, stream: &str, x: f64, y: f64) {
        self.0.with(|s| s.motions.push((self.1, stream.to_owned(), x, y)));
    }

    fn notify_pointer_button(&self, _button: i32, _state: bool) {}

    #[zbus(signal)]
    async fn closed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

struct ScRoot(Fake);

#[zbus::interface(name = "org.gnome.Mutter.ScreenCast")]
impl ScRoot {
    async fn create_session(
        &self,
        props: HashMap<String, OwnedValue>,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> OwnedObjectPath {
        let id: String = props.get("remote-desktop-session-id").unwrap().try_clone().unwrap().try_into().unwrap();
        let path = format!("/org/gnome/Mutter/ScreenCast/Session/{id}");
        server.at(path.as_str(), ScSession(self.0.clone(), id)).await.unwrap();
        OwnedObjectPath::try_from(path).unwrap()
    }
}

struct ScSession(Fake, String);

#[zbus::interface(name = "org.gnome.Mutter.ScreenCast.Session")]
impl ScSession {
    async fn record_virtual(
        &self,
        _props: HashMap<String, OwnedValue>,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> OwnedObjectPath {
        let path = format!("/org/gnome/Mutter/ScreenCast/Stream/v{}", self.1);
        server.at(path.as_str(), Stream).await.unwrap();
        OwnedObjectPath::try_from(path).unwrap()
    }

    async fn record_monitor(
        &self,
        connector: &str,
        _props: HashMap<String, OwnedValue>,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        if self.0.with(|s| s.fail_record_monitor.as_deref() == Some(connector)) {
            return Err(zbus::fdo::Error::Failed(format!("Unknown monitor {connector}")));
        }
        let path = format!("/org/gnome/Mutter/ScreenCast/Stream/m{}{}", self.1, connector.replace('-', "_"));
        server.at(path.as_str(), Stream).await.unwrap();
        Ok(OwnedObjectPath::try_from(path).unwrap())
    }
}

/// A stream that never announces a PipeWire node.
struct Stream;

#[zbus::interface(name = "org.gnome.Mutter.ScreenCast.Stream")]
impl Stream {
    #[zbus(property)]
    fn parameters(&self) -> HashMap<String, OwnedValue> {
        HashMap::new()
    }

    #[zbus(signal)]
    async fn pipe_wire_stream_added(emitter: &SignalEmitter<'_>, node: u32) -> zbus::Result<()>;
}

struct DisplayConfig(Fake);

#[zbus::interface(name = "org.gnome.Mutter.DisplayConfig")]
impl DisplayConfig {
    fn get_current_state(&self) -> RawState {
        raw(self.0.with(|s| s.layout))
    }

    #[zbus(signal)]
    async fn monitors_changed(emitter: &SignalEmitter<'_>) -> zbus::Result<()>;
}

struct Mutter {
    conn: zbus::Connection,
    fake: Fake,
}

impl Mutter {
    async fn start(bus: &Bus, layout: Layout) -> Mutter {
        let fake = Fake::new(layout);

        let conn = zbus::connection::Builder::address(bus.address.as_str())
            .unwrap()
            .serve_at("/org/gnome/Mutter/RemoteDesktop", RdRoot(fake.clone()))
            .unwrap()
            .serve_at("/org/gnome/Mutter/ScreenCast", ScRoot(fake.clone()))
            .unwrap()
            .serve_at("/org/gnome/Mutter/DisplayConfig", DisplayConfig(fake.clone()))
            .unwrap()
            .name("org.gnome.Mutter.RemoteDesktop")
            .unwrap()
            .name("org.gnome.Mutter.ScreenCast")
            .unwrap()
            .name("org.gnome.Mutter.DisplayConfig")
            .unwrap()
            .build()
            .await
            .unwrap();
        Mutter { conn, fake }
    }

    /// A new layout, announced with `MonitorsChanged`.
    async fn relayout(&self, f: impl FnOnce(&mut Layout)) {
        self.fake.with(|s| {
            f(&mut s.layout);
            s.layout.serial += 1;
        });
        let iface = self.conn.object_server().interface::<_, DisplayConfig>("/org/gnome/Mutter/DisplayConfig").await;
        DisplayConfig::monitors_changed(iface.unwrap().signal_emitter()).await.unwrap();
    }

    /// Mutter closing session `n` on its own (the sharing indicator's Stop).
    async fn close(&self, n: usize) {
        let path = format!("/org/gnome/Mutter/RemoteDesktop/Session/s{n}");
        let iface = self.conn.object_server().interface::<_, RdSession>(path.as_str()).await.unwrap();
        self.fake.with(|s| s.sessions[n].stopped = true);
        RdSession::closed(iface.signal_emitter()).await.unwrap();
    }
}

async fn client(bus: &Bus) -> zbus::Connection {
    zbus::connection::Builder::address(bus.address.as_str()).unwrap().build().await.unwrap()
}

const IPAD: DisplaySpec = DisplaySpec { pixel_width: 2752, pixel_height: 2064, scale: 2, refresh_hz: 120 };
const NO_LAIN: Layout = Layout { lain_scale: None, hdmi_x: 0, serial: 1 };

async fn settle() {
    tokio::time::sleep(Duration::from_millis(200)).await;
}

/// Review L1: a `create` dropped half-way left Mutter's session started, and `destroy` couldn't reach it.
#[tokio::test]
async fn a_dropped_create_removes_what_it_made() {
    let Some(b) = bus() else { return };
    let mutter = Mutter::start(&b, NO_LAIN).await;
    let conn = client(&b).await;
    let cursor = CursorState::new();
    let desktop = monitors::spawn(&conn, cursor.clone(), None).await.unwrap();
    let display = GnomeDisplay::new(conn.clone(), desktop, cursor);
    // The fake's stream never announces a node: create waits for it, and is dropped meanwhile.
    assert!(tokio::time::timeout(Duration::from_millis(300), display.create(IPAD)).await.is_err());
    assert_eq!(mutter.fake.sessions(), (1, 1), "the session is up while the creation runs on");
    // destroy waits for the abandoned creation, which removes its session itself.
    tokio::time::timeout(Duration::from_secs(10), display.destroy()).await.expect("destroy ends");
    assert_eq!(mutter.fake.sessions(), (1, 0), "every Mutter session lain made is stopped");
    // And the next create isn't refused as "already exists" (it fails on the fake's missing node instead).
    let again = tokio::time::timeout(Duration::from_secs(10), display.create(IPAD)).await.expect("ends");
    assert!(again.is_err_and(|e| e.to_string().contains("PipeWire node")));
    assert_eq!(mutter.fake.sessions(), (2, 0));
}

/// Review L2: a setup that failed before `Start` called `Stop`, which Mutter refuses, so the session stayed.
#[tokio::test]
async fn a_failed_input_setup_leaves_no_session() {
    let Some(b) = bus() else { return };
    let mutter = Mutter::start(&b, Layout { lain_scale: Some(2.0), ..NO_LAIN }).await;
    mutter.fake.with(|s| s.fail_record_monitor = Some("Meta-0".into()));
    let conn = client(&b).await;
    let cursor = CursorState::new();
    let desktop = monitors::spawn(&conn, cursor.clone(), None).await.unwrap();
    let input = GnomeInput::spawn(conn.clone(), desktop.desktop.clone(), cursor, Barrier::default());
    input.apply(&[InputAction::MoveTo(PointF::new(100.0, 10.0))]);
    settle().await;
    assert_eq!(mutter.fake.sessions(), (1, 0));
}

/// Motions sent for a +x move across the primary's right edge in the panel band, after a drag whose release
/// arrived while input had no session (`close`), or a normal drag.
async fn detour_motions(close: bool) -> Option<usize> {
    let b = bus()?;
    let mutter = Mutter::start(&b, Layout { lain_scale: Some(2.0), ..NO_LAIN }).await;
    let conn = client(&b).await;
    let cursor = CursorState::new();
    let desktop = monitors::spawn(&conn, cursor.clone(), None).await.unwrap();
    let input = GnomeInput::spawn(conn.clone(), desktop.desktop.clone(), cursor, Barrier::default());
    input.apply(&[InputAction::MoveTo(PointF::new(100.0, 10.0)), InputAction::Button { code: 0x110, down: true }]);
    settle().await;
    if close {
        mutter.close(0).await;
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    input.apply(&[InputAction::Button { code: 0x110, down: false }]);
    // Past the 1 s backoff after the close.
    tokio::time::sleep(Duration::from_millis(1300)).await;
    input.apply(&[InputAction::MoveTo(PointF::new(100.0, 10.0))]);
    settle().await;
    let before = mutter.fake.with(|s| s.motions.len());
    input.apply(&[InputAction::MoveTo(PointF::new(4000.0, 10.0))]);
    settle().await;
    Some(mutter.fake.with(|s| s.motions.len()) - before)
}

/// Review L3: the release was dropped before the mapper saw it, so the detour stayed off for good.
#[tokio::test]
async fn a_release_dropped_while_no_session_keeps_the_detour() {
    let Some(normal) = detour_motions(false).await else { return };
    assert_eq!(normal, 3, "the detour applies after a normal drag");
    assert_eq!(detour_motions(true).await, Some(3), "and after a drag whose session closed");
}

/// Reviews DB1, DB2 and L4: motion in stream pixels at scale 2; a re-scale or a move with the same connectors
/// rebuilds input's session (Mutter closes those streams); a failed rebuild is retried on the next input.
#[tokio::test]
async fn input_follows_every_change_of_a_monitors_rectangle() {
    let Some(b) = bus() else { return };
    let mutter = Mutter::start(&b, Layout { lain_scale: Some(1.0), ..NO_LAIN }).await;
    let conn = client(&b).await;
    let cursor = CursorState::new();
    let desktop = monitors::spawn(&conn, cursor.clone(), None).await.unwrap();
    let input = GnomeInput::spawn(conn.clone(), desktop.desktop.clone(), cursor, Barrier::default());
    input.apply(&[InputAction::MoveTo(PointF::new(100.0, 1000.0))]);
    settle().await;
    assert_eq!(mutter.fake.sessions(), (1, 1));
    // lain's display re-scaled to 2 in place: same connectors, new rectangle.
    mutter.relayout(|l| l.lain_scale = Some(2.0)).await;
    settle().await;
    assert_eq!(mutter.fake.sessions(), (2, 1), "rebuilt, the old session stopped");
    input.apply(&[InputAction::MoveTo(PointF::new(3840.0 + 688.0, 516.0))]);
    settle().await;
    let last = mutter.fake.with(|s| s.motions.last().cloned()).unwrap();
    assert_eq!((last.0, last.1.ends_with("Meta_0"), last.2, last.3), (1, true, 1376.0, 1032.0));
    // A move whose rebuild fails keeps the old session, marked stale ...
    mutter.fake.with(|s| s.fail_record_monitor = Some("Meta-0".into()));
    mutter.relayout(|l| l.hdmi_x = 1376).await;
    settle().await;
    assert_eq!(mutter.fake.sessions(), (3, 1));
    // ... and the next input after the backoff rebuilds it.
    mutter.fake.with(|s| s.fail_record_monitor = None);
    tokio::time::sleep(Duration::from_millis(1100)).await;
    input.apply(&[InputAction::MoveTo(PointF::new(100.0, 10.0))]);
    settle().await;
    assert_eq!(mutter.fake.sessions(), (4, 1));
    let last = mutter.fake.with(|s| s.motions.last().cloned()).unwrap();
    assert_eq!((last.0, last.1.ends_with("Meta_0"), last.2, last.3), (3, true, 200.0, 20.0));
}
