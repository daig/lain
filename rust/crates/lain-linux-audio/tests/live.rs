//! A capture on the real PipeWire (capture only: nothing plays, no sink changes). Run with `-- --ignored`.

use std::time::{Duration, Instant};

use lain_linux_audio::PipeWireAudio;
use lain_platform::{AudioBackend, AudioFormat};

#[tokio::test(flavor = "current_thread")]
#[ignore = "needs a PipeWire session"]
async fn captures_the_default_output() {
    let t0 = Instant::now();
    let (capture, mut rx) = PipeWireAudio.start(AudioFormat::SESSION, 20).await.expect("start");
    let started = t0.elapsed();
    let first = rx.recv().await.expect("a first chunk");
    let first_latency = t0.elapsed();
    // What it's linked to (the default sink's monitor ports).
    if let Ok(out) = std::process::Command::new("pw-link").arg("-l").output() {
        let links = String::from_utf8_lossy(&out.stdout);
        let lines: Vec<&str> = links.lines().collect();
        let ours: Vec<String> = lines
            .windows(2)
            .filter(|w| w[1].contains("-> lain-audio"))
            .map(|w| format!("{} {}", w[0], w[1].trim()))
            .collect();
        eprintln!("links: {ours:#?}");
    }

    let mut chunks = vec![first];
    let window = Instant::now();
    while window.elapsed() < Duration::from_secs(1) {
        match tokio::time::timeout(Duration::from_millis(500), rx.recv()).await {
            Ok(Some(c)) => chunks.push(c),
            Ok(None) => panic!("the channel closed while capturing"),
            Err(_) => panic!("no chunk for 500 ms"),
        }
    }
    let n = chunks.len();
    let span_ms = (chunks[n - 1].capture_time_ns - chunks[0].capture_time_ns) as f64 / 1e6;
    eprintln!(
        "start {started:?}, first chunk {first_latency:?}, {n} chunks of {} bytes over {span_ms:.1} ms of capture time \
         ({:.1}/s of wall time)",
        chunks[0].samples.len(),
        (n - 1) as f64 / window.elapsed().as_secs_f64(),
    );
    assert!(chunks.iter().all(|c| c.samples.len() == 960), "20 ms of 24 kHz mono S16LE");
    assert!(chunks.windows(2).all(|w| w[1].capture_time_ns > w[0].capture_time_ns), "monotonic times");
    assert!((40..=65).contains(&n), "about 50 chunks a second, got {n}");
    let now = lain_platform::clock::now_ns();
    assert!(chunks[n - 1].capture_time_ns <= now && now - chunks[n - 1].capture_time_ns < 500_000_000);

    let dropped_at = Instant::now();
    drop(capture);
    let drop_took = dropped_at.elapsed();
    let closed = tokio::time::timeout(Duration::from_millis(200), async { while rx.recv().await.is_some() {} }).await;
    eprintln!("drop returned in {drop_took:?}; channel closed {:?} after it", dropped_at.elapsed());
    assert!(closed.is_ok(), "the channel closes within 200 ms of the drop");
    assert!(drop_took < Duration::from_millis(5), "dropping doesn't block");
}
