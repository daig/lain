//! Desktop tests on lain's virtual display: **the lead's, run with the developer told; agents never run them.**
//! Every one is `#[ignore]`d. Each creates lain's display through `lain-gnome` (2752×2064, scale 2, 120 Hz:
//! `RecordVirtual`, a negotiating PipeWire consumer, `ApplyMonitorsConfig` method 1 for the scale), captures its
//! node with `lain-linux-video`, and always destroys the display at the end, also on failure. Run one at a time,
//! through the GPU wrapper (Mesa pinned, NVIDIA fenced off, the machine-wide lock), from `rust/`:
//!
//! ```text
//! cargo test -p lain-linux-video --test live --no-run
//! TIMEOUT=60 scripts/gpu-run.sh live-video cargo test -p lain-linux-video --test live -- --ignored --exact \
//!     --test-threads=1 --nocapture <name>
//! ```
//!
//! - `desktop_capture_10s_full`: animates lain's display with `spikes/linux-display/gtkprobe.py <connector> 12
//!   full` (a fullscreen GTK window on lain's display, changing every pixel each frame; no input is sent), captures
//!   and encodes for 10 s with the core's request pattern, and prints the frame rate, the drop rate and capture →
//!   AU. It also reports whether the cursor metadata reached `CursorState` (move the pointer onto lain's display
//!   during the run to see it; set `LAIN_EXPECT_CURSOR=1` to make that an assertion).
//! - `desktop_forced_idr_from_live_capture`: 3 s of the same with a keyframe requested at frame 120; writes the
//!   stream from that IDR on to `rust/target/lain-video-live/live-idr.h265` for
//!   `spikes/linux-convert/e2e/decode-check.py` (under `spikes/linux-encoder/fence.sh`).
//! - `desktop_end_reasons`: three sessions on the live node whose `ended` watch the test drives: `StoppedByUser`
//!   and `Failed` end the session with that event; `Destroyed` stops capture and reports nothing. (The sharing
//!   indicator's real Stop stays on the supervised list.)
//! - `desktop_input_cursor_metadata_through_capture`: **moves the pointer**, so only with the developer off the
//!   mouse and the pointer showing (GNOME hides it while they type, and the test then injects nothing). The cursor
//!   metadata through this crate's own consumer while the core's request pattern runs: the pointer goes from the
//!   primary monitor to the centre of lain's display, makes eight small moves there, and goes back. Writes the
//!   cursor image to `rust/target/lain-video-live/cursor.pam`. Input rules as `lain-gnome`'s live tests (the
//!   wave-1 lesson): the pointer's position is checked before every injected action and put back where it was;
//!   no buttons, scrolls or keys.
//!
//! No NVIDIA node is opened: `gpu-run.sh`'s guard fails and reports any attempt.

use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use lain_gnome::arrangement::Store;
use lain_gnome::bus::{self, RemoteSession};
use lain_gnome::monitors::DesktopHandle;
use lain_gnome::negotiate::{self, Negotiation};
use lain_gnome::{
    Barrier, CursorState, DisplayEnd, GnomeCursor, GnomeDisplay, GnomeInput, GnomeSource, StreamGeometry, monitors,
};
use lain_linux_video::{LinuxVideo, LinuxVideoConfig};
use lain_platform::{
    CursorImage, CursorSource, DisplayBackend, DisplaySpec, EncodeConfig, EncodeRequest, InputAction, InputBackend,
    PointF, VideoBackend, VideoEvent, VideoSession,
};
use tokio::sync::{mpsc, watch};

const IPAD: DisplaySpec =
    DisplaySpec { pixel_width: 2752, pixel_height: 2064, scale: 2, desired_scale: 0, refresh_hz: 120 };

fn encode_config() -> EncodeConfig {
    EncodeConfig {
        width: 2752,
        height: 2064,
        frame_rate: 120,
        bitrate: 60_000_000,
        chroma: lain_platform::Chroma::Yuv420,
        bit_depth: 8,
    }
}

/// The desktop a test body runs on: the session bus, and `lain-gnome`'s view of the monitors (for input).
#[derive(Clone)]
struct Desk {
    conn: zbus::Connection,
    handle: DesktopHandle,
}

