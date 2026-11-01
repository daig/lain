//! Live tests on the GNOME desktop of the user running them. Every one is `#[ignore]`d; run them one at a
//! time, from `rust/`, with the developer told:
//!
//! ```text
//! cargo test -p lain-gnome --test live -- --ignored --test-threads=1 <name>
//! ```
//!
//! Names say what a test does to the desktop:
//! - `read_only_*`: D-Bus reads (`GetCurrentState`, property reads) and `gsettings get`. Nothing changes.
//! - `inhibit_*`: one `SessionManager.Inhibit` and its `Uninhibit`.
//! - `desktop_*`: create lain's virtual monitor (`RecordVirtual`, a PipeWire consumer, `ApplyMonitorsConfig`
//!   **method 1** for scale 2), and some inject pointer motion. Each documents exactly what it does.
//!
//! Input rules (wave-1 lesson): the pointer's position is checked before every injected action and put back
//! where it was; no key is sent by any test here. The arrangement store is a temporary file, never the owner's
//! `~/.config/lain/arrangement.toml`. Every session is stopped at the end, and closing the connection (the
//! process ending) removes anything left.

use std::sync::Arc;
use std::time::Duration;

use lain_gnome::arrangement::Store;
use lain_gnome::bus::{self, RemoteSession};
use lain_gnome::display_config::{RawState, parse_state};
use lain_gnome::monitors::{self, DesktopHandle};
use lain_gnome::negotiate::{self, Negotiation};
use lain_gnome::{Barrier, CursorState, GnomeDisplay, GnomeInput, GnomePower, StreamGeometry, settings};
use lain_platform::{DisplayBackend, DisplaySpec, InputAction, InputBackend, Monitor, PointF, PowerBackend};
use zbus::Connection;
use zbus::zvariant::OwnedObjectPath;

const IPAD: DisplaySpec = DisplaySpec { pixel_width: 2752, pixel_height: 2064, scale: 2, refresh_hz: 120 };

async fn conn() -> Connection {
    Connection::session().await.expect("the session bus")
}

async fn desktop(conn: &Connection, dir: &tempfile::TempDir) -> (DesktopHandle, Arc<CursorState>) {
    let cursor = CursorState::new();
    let store = Store::new(dir.path().join("arrangement.toml"));
    let handle = monitors::spawn(conn, cursor.clone(), Some(store)).await.expect("DisplayConfig");
    (handle, cursor)
}

fn non_lain(monitors: &[Monitor]) -> Vec<Monitor> {
    monitors.iter().filter(|m| !m.lain).cloned().collect()
}

fn near(a: PointF, b: PointF) -> bool {
    a.distance(b) <= 1.0
}

