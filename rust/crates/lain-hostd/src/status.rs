//! The status in the log: what Swift's menu shows (`LainHostApp`'s `MenuBarExtra`), as log lines. Never a secret
//! or a PSK: only titles, the Wi-Fi port and counts, and video numbers.

use std::time::Duration;

use lain_host::HostStatus;
use lain_media::HostVideoStats;
use lain_platform::Platform;
use lain_proto::ChromaFormat;
use tokio::sync::broadcast::error::RecvError;
use tracing::{info, warn};

use crate::DaemonHandle;

/// Swift: `HostController.videoLines`. `None` unless connected; without numbers, why there's no video.
pub fn video_lines(status: &HostStatus, stats: Option<HostVideoStats>, error: Option<String>) -> Option<Vec<String>> {
    if !status.is_connected() {
        return None;
    }
    let Some(v) = stats else {
        return Some(vec![format!("No video: {}", error.as_deref().unwrap_or("starting"))]);
    };
    let ms = |x: Option<f64>| x.map_or_else(|| "–".to_owned(), |x| format!("{x:.1}"));
    let chroma = if v.chroma == Some(ChromaFormat::Yuv444) { "4:4:4 10-bit" } else { "4:2:0" };
    Some(vec![
        format!("Video {}×{} {chroma}", v.pixel_width, v.pixel_height),
        format!(
            "{:.1} Mb/s, {} sent, {} keyframes, {} refinements",
            v.bytes_per_second * 8.0 / 1e6,
            v.sent,
            v.keyframes,
            v.refinements
        ),
        format!(
            "Encode p50 {} / p95 {} ms, ack RTT p50 {} ms",
            ms(v.encode_ms_p50),
            ms(v.encode_ms_p95),
            ms(v.ack_rtt_ms_p50)
        ),
        format!("Dropped before encode {}, in flight {} (peak {})", v.dropped_before_encode, v.in_flight, v.peak_in_flight),
    ])
}

/// Logs every status change (its title), every Wi-Fi status change, the video error and the peer's version note
/// when they change (checked every `poll`), and the video lines every `video_every` while connected.
pub(crate) async fn log_status<P: Platform>(handle: DaemonHandle<P>, poll: Duration, video_every: Duration) {
    let mut statuses = handle.status_changes();
    let mut wifi = handle.wifi_status();
    info!("{}", handle.status().title());
    info!("{}", wifi.borrow_and_update().title());
    let mut checks = tokio::time::interval(poll);
    let mut video = tokio::time::interval(video_every);
    video.tick().await;
    let (mut error, mut note) = (None, None);
    let mut wifi_open = true;
    loop {
        tokio::select! {
            status = statuses.recv() => match status {
                Ok(status) => info!("{}", status.title()),
                Err(RecvError::Lagged(n)) => warn!("{n} status changes not logged"),
                Err(RecvError::Closed) => break,
            },
            changed = wifi.changed(), if wifi_open => match changed {
                Ok(()) => info!("{}", wifi.borrow_and_update().title()),
                Err(_) => wifi_open = false,
            },
            _ = checks.tick() => {
                let now = handle.video_error();
                if now != error {
                    match &now {
                        Some(why) => warn!("no video: {why}"),
                        None if error.is_some() => info!("video: the latest session has no error"),
                        None => {}
                    }
                    error = now;
                }
                let now = handle.peer_version_note();
                if now != note {
                    if let Some(n) = &now {
                        info!("{n}");
                    }
                    note = now;
                }
            }
            _ = video.tick() => {
                if let Some(lines) = handle.video_lines() {
                    info!("{}", lines.join("; "));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn video_lines_as_swift() {
        assert_eq!(video_lines(&HostStatus::WaitingForIPad, None, None), None);
        let connected = HostStatus::connected_usb("iPad16,6");
        assert_eq!(video_lines(&connected, None, None), Some(vec!["No video: starting".to_owned()]));
        assert_eq!(
            video_lines(&connected, None, Some("no GPU".into())),
            Some(vec!["No video: no GPU".to_owned()])
        );
        let stats = HostVideoStats {
            chroma: Some(ChromaFormat::Yuv420),
            pixel_width: 2752,
            pixel_height: 2064,
            sent: 120,
            keyframes: 2,
            refinements: 1,
            bytes_per_second: 7_500_000.0,
            encode_ms_p50: Some(7.94),
            encode_ms_p95: Some(8.6),
            ack_rtt_ms_p50: None,
            dropped_before_encode: 3,
            in_flight: 1,
            peak_in_flight: 2,
            ..HostVideoStats::default()
        };
        assert_eq!(
            video_lines(&connected, Some(stats), None).unwrap(),
            [
                "Video 2752×2064 4:2:0",
                "60.0 Mb/s, 120 sent, 2 keyframes, 1 refinements",
                "Encode p50 7.9 / p95 8.6 ms, ack RTT p50 – ms",
                "Dropped before encode 3, in flight 1 (peak 2)",
            ]
        );
    }
}