/// Runs `body` on lain's display, then destroys the display whatever happened: the body runs as a task of its
/// own, so that a panic in it (an assertion, an overflow) still reaches the destroy.
async fn with_display<F, Fut>(body: F)
where
    F: FnOnce(GnomeSource, Arc<CursorState>, Desk) -> Fut,
    Fut: std::future::Future<Output = Result<(), String>> + Send + 'static,
{
    let conn = zbus::Connection::session().await.expect("the session bus");
    let dir = tempfile::tempdir().unwrap();
    let cursor = CursorState::new();
    let store = Store::new(dir.path().join("arrangement.toml"));
    let desktop = monitors::spawn(&conn, cursor.clone(), Some(store)).await.expect("DisplayConfig");
    let display = GnomeDisplay::new(conn.clone(), desktop.clone(), cursor.clone());
    let desk = Desk { conn: conn.clone(), handle: desktop };
    let result = match display.create(IPAD).await {
        Ok((streamed, source)) => {
            eprintln!("lain's display {streamed:?} on {} (node {})", source.connector, source.node_id);
            tokio::spawn(body(source, cursor, desk))
                .await
                .unwrap_or_else(|e| Err(format!("the test body panicked: {e}")))
        }
        Err(e) => Err(format!("create: {e}")),
    };
    display.destroy().await;
    eprintln!("lain's display destroyed");
    result.unwrap();
}

/// gtkprobe fullscreen on `connector` for `seconds`, animating every pixel (killed on drop).
struct Probe(std::process::Child);

impl Probe {
    fn start(connector: &str, seconds: u32) -> Probe {
        let script = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../spikes/linux-display/gtkprobe.py");
        let child = std::process::Command::new("python3")
            .args([script, connector, &seconds.to_string(), "full"])
            .env("GSK_RENDERER", "gl")
            .stdout(std::process::Stdio::null())
            .spawn()
            .expect("gtkprobe");
        Probe(child)
    }
}

