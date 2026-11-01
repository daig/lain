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
//!
//! No NVIDIA node is opened: `gpu-run.sh`'s guard fails and reports any attempt.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, Instant};

use lain_gnome::arrangement::Store;
use lain_gnome::{CursorState, DisplayEnd, GnomeDisplay, GnomeSource, monitors};
use lain_linux_video::{LinuxVideo, LinuxVideoConfig};
use lain_platform::{DisplayBackend, DisplaySpec, EncodeConfig, EncodeRequest, VideoBackend, VideoEvent, VideoSession};
use tokio::sync::{mpsc, watch};

const IPAD: DisplaySpec = DisplaySpec { pixel_width: 2752, pixel_height: 2064, scale: 2, refresh_hz: 120 };

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

/// Runs `body` on lain's display, then destroys the display whatever happened.
async fn with_display<F, Fut>(body: F)
where
    F: FnOnce(GnomeSource, Arc<CursorState>) -> Fut,
    Fut: std::future::Future<Output = Result<(), String>>,
{
    let conn = zbus::Connection::session().await.expect("the session bus");
    let dir = tempfile::tempdir().unwrap();
    let cursor = CursorState::new();
    let store = Store::new(dir.path().join("arrangement.toml"));
    let desktop = monitors::spawn(&conn, cursor.clone(), Some(store)).await.expect("DisplayConfig");
    let display = GnomeDisplay::new(conn.clone(), desktop, cursor.clone());
    let result = match display.create(IPAD).await {
        Ok((streamed, source)) => {
            eprintln!("lain's display {streamed:?} on {} (node {})", source.connector, source.node_id);
            body(source, cursor).await
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
    let mut run = Run::default();
    let (mut outstanding, mut next_id, mut newest, mut requested) = (false, 1u32, 0u64, 0u64);
    let t0 = Instant::now();
    while t0.elapsed() < duration {
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
    with_display(|source, cursor| async move {
        let _probe = Probe::start(&source.connector, 13);
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
            (run.captured - encoded_captures.len() as u64) as f64 / 10.0,
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
    with_display(|source, _| async move {
        let _probe = Probe::start(&source.connector, 6);
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
    with_display(|source, _| async move {
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