/// Polls `f` every 20 ms until it returns `Some`, for at most `limit`.
async fn poll<T>(limit: Duration, mut f: impl FnMut() -> Option<T>) -> Option<T> {
    let deadline = tokio::time::Instant::now() + limit;
    loop {
        if let Some(v) = f() {
            return Some(v);
        }
        if tokio::time::Instant::now() >= deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A consumer of the primary monitor's `RecordMonitor` stream at 1 frame/s that only reads its cursor
/// metadata: where the pointer is while it is on the primary monitor. (A monitor stream negotiates only its
/// monitor's size, spike B §6.)
struct HomeProbe {
    session: RemoteSession,
    consumer: Negotiation,
    cursor: Arc<CursorState>,
}

impl HomeProbe {
    async fn start(conn: &Connection, d: &DesktopHandle) -> HomeProbe {
        let primary =
            d.desktop.borrow().monitors.iter().find(|m| m.monitor.primary).cloned().expect("a primary monitor");
        let (w, h, _) = primary.mode.expect("its mode");
        let session = RemoteSession::create(conn).await.expect("a probe session");
        let path: OwnedObjectPath = session.record_monitor(&primary.spec.connector).await.expect("RecordMonitor");
        let stream = session.stream(path).await.unwrap();
        let mut added = stream.receive_signal("PipeWireStreamAdded").await.unwrap();
        session.start().await.unwrap();
        let node = tokio::time::timeout(Duration::from_secs(5), bus::next_node_id(&mut added)).await.unwrap().unwrap();
        let cursor = CursorState::new();
        cursor.set_geometry(Some(StreamGeometry { bounds: primary.monitor.bounds, scale: primary.scale }));
        let (consumer, format) = negotiate::consume_cursor(node, w as u32, h as u32, 1, cursor.clone());
        let format = tokio::time::timeout(Duration::from_secs(5), format).await.unwrap().unwrap();
        eprintln!("home probe on {}: {format:?}", primary.spec.connector);
        HomeProbe { session, consumer, cursor }
    }

    fn at(&self) -> Option<PointF> {
        self.cursor.location()
    }

    async fn stop(self) {
        self.consumer.finish().await;
        let _ = self.session.stop().await;
    }
}

/// Moves the pointer back to `home` (on the primary monitor) and checks it got there, once more if not.
async fn restore(input: &GnomeInput, home_probe: &HomeProbe, home: PointF) -> bool {
    for attempt in 1..=2 {
        input.apply(&[InputAction::MoveTo(home)]);
        let back = poll(Duration::from_secs(1), || home_probe.at().filter(|p| near(*p, home))).await;
        eprintln!("restore attempt {attempt}: {:?}", home_probe.at());
        if back.is_some() {
            return true;
        }
    }
    eprintln!("restore_failed: pointer not back at {home:?}; not moved again");
    false
}

/// Read-only: `DisplayConfig.GetCurrentState` through the desktop task, which applies nothing while lain has
/// no display. Prints the monitors.
#[tokio::test]
#[ignore = "reads the live desktop's DisplayConfig"]
async fn read_only_get_current_state_lists_the_monitors() {
    let c = conn().await;
    let dir = tempfile::tempdir().unwrap();
    let (d, _) = desktop(&c, &dir).await;
    let monitors = d.monitors.borrow().clone();
    eprintln!("{monitors:#?}");
    assert!(!monitors.is_empty());
    assert!(monitors.iter().all(|m| !m.lain));
    assert_eq!(monitors.iter().filter(|m| m.primary).count(), 1);
    // The parse agrees with a direct call.
    let proxy = bus::proxy(&c, bus::DISPLAY_CONFIG, bus::DISPLAY_CONFIG_PATH, bus::DISPLAY_CONFIG).await.unwrap();
    let raw: RawState = proxy.call("GetCurrentState", &()).await.unwrap();
    let state = parse_state(raw);
    assert_eq!(state.logical.len(), monitors.len());
    eprintln!("layout mode {:?}, serial {}", state.layout_mode, state.serial);
}

/// Read-only: Mutter's ScreenCast and RemoteDesktop versions (properties).
#[tokio::test]
#[ignore = "reads Mutter's D-Bus properties"]
async fn read_only_mutter_interfaces() {
    let c = conn().await;
    let sc = bus::proxy(&c, bus::SCREEN_CAST, bus::SCREEN_CAST_PATH, bus::SCREEN_CAST).await.unwrap();
    let rd = bus::proxy(&c, bus::REMOTE_DESKTOP, bus::REMOTE_DESKTOP_PATH, bus::REMOTE_DESKTOP).await.unwrap();
    let sc_version: i32 = sc.get_property("Version").await.unwrap();
    let rd_version: i32 = rd.get_property("Version").await.unwrap();
    let devices: u32 = rd.get_property("SupportedDeviceTypes").await.unwrap();
    eprintln!("ScreenCast {sc_version}, RemoteDesktop {rd_version}, device types {devices}");
    assert!(sc_version >= 4, "RecordVirtual's properties need ScreenCast 4 or later");
    assert_eq!(devices & 3, 3, "keyboard and pointer");
}

/// Read-only: the input settings through `gsettings get`.
#[tokio::test]
#[ignore = "runs gsettings get on the live session"]
async fn read_only_gsettings_input_settings() {
    let s = settings::read().await;
    eprintln!("{s:?}");
    assert!(s.double_click_ms > 0 && s.key_repeat_delay_ms > 0 && s.key_repeat_interval_ms > 0);
    assert!(s.input_source.contains(':'), "type:id, e.g. xkb:us");
}

async fn lain_inhibitors(c: &Connection) -> usize {
    let sm = bus::proxy(c, bus::SESSION_MANAGER, bus::SESSION_MANAGER_PATH, bus::SESSION_MANAGER).await.unwrap();
    let paths: Vec<OwnedObjectPath> = sm.call("GetInhibitors", &()).await.unwrap();
    let mut n = 0;
    for p in paths {
        let i = bus::proxy(c, bus::SESSION_MANAGER, p, "org.gnome.SessionManager.Inhibitor").await.unwrap();
        let app: String = i.call("GetAppId", &()).await.unwrap_or_default();
        let reason: String = i.call("GetReason", &()).await.unwrap_or_default();
        if app == "lain" && reason == lain_gnome::power::REASON {
            n += 1;
        }
    }
    n
}

/// One `SessionManager.Inhibit("lain", 0, "An iPad is connected", suspend | idle)`, checked in
/// `GetInhibitors`, then its `Uninhibit`. While it is held (well under a second), GNOME won't suspend or blank.
#[tokio::test]
#[ignore = "takes and releases a gnome-session inhibitor"]
async fn inhibit_and_release() {
    let c = conn().await;
    assert_eq!(lain_inhibitors(&c).await, 0, "a lain inhibitor already exists");
    let power = GnomePower::spawn(c.clone());
    power.set_awake(true);
    power.set_awake(true); // counted by the core; a repeat changes nothing
    let mut held = 0;
    for _ in 0..50 {
        held = lain_inhibitors(&c).await;
        if held > 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    power.user_activity();
    power.set_awake(false);
    let mut after = 1;
    for _ in 0..50 {
        after = lain_inhibitors(&c).await;
        if after == 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(held, 1, "one inhibitor while awake");
    assert_eq!(after, 0, "released");
}

/// Creates lain's display at 2752×2064, scale 2, 120 Hz and destroys it. On the desktop: a virtual monitor
/// `Meta-<n>` appears to the right of the layout (Mutter's placement), a short-lived PipeWire consumer fixes
/// its mode, `ApplyMonitorsConfig` method 1 sets scale 2 keeping it there, and `Stop` removes it; the other
/// monitors are checked to be as they were. No input.
#[tokio::test]
#[ignore = "creates and removes a virtual monitor on the live desktop"]
async fn desktop_create_2752x2064_scale2_120hz_and_destroy() {
    let c = conn().await;
    let dir = tempfile::tempdir().unwrap();
    let (d, cursor) = desktop(&c, &dir).await;
    let before = d.monitors.borrow().clone();
    let display = GnomeDisplay::new(c.clone(), d.clone(), cursor);
    let started = std::time::Instant::now();
    let created = display.create(IPAD).await;
    eprintln!("create took {:?}: {created:?}", started.elapsed());
    let checks = (|| {
        let (streamed, source) = created.as_ref().map_err(|e| e.to_string())?;
        let m = display.monitors().borrow().clone();
        let lain = m.iter().find(|m| m.lain).ok_or("lain's display isn't listed")?.clone();
        eprintln!(
            "streamed {streamed:?}, source node {} mapping {:?}, lain {lain:?}",
            source.node_id, source.mapping_id
        );
        if (streamed.pixel_width, streamed.pixel_height, streamed.refresh_hz) != (2752, 2064, 120) {
            return Err(format!("mode {streamed:?}"));
        }
        if streamed.id != lain.id {
            return Err("StreamedDisplay.id isn't lain's monitor id".into());
        }
        if (lain.bounds.width, lain.bounds.height) != (1376.0, 1032.0) {
            return Err(format!("not at scale 2: {:?}", lain.bounds));
        }
        if source.ended.borrow().is_some() {
            return Err("ended already".into());
        }
        Ok(source.ended.clone())
    })();
    let started = std::time::Instant::now();
    display.destroy().await;
    eprintln!("destroy took {:?}", started.elapsed());
    display.destroy().await; // idempotent
    let after = d.monitors.borrow().clone();
    let ended = checks.expect("create");
    assert_eq!(*ended.borrow(), Some(lain_gnome::DisplayEnd::Destroyed));
    assert!(after.iter().all(|m| !m.lain));
    assert_eq!(non_lain(&after), before, "the other monitors are back as they were");
}

/// The scale-2 handover (spike B exp8 with lain's sequence): `create` negotiates the mode with its own
/// consumer, leaves, and applies scale 2; then a second consumer (this test's, reading cursor metadata only,
/// for 2 s) connects to the same node with the same size and must get the same format, with no new monitor
/// and the mode unchanged. Then destroy. On the desktop: as `desktop_create_…`, plus that consumer. No input.
#[tokio::test]
#[ignore = "creates a virtual monitor and connects a second PipeWire consumer to it"]
async fn desktop_scale2_handover_to_a_second_consumer() {
    let c = conn().await;
    let dir = tempfile::tempdir().unwrap();
    let (d, cursor) = desktop(&c, &dir).await;
    let display = GnomeDisplay::new(c.clone(), d.clone(), cursor.clone());
    let (streamed, source) = display.create(IPAD).await.expect("create");
    let monitors_before = display.monitors().borrow().clone();
    let (consumer, format) = negotiate::consume_cursor(source.node_id, 2752, 2064, 120, cursor);
    let format = tokio::time::timeout(Duration::from_secs(5), format).await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    let monitors_during = display.monitors().borrow().clone();
    let mode = d.desktop.borrow().by_connector(&source.connector).and_then(|m| m.mode);
    consumer.finish().await;
    display.destroy().await;
    eprintln!("second consumer: {format:?}; mode now {mode:?}");
    let format = format.expect("in time").expect("a result").expect("a format");
    assert_eq!((format.width, format.height, format.max_framerate), (2752, 2064, (120, 1)));
    assert_eq!(monitors_during, monitors_before, "no new monitor, nothing moved");
    assert_eq!(mode.map(|(w, h, hz)| (w, h, hz.round() as u32)), Some((2752, 2064, streamed.refresh_hz)));
}

/// `monitors()` on every change: records each update while lain's display is created (it appears, then is
/// scaled to 2) and destroyed (it leaves), and checks the sequence. On the desktop: as `desktop_create_…`.
#[tokio::test]
#[ignore = "creates and removes a virtual monitor on the live desktop"]
async fn desktop_monitors_on_every_change() {
    let c = conn().await;
    let dir = tempfile::tempdir().unwrap();
    let (d, cursor) = desktop(&c, &dir).await;
    let display = GnomeDisplay::new(c.clone(), d.clone(), cursor);
    let mut rx = display.monitors();
    let before = rx.borrow_and_update().clone();
    let recorder = tokio::spawn(async move {
        let mut seen = Vec::new();
        while tokio::time::timeout(Duration::from_secs(3), rx.changed()).await.is_ok_and(|r| r.is_ok()) {
            seen.push(rx.borrow_and_update().clone());
        }
        seen
    });
    let created = display.create(IPAD).await;
    display.destroy().await;
    let seen = recorder.await.unwrap();
    for s in &seen {
        eprintln!("{s:?}");
    }
    created.expect("create");
    assert!(seen.iter().any(|m| m.iter().any(|m| m.lain && m.bounds.width == 1376.0)), "lain's display at scale 2");
    assert_eq!(non_lain(seen.last().unwrap()), before);
    assert!(seen.last().unwrap().iter().all(|m| !m.lain), "gone at the end");
}

/// A pointer move onto lain's display and back. On the desktop: lain's display as in `desktop_create_…`; a
/// consumer of the primary monitor's stream at 1 frame/s and one of lain's stream read the cursor metadata
/// only. The test waits up to 15 s for the pointer to be visible on the primary monitor and records that
/// position as home; then, checking it is still at home, it moves the pointer to the centre of lain's display
/// (one absolute motion, or three if the panel-barrier detour applies, none when no previous position is known),
/// checks it arrived, and moves it back home whatever happened (once more if it didn't get there). No
/// buttons, scrolls or keys. If the pointer isn't at home before the move, nothing is injected.
#[tokio::test]
#[ignore = "moves the pointer onto a virtual monitor and back"]
async fn desktop_input_pointer_onto_lains_display_and_back() {
    let c = conn().await;
    let dir = tempfile::tempdir().unwrap();
    let (d, cursor) = desktop(&c, &dir).await;
    let display = GnomeDisplay::new(c.clone(), d.clone(), cursor.clone());
    let input = GnomeInput::spawn(c.clone(), d.desktop.clone(), cursor.clone(), Barrier::default());
    let (_, source) = display.create(IPAD).await.expect("create");
    let (lain_consumer, _) = negotiate::consume_cursor(source.node_id, 2752, 2064, 120, cursor.clone());
    let home_probe = HomeProbe::start(&c, &d).await;
    let outcome = async {
        let Some(home) = poll(Duration::from_secs(15), || home_probe.at()).await else {
            return Err("the pointer wasn't visible on the primary monitor; nothing injected".to_owned());
        };
        eprintln!("home {home:?}");
        let lain = display.monitors().borrow().iter().find(|m| m.lain).cloned().ok_or("lain's display isn't listed")?;
        let centre = PointF::new(lain.bounds.x + lain.bounds.width / 2.0, lain.bounds.y + lain.bounds.height / 2.0);
        if !home_probe.at().is_some_and(|p| near(p, home)) {
            return Err("the pointer left home before the move; nothing injected".into());
        }
        input.apply(&[InputAction::MoveTo(centre)]);
        let arrived = poll(Duration::from_secs(2), || display.cursor_location().filter(|p| near(*p, centre))).await;
        eprintln!("moved to {centre:?}: on lain's display at {:?}", display.cursor_location());
        // Put back whatever happened: the test moved it.
        let restored = restore(&input, &home_probe, home).await;
        Ok((arrived.is_some(), restored))
    }
    .await;
    home_probe.stop().await;
    lain_consumer.finish().await;
    display.destroy().await;
    let (arrived, restored) = outcome.expect("ran");
    assert!(arrived, "the pointer reached lain's display's centre");
    assert!(restored, "the pointer is back home");
}

/// Input after `destroy`: lain's display is created, the pointer is nudged 10 logical pixels left on the
/// primary monitor and back, lain's display is destroyed, and the same nudge is repeated through the same
/// `GnomeInput` (whose session is rebuilt for the new set of monitors). On the desktop: as
/// `desktop_create_…`, plus a 1 frame/s consumer of the primary monitor's stream reading the cursor metadata.
/// Each nudge starts from where the pointer is then (it must be visible on the primary monitor, else nothing
/// more is injected) and is put back there. No buttons, scrolls or keys.
#[tokio::test]
#[ignore = "nudges the pointer on the primary monitor before and after removing a virtual monitor"]
async fn desktop_input_still_works_after_destroy() {
    let c = conn().await;
    let dir = tempfile::tempdir().unwrap();
    let (d, cursor) = desktop(&c, &dir).await;
    let display = GnomeDisplay::new(c.clone(), d.clone(), cursor.clone());
    let input = GnomeInput::spawn(c.clone(), d.desktop.clone(), cursor.clone(), Barrier::default());
    display.create(IPAD).await.expect("create");
    let home_probe = HomeProbe::start(&c, &d).await;
    let nudge = async |label: &str| -> Result<bool, String> {
        let home = home_probe.at().ok_or("the pointer isn't visible on the primary monitor; nothing injected")?;
        let primary = d.monitors.borrow().iter().find(|m| m.primary).cloned().unwrap();
        let x = if home.x - 10.0 >= primary.bounds.x { home.x - 10.0 } else { home.x + 10.0 };
        let to = PointF::new(x, home.y);
        input.apply(&[InputAction::MoveTo(to)]);
        let moved = poll(Duration::from_secs(2), || home_probe.at().filter(|p| near(*p, to))).await.is_some();
        eprintln!("{label}: nudged to {to:?}: {moved} (now {:?})", home_probe.at());
        let back = restore(&input, &home_probe, home).await;
        Ok(moved && back)
    };
    let outcome = async {
        poll(Duration::from_secs(15), || home_probe.at())
            .await
            .ok_or("the pointer wasn't visible; nothing injected")?;
        let before = nudge("with lain's display").await?;
        display.destroy().await;
        tokio::time::sleep(Duration::from_millis(500)).await;
        let after = nudge("after destroy").await?;
        Ok::<_, String>((before, after))
    }
    .await;
    home_probe.stop().await;
    display.destroy().await;
    let (before, after) = outcome.expect("ran");
    assert!(before, "input worked with lain's display");
    assert!(after, "input still works after destroy");
}
