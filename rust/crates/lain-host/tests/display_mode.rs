//! Protocol v8 display modes (`Hello.desiredDisplayMode`), instant restore on client quit
//! (`ReleaseAll(.disconnect)`), "Return to Host Display" + pause/resume connections, and power continuity
//! across `DisplayKeeper`.

mod common;

use std::time::Duration;

use common::*;
use lain_host::HostStatus;
use lain_platform::DisplayBackend;
use lain_proto::*;

const KEEP: Duration = Duration::from_secs(30);

fn rig(keep: Duration) -> (WifiRig, Vec<u8>) {
    let secret = secret();
    let config = lain_host::HostConfig { display_keep_alive: keep, ..wifi_config() };
    (WifiRig::new(vec![(SERIAL.to_owned(), secret.clone())], config), secret)
}

#[tokio::test]
async fn primary_mode_hides_physical_displays_and_restores_on_stop() {
    let (rig, secret) = rig(Duration::ZERO);
    let hello = Hello { desired_display_mode: DisplayMode::Primary, ..wifi_hello() };
    let ipad = rig.connect(&secret, hello).await;
    let ack = ipad.hello_ack().expect("HelloAck");
    assert_eq!(ack.display_mode, DisplayMode::Primary);
    assert_eq!(rig.session.display_mode(), Some(lain_platform::DisplayMode::Primary));
    assert!(rig.platform.display.has_hidden_host_displays());
    assert!(rig.session.can_restore_host_display());

    rig.session.stop().await;
    assert!(!rig.platform.display.has_hidden_host_displays());
    assert_eq!(rig.platform.display.live(), 0);
}

#[tokio::test]
async fn capture_existing_streams_physical_display_and_skips_keeper() {
    let (rig, secret) = rig(KEEP);
    let hello = Hello { desired_display_mode: DisplayMode::CaptureExisting, ..wifi_hello() };
    let ipad = rig.connect(&secret, hello).await;
    let ack = ipad.hello_ack().expect("HelloAck");
    assert_eq!(ack.display_mode, DisplayMode::CaptureExisting);
    assert_eq!((ack.display_point_width, ack.display_point_height), (1920, 1080));
    assert_eq!(ack.display_scale, 100);
    assert_eq!(ack.display_scales, [100, 125, 150, 175, 200, 225, 250, 275, 300]);
    // Physical monitor is 60 Hz: encoder frame rate is capped to it.
    assert_eq!(rig.platform.video().last_session().unwrap().config().frame_rate, 60);

    // Disconnecting doesn't keep an existing physical display in DisplayKeeper.
    ipad.link.close();
    assert!(eventually(T, || !rig.session.status().is_connected()).await);
    assert!(!rig.session.has_kept_display());
    assert!(eventually(T, || !rig.platform.power().is_awake()).await, "power released without kept display");
}

#[tokio::test]
async fn capture_existing_on_headless_host_falls_back_to_extend() {
    let (rig, secret) = rig(Duration::ZERO);
    rig.platform.display.fake.set_physical(Vec::new());
    let hello = Hello { desired_display_mode: DisplayMode::CaptureExisting, ..wifi_hello() };
    let ipad = rig.connect(&secret, hello).await;
    let ack = ipad.hello_ack().expect("HelloAck");
    assert_eq!(ack.display_mode, DisplayMode::Extend);
    rig.session.stop().await;
}

#[tokio::test(start_paused = true)]
async fn switching_display_mode_replaces_kept_display() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, Hello { desired_display_mode: DisplayMode::Primary, ..wifi_hello() }).await;
    assert_eq!(ipad.hello_ack().unwrap().display_mode, DisplayMode::Primary);
    ipad.link.close();
    assert!(eventually(T, || !rig.session.status().is_connected() && rig.session.has_kept_display()).await);
    assert_eq!(rig.platform.display.created(), 1);

    // Reconnecting in Extend mode must not reuse the Primary kept display.
    let back = rig.connect(&secret, Hello { desired_display_mode: DisplayMode::Extend, ..wifi_hello() }).await;
    assert_eq!(back.hello_ack().unwrap().display_mode, DisplayMode::Extend);
    assert_eq!(rig.platform.display.created(), 2);
    assert!(!rig.platform.display.has_hidden_host_displays());
    rig.session.stop().await;
}

#[tokio::test(start_paused = true)]
async fn client_quit_release_all_disconnect_skips_keeper_and_restores_immediately() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, Hello { desired_display_mode: DisplayMode::Primary, ..wifi_hello() }).await;
    assert_eq!(ipad.hello_ack().unwrap().display_mode, DisplayMode::Primary);
    assert!(rig.platform.display.has_hidden_host_displays());

    ipad.link.send(Message::ReleaseAll(ReleaseAll { reason: ReleaseReason::Disconnect }));
    assert!(eventually(T, || rig.platform.display.live() == 0).await, "display removed immediately, skipping keeper");
    assert!(!rig.session.has_kept_display());
    assert!(!rig.platform.display.has_hidden_host_displays());
    assert!(eventually(T, || !rig.platform.power().is_awake()).await, "power released immediately on quit");
}

#[tokio::test(start_paused = true)]
async fn restore_host_display_pauses_reconnects_until_resumed() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, Hello { desired_display_mode: DisplayMode::Primary, ..wifi_hello() }).await;
    assert_eq!(ipad.hello_ack().unwrap().display_mode, DisplayMode::Primary);

    rig.session.restore_host_display().await;
    assert_eq!(rig.session.status(), HostStatus::Paused);
    assert!(rig.session.is_paused());
    assert!(!rig.session.has_kept_display());
    assert!(!rig.platform.display.has_hidden_host_displays());
    assert_eq!(rig.platform.display.live(), 0);
    assert!(eventually(T, || !rig.platform.power().is_awake()).await);

    // While paused, incoming Wi-Fi links are refused as busy.
    let refused = rig.connect(&secret, wifi_hello()).await;
    assert!(refused.is_busy("paused on the host"));

    // After resuming, connections work again.
    rig.session.resume_connections();
    assert!(!rig.session.is_paused());
    assert_eq!(rig.session.status(), HostStatus::WaitingForIPad);
    let back = rig.connect(&secret, wifi_hello()).await;
    assert!(back.hello_ack().is_some());
    rig.session.stop().await;
}

#[tokio::test(start_paused = true)]
async fn power_stays_held_during_keep_alive_and_drops_on_expiry() {
    let (rig, secret) = rig(KEEP);
    let ipad = rig.connect(&secret, wifi_hello()).await;
    assert!(ipad.hello_ack().is_some());
    assert_eq!(rig.platform.power().transitions(), vec![true]);

    // Disconnect: bridge + keeper hold power without dropping to false in between.
    ipad.link.close();
    assert!(eventually(T, || !rig.session.status().is_connected() && rig.session.has_kept_display()).await);
    assert_eq!(rig.platform.power().transitions(), vec![true], "no gap in power assertion");

    // Expiry releases both the display and the power assertion.
    tokio::time::sleep(KEEP + Duration::from_secs(1)).await;
    assert!(eventually(T, || rig.platform.display.live() == 0 && !rig.platform.power().is_awake()).await);
    assert_eq!(rig.platform.power().transitions(), vec![true, false]);
}