impl Drop for Probe {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn percentile(v: &mut [u64], q: f64) -> f64 {
    v.sort_unstable();
    if v.is_empty() { 0.0 } else { v[((v.len() - 1) as f64 * q).round() as usize] as f64 / 1e6 }
}

/// What a run of the core's request pattern saw.
#[derive(Default)]
struct Run {
    captured: u64,
    encoded: Vec<lain_platform::EncodedFrame>,
    failed: u32,
    end: Option<VideoEvent>,
}

/// The core's pattern for `duration`: one request outstanding, for each new capture; `keyframe_at` requests an
/// IDR on that request.
async fn drive(
    session: &impl VideoSession,
    events: &mut mpsc::UnboundedReceiver<VideoEvent>,
    duration: Duration,
    keyframe_at: Option<u32>,
) -> Run {
    let t0 = Instant::now();
    drive_while(session, events, || t0.elapsed() < duration, keyframe_at).await
}

/// [`drive`] for as long as `keep_going` says (checked at least every half second).
async fn drive_while(
    session: &impl VideoSession,
    events: &mut mpsc::UnboundedReceiver<VideoEvent>,
    keep_going: impl Fn() -> bool,
    keyframe_at: Option<u32>,
) -> Run {
    let mut run = Run::default();
    let (mut outstanding, mut next_id, mut newest, mut requested) = (false, 1u32, 0u64, 0u64);
    while keep_going() {
        let Ok(event) = tokio::time::timeout(Duration::from_millis(500), events.recv()).await else { continue };
        match event {
            Some(VideoEvent::Captured { capture, .. }) => {
                run.captured += 1;
                newest = capture;
            }
            Some(VideoEvent::Encoded(f)) => {
                outstanding = false;
                run.encoded.push(f);
            }
            Some(VideoEvent::EncodeFailed { .. }) => {
                outstanding = false;
                run.failed += 1;
            }
            Some(end) => {
                run.end = Some(end);
                break;
            }
            None => break,
        }
        if !outstanding && newest > requested {
            requested = newest;
            session.encode(EncodeRequest {
                frame_id: next_id,
                keyframe: keyframe_at == Some(next_id),
                refinement: false,
                bitrate: None,
            });
            next_id += 1;
            outstanding = true;
        }
    }
    run
}

#[tokio::test]
#[ignore = "desktop: creates lain's display and a fullscreen window on it (the lead runs it, with the developer told)"]
async fn desktop_capture_10s_full() {
    with_display(|source, cursor, _| async move {
        let _probe = Probe::start(&source.connector, 16); // outlasts the 2 s settle, the start and 11 s of driving
        tokio::time::sleep(Duration::from_secs(2)).await; // the window comes up fullscreen
        let video = LinuxVideo::new(LinuxVideoConfig::default());
        let (session, mut events) = video.start(&source, encode_config()).await.map_err(|e| e.to_string())?;
        // 1 s of warm-up, then 10 s measured.
        let _ = drive(&session, &mut events, Duration::from_secs(1), None).await;
        let before = session.stats();
        let run = drive(&session, &mut events, Duration::from_secs(10), None).await;
        let after = session.stats();
        let cursor_seen = cursor.location().is_some() || cursor.image().is_some();
        session.stop().await;
        let encoded_captures: HashSet<u64> = run.encoded.iter().map(|f| f.capture).collect();
        let mut latency: Vec<u64> = run.encoded.iter().map(|f| f.encode_done_ns - f.capture_ns).collect();
        let mut encode: Vec<u64> = run.encoded.iter().map(|f| f.encode_done_ns - f.submit_ns).collect();
        let bytes: usize = run.encoded.iter().map(|f| f.annexb.len()).sum();
        println!("live capture of lain's display, gtkprobe full, 10 s:");
        println!(
            "  delivered {:.1}/s, replaced before conversion {:.1}/s, captured {:.1}/s, encoded {:.1}/s, never encoded {:.1}/s, failed {}",
            (after.delivered - before.delivered) as f64 / 10.0,
            (after.replaced - before.replaced) as f64 / 10.0,
            run.captured as f64 / 10.0,
            run.encoded.len() as f64 / 10.0,
            // Saturating: a request still out at the end of the warm-up is answered in this window.
            run.captured.saturating_sub(encoded_captures.len() as u64) as f64 / 10.0,
            run.failed
        );
        println!(
            "  capture (PTS) → AU p50 {:.2} p95 {:.2} ms; encode p50 {:.2} p95 {:.2} ms; {:.1} Mbps",
            percentile(&mut latency, 0.5),
            percentile(&mut latency, 0.95),
            percentile(&mut encode, 0.5),
            percentile(&mut encode, 0.95),
            bytes as f64 * 8.0 / 10.0 / 1e6
        );
        println!("  cursor metadata reached CursorState: {cursor_seen}");
        if std::env::var_os("LAIN_EXPECT_CURSOR").is_some() && !cursor_seen {
            return Err("no cursor metadata reached CursorState".into());
        }
        if run.end.is_some() {
            return Err(format!("the session ended: {:?}", run.end));
        }
        if run.encoded.len() < 600 {
            return Err(format!("only {} pictures encoded in 10 s", run.encoded.len()));
        }
        Ok(())
    })
    .await;
}

#[tokio::test]
#[ignore = "desktop: creates lain's display and a fullscreen window on it (the lead runs it, with the developer told)"]
async fn desktop_forced_idr_from_live_capture() {
    with_display(|source, _, _| async move {
        let _probe = Probe::start(&source.connector, 8);
        tokio::time::sleep(Duration::from_secs(2)).await;
        let (session, mut events) =
            LinuxVideo::default().start(&source, encode_config()).await.map_err(|e| e.to_string())?;
        let run = drive(&session, &mut events, Duration::from_secs(3), Some(120)).await;
        session.stop().await;
        let at = run.encoded.iter().position(|f| f.frame_id == 120).ok_or("frame 120 wasn't encoded")?;
        let idr = &run.encoded[at];
        if !idr.keyframe {
            return Err("the requested frame isn't a keyframe".into());
        }
        let others = run.encoded.iter().enumerate().filter(|(i, f)| *i != at && *i != 0 && f.keyframe).count();
        let dir = std::path::PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../target/lain-video-live"));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("live-idr.h265");
        let stream: Vec<u8> = run.encoded[at..].iter().flat_map(|f| f.annexb.iter().copied()).collect();
        std::fs::write(&path, stream).unwrap();
        println!(
            "forced IDR on frame 120: {} bytes; {} other unrequested keyframes; {} pictures from it written to {}",
            idr.annexb.len(),
            others,
            run.encoded.len() - at,
            path.display()
        );
        println!(
            "decode check: spikes/linux-encoder/fence.sh python3 -I spikes/linux-convert/e2e/decode-check.py {}",
            path.display()
        );
        Ok(())
    })
    .await;
}

#[tokio::test]
#[ignore = "desktop: creates lain's display (the lead runs it, with the developer told)"]
async fn desktop_end_reasons() {
    with_display(|source, _, _| async move {
        let cases = [
            (DisplayEnd::StoppedByUser, Some(VideoEvent::StoppedByUser)),
            (DisplayEnd::Failed("test".into()), None), // a Failed event; its text is checked below
            (DisplayEnd::Destroyed, None),
        ];
        for (end, want) in cases {
            let (ended_tx, ended) = watch::channel(None);
            let driven = GnomeSource { ended, ..source.clone() };
            let (session, mut events) =
                LinuxVideo::default().start(&driven, encode_config()).await.map_err(|e| e.to_string())?;
            tokio::time::sleep(Duration::from_millis(300)).await;
            ended_tx.send_replace(Some(end.clone()));
            let mut last = None;
            let deadline = Instant::now() + Duration::from_secs(2);
            while Instant::now() < deadline {
                match tokio::time::timeout(Duration::from_millis(100), events.recv()).await {
                    Ok(Some(VideoEvent::Captured { .. })) => {}
                    Ok(Some(e)) => {
                        last = Some(e);
                        break;
                    }
                    Ok(None) => break,
                    Err(_) => {}
                }
            }
            session.stop().await;
            println!("{end:?} → {last:?}");
            match (&end, &last) {
                (DisplayEnd::StoppedByUser, l) if *l == want => {}
                (DisplayEnd::Failed(_), Some(VideoEvent::Failed(e))) if e.to_string().contains("test") => {}
                (DisplayEnd::Destroyed, None) => {}
                _ => return Err(format!("{end:?} gave {last:?}")),
            }
        }
        Ok(())
    })
    .await;
}

// --- The pointer test's helpers (as `lain-gnome`'s tests/live.rs, here through lain's own capture).

fn near(a: PointF, b: PointF) -> bool {
    a.distance(b) <= 1.0
}

/// Polls `f` every `step` until it returns `Some`, for at most `limit`.
async fn poll_every<T>(step: Duration, limit: Duration, mut f: impl FnMut() -> Option<T>) -> Option<T> {
    let deadline = Instant::now() + limit;
    loop {
        if let Some(v) = f() {
            return Some(v);
        }
        if Instant::now() >= deadline {
            return None;
        }
        tokio::time::sleep(step).await;
    }
}

async fn poll<T>(limit: Duration, f: impl FnMut() -> Option<T>) -> Option<T> {
    poll_every(Duration::from_millis(20), limit, f).await
}

/// The pointer is seen at `p` and is still there `wait` later: nobody is moving the mouse.
async fn still_at(seen: impl Fn() -> Option<PointF>, p: PointF, wait: Duration) -> bool {
    if !seen().is_some_and(|q| near(q, p)) {
        return false;
    }
    tokio::time::sleep(wait).await;
    seen().is_some_and(|q| near(q, p))
}

/// A consumer of the primary monitor's `RecordMonitor` stream at the monitor's refresh rate that only reads its
/// cursor metadata (it maps no buffers): where the pointer is while it is on the primary monitor, at most a
/// frame old.
struct HomeProbe {
    session: RemoteSession,
    consumer: Negotiation,
    cursor: Arc<CursorState>,
}

impl HomeProbe {
    async fn start(desk: &Desk) -> Result<HomeProbe, String> {
        let primary = desk.handle.desktop.borrow().monitors.iter().find(|m| m.monitor.primary).cloned();
        let primary = primary.ok_or("no primary monitor")?;
        let (w, h, hz) = primary.mode.ok_or("the primary monitor's mode isn't known")?;
        let fps = (hz.round() as u32).max(1);
        let session = RemoteSession::create(&desk.conn).await.map_err(|e| format!("a probe session: {e}"))?;
        let started = async {
            let path = session.record_monitor(&primary.spec.connector).await.map_err(|e| e.to_string())?;
            let stream = session.stream(path).await.map_err(|e| e.to_string())?;
            let mut added = stream.receive_signal("PipeWireStreamAdded").await.map_err(|e| e.to_string())?;
            session.start().await.map_err(|e| e.to_string())?;
            let node = tokio::time::timeout(Duration::from_secs(5), bus::next_node_id(&mut added)).await;
            node.ok().flatten().ok_or_else(|| "no node in 5 s".to_owned())
        };
        let node = match started.await {
            Ok(node) => node,
            Err(e) => {
                let _ = session.stop().await;
                return Err(format!("the home probe's RecordMonitor of {}: {e}", primary.spec.connector));
            }
        };
        let cursor = CursorState::new();
        cursor.set_geometry(Some(StreamGeometry { bounds: primary.monitor.bounds, scale: primary.scale }));
        let (consumer, format) = negotiate::consume_cursor(node, w as u32, h as u32, fps, cursor.clone());
        let format = tokio::time::timeout(Duration::from_secs(5), format).await;
        eprintln!("home probe on {}: {format:?}", primary.spec.connector);
        Ok(HomeProbe { session, consumer, cursor })
    }

