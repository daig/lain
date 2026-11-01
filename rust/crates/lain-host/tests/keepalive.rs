//! The display keep-alive (`HostConfig::display_keep_alive`, `keeper.rs`): lain's display outlives a session
//! whose link went away, and the next session of the same size takes it back. Asked for at the bring-up
//! (2026-11-01), when switching apps on the iPad rebuilt the display every time.

mod common;

use std::time::Duration;

use common::*;
use lain_platform::PlatformError;

const KEEP: Duration = Duration::from_secs(30);

fn rig(keep: Duration) -> (WifiRig, Vec<u8>) {
    let secret = secret();
    let config = lain_host::HostConfig { display_keep_alive: keep, ..wifi_config() };
    (WifiRig::new(vec![(SERIAL.to_owned(), secret.clone())], config), secret)
}

/// The iPad's app leaving the screen: its link closes. The display stays, without video.
async fn leave(rig: &WifiRig, ipad: WifiIPad) {
    ipad.link.close();
    assert!(eventually(T, || rig.platform.power().transitions().last() == Some(&false)).await, "power released");
}

#[tokio::test(start_paused = true)]
async fn an_app_switch_gets_the_same_display_back() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    assert!(ipad.hello_ack().is_some());
    let display = &rig.platform.display;
    assert_eq!((display.created(), display.live()), (1, 1));
    leave(&rig, ipad).await;
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert_eq!(display.live(), 1, "kept while the iPad is away");
    let sessions = rig.platform.video().sessions().len();
    let back = rig.connect(&secret, wifi_hello()).await;
    assert!(back.hello_ack().is_some());
    assert_eq!((display.created(), display.live(), display.peak()), (1, 1, 1), "the same display, never two");
    assert_eq!(rig.platform.video().sessions().len(), sessions + 1, "video restarted on it");
    rig.session.stop().await;
    assert_eq!(display.live(), 0);
}

#[tokio::test(start_paused = true)]
async fn a_kept_display_is_removed_when_the_ipad_stays_away() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    leave(&rig, ipad).await;
    tokio::time::sleep(KEEP - Duration::from_secs(1)).await;
    assert_eq!(rig.platform.display.live(), 1);
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(rig.platform.display.live(), 0, "removed once the keep-alive ran out");
    // The next session makes a new one.
    let back = rig.connect(&secret, wifi_hello()).await;
    assert!(back.hello_ack().is_some());
    assert_eq!((rig.platform.display.created(), rig.platform.display.live()), (2, 1));
}

#[tokio::test(start_paused = true)]
async fn another_size_gets_a_new_display() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    leave(&rig, ipad).await;
    let other = lain_proto::Hello { pixel_width: 2420, pixel_height: 1668, ..wifi_hello() };
    let back = rig.connect(&secret, other).await;
    assert!(back.hello_ack().is_some());
    let display = &rig.platform.display;
    assert_eq!((display.created(), display.live(), display.peak()), (2, 1, 1), "the kept one went first");
}

#[tokio::test(start_paused = true)]
async fn stopping_removes_a_kept_display() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    leave(&rig, ipad).await;
    assert_eq!(rig.platform.display.live(), 1);
    rig.session.stop().await;
    assert_eq!(rig.platform.display.live(), 0, "stop waits for the kept display's removal");
}

#[tokio::test(start_paused = true)]
async fn dropping_the_session_removes_a_kept_display() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    leave(&rig, ipad).await;
    let platform = rig.platform.clone();
    drop(rig.session);
    assert!(eventually(T, || platform.display.live() == 0).await);
}

#[tokio::test(start_paused = true)]
async fn capture_stopped_on_the_desktop_takes_the_display_with_it() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    assert!(ipad.hello_ack().is_some());
    rig.platform.video().last_session().unwrap().stop_by_user();
    assert!(eventually(T, || rig.platform.display.live() == 0).await, "not kept: the owner stopped it");
}

#[tokio::test(start_paused = true)]
async fn a_kept_display_that_no_longer_captures_is_replaced() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    leave(&rig, ipad).await;
    // Stopped on the desktop while kept: capture on it fails, so a new display is made.
    rig.platform.video().fail_next_start(PlatformError::Failed("the node is gone".into()));
    let back = rig.connect(&secret, wifi_hello()).await;
    assert!(back.hello_ack().is_some());
    let display = &rig.platform.display;
    assert_eq!((display.created(), display.live(), display.peak()), (2, 1, 1));
    assert!(rig.session.video_error().is_none(), "video runs on the new display");
}

#[tokio::test(start_paused = true)]
async fn no_keep_alive_removes_the_display_at_once() {
    let (rig, secret) = rig(Duration::ZERO);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    ipad.link.close();
    assert!(eventually(T, || rig.platform.display.live() == 0).await);
}