    fn at(&self) -> Option<PointF> {
        self.cursor.location()
    }

    async fn stop(self) {
        self.consumer.finish().await;
        let _ = self.session.stop().await;
    }
}

/// Moves the pointer back to `home` (on the primary monitor), undoing the test's own moves, and checks it got
/// there. A second attempt is made only if the pointer is seen exactly where it was before the first one (so
/// nobody moved it meanwhile); otherwise nothing more is injected and the failure is reported.
async fn restore(input: &GnomeInput, home_probe: &HomeProbe, lain: &CursorState, home: PointF) -> bool {
    let seen = || home_probe.at().or_else(|| lain.location());
    let mut before = seen();
    for attempt in 1..=2 {
        if attempt == 2 {
            let now = seen();
            if !(now.is_some() && before.is_some_and(|b| now.is_some_and(|n| near(n, b)))) {
                eprintln!("restore_failed: pointer at {now:?} (was {before:?}): it moved meanwhile; not moved again");
                return false;
            }
            before = now;
        }
        input.apply(&[InputAction::MoveTo(home)]);
        let back = poll(Duration::from_secs(1), || home_probe.at().filter(|p| near(*p, home))).await;
        eprintln!("restore attempt {attempt}: {:?} (from {before:?})", home_probe.at());
        if back.is_some() {
            return true;
        }
    }
    eprintln!("restore_failed: pointer not back at {home:?}; not moved again");
    false
}

/// What [`round_trip`] saw.
struct Trip {
    home: PointF,
    centre: PointF,
    /// lain's metadata before the first move: its location, and whether there was an image.
    before: (Option<PointF>, bool),
    /// The first move (which also starts input's session) until the metadata reported the centre.
    arrival: Option<Duration>,
    image: Option<Arc<CursorImage>>,
    /// Each small move until the metadata reported it (`None`: not within a second).
    moves: Vec<Option<Duration>>,
    /// The image after the moves is the same `Arc` as at the arrival (no new bitmap: the sprite didn't change).
    same_image: bool,
    /// The home probe saw the pointer back home.
    restored: bool,
    /// After that, lain's metadata went invalid within a second.
    left: bool,
}

/// The round trip: home → lain's centre → eight moves of 60 logical pixels around it → home. Errs only when
/// nothing was injected.
async fn round_trip(
    input: &GnomeInput,
    home_probe: &HomeProbe,
    lain: &Arc<CursorState>,
    desk: &Desk,
) -> Result<Trip, String> {
    // What the host reads: `GnomeCursor` is its `CursorSource`, `CursorState::location` its `cursor_location`.
    let source = GnomeCursor::new(lain.clone());
    let home = poll(Duration::from_secs(15), || home_probe.at())
        .await
        .ok_or("the pointer wasn't visible on the primary monitor; nothing injected")?;
    let bounds = desk.handle.monitors.borrow().iter().find(|m| m.lain).map(|m| m.bounds);
    let bounds = bounds.ok_or("lain's display isn't listed; nothing injected")?;
    let centre = PointF::new(bounds.x + bounds.width / 2.0, bounds.y + bounds.height / 2.0);
    let before = (lain.location(), source.current().is_some());
    eprintln!("home {home:?}; lain's display {bounds:?}; its metadata before the move: {before:?}");
    if !still_at(|| home_probe.at(), home, Duration::from_millis(500)).await {
        return Err("the pointer isn't still at home before the move; nothing injected".into());
    }
    let started = Instant::now();
    input.apply(&[InputAction::MoveTo(centre)]);
    let reported = |to: PointF| move || lain.location().filter(|p| near(*p, to));
    let arrival =
        poll_every(Duration::from_millis(1), Duration::from_secs(2), reported(centre)).await.map(|_| started.elapsed());
    // The bitmap comes with the first valid metadata, or a buffer later.
    let image = poll(Duration::from_millis(500), || source.current()).await;
    eprintln!("moved to {centre:?}: the metadata says {:?} after {arrival:?}", lain.location());
    let mut moves = Vec::new();
    let mut at = centre;
    if arrival.is_some() {
        for i in 0..8 {
            // Only from where the last move put it, and only if it stays there: nobody took the mouse.
            if !still_at(|| lain.location(), at, Duration::from_millis(100)).await {
                eprintln!("move {i}: the pointer isn't where the last move put it ({:?}); no more", lain.location());
                break;
            }
            let angle = f64::from(i) * std::f64::consts::FRAC_PI_4;
            let to = PointF::new((centre.x + 60.0 * angle.cos()).round(), (centre.y + 60.0 * angle.sin()).round());
            let started = Instant::now();
            input.apply(&[InputAction::MoveTo(to)]);
            let seen = poll_every(Duration::from_millis(1), Duration::from_secs(1), reported(to)).await;
            moves.push(seen.map(|_| started.elapsed()));
            if seen.is_none() {
                eprintln!("move {i} to {to:?}: the metadata says {:?}; no more", lain.location());
                break;
            }
            at = to;
        }
    }
    let same_image = matches!((&image, source.current()), (Some(a), Some(b)) if Arc::ptr_eq(a, &b));
    // Put back whatever happened: the test moved it.
    let restored = restore(input, home_probe, lain, home).await;
    let left = poll(Duration::from_secs(1), || lain.location().is_none().then_some(())).await.is_some();
    Ok(Trip { home, centre, before, arrival, image, moves, same_image, restored, left })
}

/// A cursor image as the host sends it: at lain's scale, its hotspot inside it, premultiplied BGRA with
/// something opaque and something clear. The `Ok` describes it.
fn check_image(img: &CursorImage) -> Result<String, String> {
    let (w, h) = (usize::from(img.pixel_width), usize::from(img.pixel_height));
    let px = img.pixels.as_chunks::<4>().0;
    let opaque = px.iter().filter(|p| p[3] == 255).count();
    let clear = px.iter().filter(|p| p[3] == 0).count();
    let unpremultiplied = px.iter().filter(|p| p[0] > p[3] || p[1] > p[3] || p[2] > p[3]).count();
    let s = f32::from(img.scale.max(1));
    let hotspot_inside = (0.0..w as f32 / s).contains(&img.hotspot_x) && (0.0..h as f32 / s).contains(&img.hotspot_y);
    let summary = format!(
        "{w}×{h} pixels at scale {}, hotspot ({}, {}) points, {opaque} opaque, {clear} clear, {unpremultiplied} not \
         premultiplied",
        img.scale, img.hotspot_x, img.hotspot_y
    );
    if img.scale != 2 || !hotspot_inside || unpremultiplied > 0 || opaque == 0 || clear == 0 {
        return Err(format!("an unlikely cursor image: {summary}"));
    }
    Ok(summary)
}

/// Writes `img` as a PAM (straight RGBA, as viewers expect) to `rust/target/lain-video-live/cursor.pam`.
fn write_pam(img: &CursorImage) -> std::path::PathBuf {
    let dir = std::path::PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../../target/lain-video-live"));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("cursor.pam");
    let header = format!(
        "P7\nWIDTH {}\nHEIGHT {}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n",
        img.pixel_width, img.pixel_height
    );
    let mut bytes = header.into_bytes();
    for p in img.pixels.as_chunks::<4>().0 {
        let unmultiply = |c: u8| if p[3] == 0 { 0 } else { (u32::from(c) * 255 / u32::from(p[3])).min(255) as u8 };
        bytes.extend_from_slice(&[unmultiply(p[2]), unmultiply(p[1]), unmultiply(p[0]), p[3]]);
    }
    std::fs::write(&path, bytes).unwrap();
    path
}

/// The cursor metadata through this crate's own consumer, the pointer moved onto lain's display and back. On the
/// desktop: lain's display as in the other tests (nothing on it but the background), captured and encoded with
/// the core's request pattern; a consumer of the primary monitor's stream at its refresh rate that reads only its
/// cursor metadata (where the pointer is while it is there). The test waits up to 15 s for the pointer to be
/// visible on the primary monitor and records that position as home; lain's metadata must know nothing then.
/// Once the pointer has stayed at home for half a second, it moves it to the centre of lain's display (one
/// absolute motion) and waits for the metadata to report it there, with an image at scale 2. Then come eight
/// moves of about 60 logical pixels around the centre, each made only once the pointer is seen still where the
/// last one put it. Nothing on lain's display changes, so these are cursor-only updates, and each is timed until
/// the metadata reports it. Then the pointer goes back home whatever happened (once more only if it is seen
/// unmoved since), and the metadata must go invalid. No buttons, scrolls or keys. If the pointer isn't still at
/// home before the first move, nothing is injected.
#[tokio::test]
#[ignore = "desktop: moves the pointer onto lain's display and back (the lead runs it, the developer off the mouse)"]
async fn desktop_input_cursor_metadata_through_capture() {
    with_display(|source, cursor, desk| async move {
        let input =
            GnomeInput::spawn(desk.conn.clone(), desk.handle.desktop.clone(), cursor.clone(), Barrier::default());
        let (session, mut events) =
            LinuxVideo::default().start(&source, encode_config()).await.map_err(|e| e.to_string())?;
        let home_probe = match HomeProbe::start(&desk).await {
            Ok(probe) => probe,
            Err(e) => {
                session.stop().await;
                return Err(e);
            }
        };
        let done = AtomicBool::new(false);
        let (run, trip) =
            tokio::join!(drive_while(&session, &mut events, || !done.load(Ordering::Acquire), None), async {
                let trip = round_trip(&input, &home_probe, &cursor, &desk).await;
                done.store(true, Ordering::Release);
                trip
            });
        let stats = session.stats();
        session.stop().await;
        home_probe.stop().await;
        let trip = trip?;
        let ms = |d: &Option<Duration>| d.map_or("-".to_owned(), |d| format!("{:.1}", d.as_secs_f64() * 1e3));
        println!("the cursor metadata through lain-linux-video's capture:");
        println!("  home {:?}; lain's centre {:?}; before the move: {:?}", trip.home, trip.centre, trip.before);
        println!("  first move → reported: {} ms (includes starting input's session)", ms(&trip.arrival));
        let moves: Vec<String> = trip.moves.iter().map(ms).collect();
        println!("  small moves → reported (ms): {}", moves.join(" "));
        let mut times: Vec<u64> = trip.moves.iter().flatten().map(|d| d.as_nanos() as u64).collect();
        println!("    p50 {:.1}, max {:.1} ms", percentile(&mut times, 0.5), percentile(&mut times, 1.0));
        println!(
            "  same image after the moves: {}; back home: {}; metadata invalid after: {}",
            trip.same_image, trip.restored, trip.left
        );
        println!(
            "  video meanwhile: {} captured, {} encoded, {} failed, end {:?}; stats {stats:?}",
            run.captured,
            run.encoded.len(),
            run.failed,
            run.end
        );
        let mut failures = Vec::new();
        match &trip.image {
            Some(img) => {
                let path = write_pam(img);
                match check_image(img) {
                    Ok(summary) => println!("  image: {summary}; written to {}", path.display()),
                    Err(e) => failures.push(format!("{e} (written to {})", path.display())),
                }
            }
            None => failures.push("no cursor image while the pointer was on lain's display".to_owned()),
        }
        if trip.before != (None, false) {
            failures.push(format!("lain's metadata knew a pointer before it was there: {:?}", trip.before));
        }
        if trip.arrival.is_none() {
            failures.push("the metadata never reported the pointer at lain's centre".into());
        }
        if trip.arrival.is_some() && (trip.moves.len() < 8 || trip.moves.iter().any(Option::is_none)) {
            failures.push(format!("{} of 8 small moves reported", trip.moves.iter().flatten().count()));
        }
        if !trip.same_image {
            failures.push("the image changed during the small moves".into());
        }
        if !trip.left {
            failures.push(format!("the metadata still says {:?} after the pointer left", cursor.location()));
        }
        if !trip.restored {
            failures.push("the pointer isn't back home".into());
        }
        if run.end.is_some() || run.failed > 0 {
            failures.push(format!("the video session: end {:?}, {} failed", run.end, run.failed));
        }
        if failures.is_empty() { Ok(()) } else { Err(failures.join("; ")) }
    })
    .await;
}
