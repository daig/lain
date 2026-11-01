//! The session over the network (Swift: `Tests/LainHostCoreTests/HostSessionWiFiTests.swift`, case by case):
//! the iPad's Wi-Fi side is `lain-link`'s dialer over memory streams bound to a pairing, handed in as
//! `lain-wifi`'s listener would hand in its TLS streams; its USB side, where a test needs one, is a client-role
//! listener behind the fake usbmuxd. Tests without USB run on paused time; the others on real time (the fake
//! usbmuxd's sockets are real, loopback and Unix only).
//!
//! The listener's own tests (PSKs, refresh, retries: `anUnreadableKeychainIsRetriedWithBackoff`,
//! `aSlowKeyReadFinishingLastDoesNotPutBackTheOldKey`, the TLS refusal of an unknown identity) belong to
//! `lain-wifi`, which owns the listener here.

mod common;

use std::time::Duration;

use common::*;
use lain_host::{HostConfig, HostStatus, Tuning, WifiAdmission};
use lain_link::{BoundStream, ByteStream, ChannelAuth, LinkDialer, PairingAccounts, TransportError, VersionGap};
use lain_platform::PlatformError;
use lain_proto::*;
use lain_usbmux::fake::FakeDevice;
use tokio::io::AsyncWriteExt;

fn stored(secret: &[u8]) -> Vec<(String, Vec<u8>)> {
    vec![(SERIAL.to_owned(), secret.to_vec())]
}

fn usb_stored(secret: &[u8]) -> Vec<(String, Vec<u8>)> {
    vec![(PairingAccounts::USB_HOST.to_owned(), secret.to_vec())]
}

fn admission(usb_preference: Duration) -> HostConfig {
    HostConfig { wifi: WifiAdmission { usb_preference, ..WifiAdmission::default() }, ..wifi_config() }
}

const BUSY_USB: &str = "this iPad is on USB";

// MARK: A session over Wi-Fi

#[tokio::test(start_paused = true)]
async fn a_wifi_session_runs_like_a_usb_one() {
    let secret = secret();
    let mut rig = WifiRig::new(stored(&secret), wifi_config());
    let mut ipad = rig.connect(&secret, wifi_hello()).await;
    // HelloAck names this computer, over Wi-Fi as over USB.
    let ack = ipad.hello_ack().expect("HelloAck").clone();
    assert_eq!((ack.host_id.as_str(), ack.host_name.as_str()), (identity().id.as_str(), identity().name.as_str()));
    assert_eq!((ack.display_point_width, ack.display_point_height), (1376, 1032));
    // The layout follows it, then (v4) the setup.
    let layout = DisplayLayout {
        displays: vec![
            LayoutDisplay { display_id: 1, x: 0.0, y: 0.0, width: 1920.0, height: 1080.0, is_streamed: false },
            LayoutDisplay { display_id: 100, x: 1920.0, y: 0.0, width: 1376.0, height: 1032.0, is_streamed: true },
        ],
    };
    assert_eq!(ipad.link.next(T).await, Some(Message::DisplayLayout(layout)));
    assert_eq!(
        ipad.link.next(T).await,
        Some(Message::HostSetup(HostSetup { items: vec![], video_problem: String::new(), has_other_display: false }))
    );
    assert!(rig.statuses.reaches(&connected_via(lan()), T).await);
    assert_eq!(rig.session.status().title(), "Connected to iPad16,6 over LAN (lo)");
    assert_eq!(rig.platform.power().transitions(), [true]);

    // Input is injected; pings are answered.
    ipad.link.send(key(0x04, true));
    assert!(eventually(T, || rig.platform.input().actions() == routed(&[key(0x04, true)], false)).await);
    ipad.link.send(Message::Ping(Ping { id: 5, sent_at_ns: 77 }));
    let pong = ipad.link.first(T, |m| matches!(m, Message::Pong(p) if p.id == 5 && p.ping_sent_at_ns == 77)).await;
    assert!(pong.is_some());

    // The iPad goes away: everything is released once, the assertion dropped.
    ipad.link.close();
    let released = routed(&[key(0x04, true)], true);
    assert!(eventually(T, || rig.platform.input().actions() == released).await);
    assert!(eventually(T, || rig.platform.power().transitions() == [true, false]).await);
    assert!(rig.statuses.reaches(&HostStatus::WaitingForIPad, T).await);
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(rig.platform.input().actions(), released);
    assert_eq!(rig.platform.fake.secrets.snapshot(), stored(&secret).into_iter().collect(), "Wi-Fi never pairs");
    rig.session.stop().await;
}

// MARK: USB wins

#[tokio::test]
async fn usb_takes_over_from_a_live_wifi_session() {
    let secret = secret();
    let mut rig =
        Rig::new(RigOptions { stored: stored(&secret), usb_stored: usb_stored(&secret), devices: vec![], ..Default::default() })
            .await;
    let mut ipad = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(ipad.hello_ack().is_some());
    assert!(rig.statuses.reaches(&connected_via(lan()), T).await);
    ipad.link.send(key(0x04, true));
    assert!(eventually(T, || rig.actions().len() == routed(&[key(0x04, true)], false).len()).await);

    // The cable goes in: the same iPad over USB takes the session.
    rig.mux.attach(FakeDevice::usb(7, SERIAL));
    let mut usb = rig.usb.next_link(T).await.expect("a USB link");
    let ack = usb.hello_ack().await.expect("HelloAck over USB");
    assert_eq!((ack.host_id, ack.host_name), (identity().id, identity().name));
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    assert!(ipad.link.closed(T).await);
    // Exactly one release, before anything of the USB session; the assertion never lapsed (the USB session
    // began before the Wi-Fi one ended).
    usb.send(key(0x05, true));
    let mut expected = routed(&[key(0x04, true)], true);
    expected.extend(routed(&[key(0x05, true)], false));
    assert!(eventually(T, || rig.actions() == expected).await, "{:?}", rig.actions());
    assert_eq!(rig.awake(), [true]);
    assert_eq!(rig.status().title(), "Connected to iPad16,6 over USB");
    let _ = ipad.link.next(Duration::from_millis(1)).await;
    rig.session.stop().await;
}

#[tokio::test]
async fn a_wifi_link_while_usb_is_live_is_busy() {
    let secret = secret();
    let mut rig = Rig::new(RigOptions { stored: stored(&secret), usb_stored: usb_stored(&secret), ..Default::default() }).await;
    let _usb = rig.usb.next_link(T).await.expect("a USB link");
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);

    let ipad = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(ipad.is_busy("a USB session is live"), "{:?}", ipad.reply);
    assert!(ipad.link.closed(Duration::from_secs(3)).await, "closed after a short drain");
    // The USB session never noticed.
    assert_eq!(rig.status(), HostStatus::connected_usb("iPad16,6"));
    assert!(rig.actions().is_empty());
    assert_eq!(rig.awake(), [true]);
    rig.session.stop().await;
}

#[tokio::test]
async fn the_same_ipad_attached_over_usb_is_preferred_for_a_while() {
    let secret = secret();
    // The iPad is on the cable, but lain doesn't answer there: its USB dials keep failing.
    let rig = Rig::new(RigOptions {
        stored: stored(&secret),
        devices: vec![FakeDevice::usb(7, SERIAL).refusing()],
        config: admission(Duration::from_millis(1500)),
        ..Default::default()
    })
    .await;
    let start = tokio::time::Instant::now();
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(7)).await);
    let dialed = tokio::time::Instant::now(); // the window began between `start` and now (the attach)

    let early = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(start.elapsed() < Duration::from_millis(1200));
    assert!(early.is_busy(BUSY_USB), "{:?}", early.reply);
    assert!(early.link.closed(Duration::from_secs(3)).await);

    // Once USB has had its chance, Wi-Fi is let in.
    tokio::time::sleep_until(dialed + Duration::from_millis(1700)).await;
    let mut rig = rig;
    let late = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(late.hello_ack().is_some(), "{:?}", late.reply);
    assert!(rig.statuses.reaches(&connected_via(lan()), T).await);
    rig.session.stop().await;
}

#[tokio::test]
async fn the_window_restarts_when_the_ipads_usb_session_ends() {
    let secret = secret();
    let mut rig = Rig::new(RigOptions {
        stored: stored(&secret),
        usb_stored: usb_stored(&secret),
        config: admission(Duration::from_millis(1500)),
        ..Default::default()
    })
    .await;
    let usb = rig.usb.next_link(T).await.expect("a USB link");
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    tokio::time::sleep(Duration::from_millis(1700)).await; // long past the attach

    // lain on the iPad stops answering over USB (the session ends, redials fail) and dials over Wi-Fi at once:
    // USB just had a session, so it gets its window again.
    rig.usb.listener.cancel();
    usb.close();
    assert!(rig.statuses.reaches(&HostStatus::Connecting, T).await);
    let ended = tokio::time::Instant::now();
    let early = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(ended.elapsed() < Duration::from_millis(1200));
    assert!(early.is_busy(BUSY_USB), "{:?}", early.reply);

    tokio::time::sleep_until(ended + Duration::from_millis(1700)).await;
    let late = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(late.hello_ack().is_some(), "{:?}", late.reply);
    assert!(rig.statuses.reaches(&connected_via(lan()), T).await);
    rig.session.stop().await;
}

/// The case the window exists for: the iPad is plugged in behind a device without lain (an iPhone charging),
/// whose fast retries take about 2 s. The iPad's window counts from its attach, so it dials over Wi-Fi in vain
/// meanwhile, and its session comes up over USB with no Wi-Fi session in between.
#[tokio::test]
async fn an_ipad_waiting_behind_another_device_is_kept_for_usb() {
    let secret = secret();
    let mut rig = Rig::new(RigOptions {
        stored: stored(&secret),
        usb_stored: usb_stored(&secret),
        devices: vec![FakeDevice::usb(3, "IPHONE-3").refusing(), FakeDevice::usb(7, SERIAL)],
        ..Default::default()
    })
    .await;
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(3)).await);

    let wifi = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(wifi.is_busy(BUSY_USB), "{:?}", wifi.reply);
    assert_eq!(rig.session.usb_device_dialed(), Some(3), "still waiting its turn: the window came from its attach");

    let mut usb = rig.usb.next_link(T).await.expect("a USB link");
    assert!(usb.hello_ack().await.is_some());
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    assert_eq!(rig.awake(), [true], "no Wi-Fi session ever started");
    rig.session.stop().await;
}

/// The window restarts at the waiting iPad's first dial: however long the device ahead of it took, USB gets
/// its full window once it is the iPad's turn.
#[tokio::test]
async fn the_window_restarts_when_a_waiting_ipad_is_first_dialed() {
    let secret = secret();
    let rig = Rig::new(RigOptions {
        stored: stored(&secret),
        devices: vec![FakeDevice::usb(3, "IPHONE-3").refusing(), FakeDevice::usb(7, SERIAL).refusing()],
        // The iPhone's turn: 25 × 100 ms, well past the window from the attach.
        config: HostConfig { tuning: Tuning { fast_retries: 25, ..Tuning::default() }, ..admission(Duration::from_millis(1500)) },
        ..Default::default()
    })
    .await;
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(3)).await);
    let attached = tokio::time::Instant::now(); // usbmuxd reported both devices together
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(7)).await);
    assert!(attached.elapsed() > Duration::from_millis(1500), "the window from the attach is over");

    let ipad = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(ipad.is_busy(BUSY_USB), "{:?}", ipad.reply);
    rig.session.stop().await;
}

/// Two devices failing over USB take turns, but hand-overs back to the iPad don't restart its window: Wi-Fi
/// gets in once the window from its first dial is over, instead of being busy for good.
#[tokio::test]
async fn hand_overs_between_failing_devices_dont_keep_wifi_busy() {
    let secret = secret();
    let mut rig = Rig::new(RigOptions {
        stored: stored(&secret),
        devices: vec![FakeDevice::usb(3, "IPHONE-3").refusing(), FakeDevice::usb(7, SERIAL).refusing()],
        // A hand-over about every 0.5 s: the iPad is dialed again about every second.
        config: HostConfig { tuning: Tuning { fast_retries: 5, ..Tuning::default() }, ..admission(Duration::from_millis(1500)) },
        ..Default::default()
    })
    .await;
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(7)).await);
    let first_dial = tokio::time::Instant::now(); // its window began just before
    let early = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(early.is_busy(BUSY_USB), "{:?}", early.reply);

    // The iPhone's turn, then the iPad's again...
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(3)).await);
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(7)).await);
    // ...and the window from its first dial runs out all the same.
    tokio::time::sleep_until(first_dial + Duration::from_millis(1700)).await;
    let late = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(late.hello_ack().is_some(), "{:?}", late.reply);
    assert!(rig.statuses.reaches(&connected_via(lan()), T).await);
    rig.session.stop().await;
}

// MARK: Wi-Fi over Wi-Fi

#[tokio::test(start_paused = true)]
async fn a_new_wifi_link_from_the_same_ipad_replaces_its_session() {
    let secret = secret();
    let rig = WifiRig::new(stored(&secret), wifi_config());
    let first = rig.connect(&secret, wifi_hello()).await;
    assert!(first.hello_ack().is_some());
    first.link.send(key(0x04, true));
    assert!(eventually(T, || !rig.platform.input().actions().is_empty()).await);

    // The iPad redials (it thinks the first link is gone): the new link takes over.
    let second = rig.connect(&secret, hello()).await;
    assert!(second.hello_ack().is_some(), "{:?}", second.reply);
    assert!(first.link.closed(T).await);
    // The assertion never lapsed: the new session began before the old one ended.
    assert_eq!(rig.platform.power().transitions(), [true]);
    second.link.send(key(0x04, false));
    let mut expected = routed(&[key(0x04, true)], true);
    expected.extend(routed(&[key(0x04, false)], false)); // an orphan release: nothing
    assert!(eventually(T, || rig.platform.input().actions() == expected).await);
    second.link.send(key(0x05, true));
    expected.extend(routed(&[key(0x05, true)], false));
    assert!(eventually(T, || rig.platform.input().actions() == expected).await);
    assert_eq!(rig.session.status(), connected_via(lan()));
    rig.session.stop().await;
}

#[tokio::test(start_paused = true)]
async fn another_ipad_over_wifi_is_busy() {
    let (one, two) = (secret(), secret());
    let mut rig = WifiRig::new(vec![(SERIAL.into(), one.clone()), ("IPAD-8".into(), two.clone())], wifi_config());
    let first = rig.connect(&one, wifi_hello()).await;
    assert!(first.hello_ack().is_some());
    assert!(rig.statuses.reaches(&connected_via(lan()), T).await);

    let second = rig.connect(&two, wifi_hello()).await;
    assert!(second.is_busy("another iPad is connected"), "{:?}", second.reply);
    assert!(second.link.closed(Duration::from_secs(3)).await);
    // The first goes on untouched.
    first.link.send(key(0x04, true));
    assert!(eventually(T, || rig.platform.input().actions() == routed(&[key(0x04, true)], false)).await);
    assert!(!first.link.closed(Duration::from_millis(200)).await);
    assert_eq!(rig.platform.power().transitions(), [true]);
    rig.session.stop().await;
}

// MARK: Other USB devices

/// Nothing reached the live Wi-Fi session: the same status with nothing new published, its link open, nothing
/// released, the assertion held throughout, and input still flowing.
async fn expect_untouched(rig: &mut Rig, ipad: &WifiIPad, status: &HostStatus) {
    assert_eq!(&rig.status(), status);
    assert_eq!(rig.statuses.next(Duration::from_millis(100)).await, None);
    assert!(!ipad.link.closed(Duration::from_millis(100)).await);
    assert!(rig.actions().is_empty());
    assert_eq!(rig.awake(), [true]);
    ipad.link.send(key(0x04, true));
    assert!(eventually(T, || rig.actions() == routed(&[key(0x04, true)], false)).await);
}

#[tokio::test]
async fn an_iphone_coming_and_going_leaves_the_wifi_session_up() {
    let secret = secret();
    let mut rig = Rig::new(RigOptions { stored: stored(&secret), devices: vec![], ..Default::default() }).await;
    let ipad = rig.wifi_connect(&secret, wifi_hello()).await;
    let wifi = connected_via(lan());
    assert!(rig.statuses.reaches(&wifi, T).await);

    // An iPhone is plugged in to charge (no lain on it), then unplugged.
    rig.mux.attach(FakeDevice::usb(3, "IPHONE-3").refusing());
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(3)).await);
    tokio::time::sleep(Duration::from_millis(250)).await; // several failed dials
    assert_eq!(rig.status(), wifi);
    rig.mux.detach(3);
    assert!(eventually(T, || rig.session.usb_device_dialed().is_none()).await);
    tokio::time::sleep(Duration::from_millis(100)).await;
    expect_untouched(&mut rig, &ipad, &wifi).await;
    rig.session.stop().await;
}

#[tokio::test]
async fn an_iphone_reattaching_leaves_the_wifi_session_up() {
    let secret = secret();
    let mut rig = Rig::new(RigOptions { stored: stored(&secret), devices: vec![], ..Default::default() }).await;
    let ipad = rig.wifi_connect(&secret, wifi_hello()).await;
    let wifi = connected_via(lan());
    assert!(rig.statuses.reaches(&wifi, T).await);
    rig.mux.attach(FakeDevice::usb(3, "IPHONE-3").refusing());
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(3)).await);
    let generation = rig.session.usb_connect_loop();

    // usbmuxd reports the iPhone attached again (it re-enumerated): its connect loop starts over, and only a
    // session of that loop's would end.
    rig.mux.attach(FakeDevice::usb(3, "IPHONE-3").refusing());
    assert!(
        eventually(T, || rig.session.usb_connect_loop() != generation && rig.session.usb_device_dialed() == Some(3))
            .await
    );
    tokio::time::sleep(Duration::from_millis(100)).await;
    expect_untouched(&mut rig, &ipad, &wifi).await;
    rig.session.stop().await;
}

#[tokio::test]
async fn a_usbmuxd_restart_leaves_the_wifi_session_up() {
    let secret = secret();
    let config =
        HostConfig { tuning: Tuning { usbmux_retry_interval: Duration::from_millis(100), ..Tuning::default() }, ..wifi_config() };
    let mut rig = Rig::new(RigOptions { stored: stored(&secret), devices: vec![], config, ..Default::default() }).await;
    let ipad = rig.wifi_connect(&secret, wifi_hello()).await;
    let wifi = connected_via(lan());
    assert!(rig.statuses.reaches(&wifi, T).await);
    rig.mux.attach(FakeDevice::usb(3, "IPHONE-3").refusing());
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(3)).await);
    let generation = rig.session.usb_connect_loop();

    // usbmuxd restarts: the host forgets its devices (ending their loops) and listens again, and the iPhone is
    // reported afresh.
    rig.mux.restart();
    assert!(
        eventually(T, || rig.session.usb_connect_loop() != generation && rig.session.usb_device_dialed() == Some(3))
            .await
    );
    tokio::time::sleep(Duration::from_millis(100)).await;
    expect_untouched(&mut rig, &ipad, &wifi).await;
    rig.session.stop().await;
}

/// Linux: usbmuxd exits after the last iOS device is unplugged and is started again for the next one (SL4).
/// Neither is an error, and the next iPad is found once the daemon is back.
#[tokio::test]
async fn usbmuxd_exiting_and_coming_back_is_no_error() {
    let config =
        HostConfig { tuning: Tuning { usbmux_retry_interval: Duration::from_millis(100), ..Tuning::default() }, ..wifi_config() };
    let mut rig = Rig::new(RigOptions { config, ..Default::default() }).await;
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    rig.mux.detach(7);
    rig.mux.exit();
    assert!(rig.statuses.reaches(&HostStatus::WaitingForIPad, T).await);
    tokio::time::sleep(Duration::from_millis(350)).await; // several polls of a daemon that isn't there
    assert_eq!(rig.status(), HostStatus::WaitingForIPad);
    rig.mux.attach(FakeDevice::usb(8, SERIAL));
    rig.mux.relaunch().unwrap();
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    rig.session.stop().await;
}

// MARK: Another protocol

/// A v2 app can't negotiate: its first frame, framed in v2, is refused by the acceptor (answered in v2), and
/// the owner is told to update the iPad, as over USB.
#[tokio::test(start_paused = true)]
async fn a_wifi_peer_framing_a_legacy_protocol_is_asked_to_update() {
    let secret = secret();
    let mut rig = WifiRig::new(stored(&secret), wifi_config());
    let (mut near, far) = lain_link::memory_pair();
    let bound: Box<dyn ByteStream> = Box::new(BoundStream::new(far, secret.clone(), lan()));
    rig.wifi.send(bound).await.unwrap();
    // v2's ChannelHello: version, kind, token, HMAC, in a v2 header (the v3 codec can't write it).
    let mut payload = vec![2u8, ConnectionKind::Realtime.raw()];
    payload.extend_from_slice(&ChannelAuth::random_bytes::<16>());
    payload.extend_from_slice(&ChannelAuth::PAIRING_MAC);
    let header = FrameHeader {
        version: 2,
        ty: MessageType::ChannelHello,
        flags: HeaderFlags::EMPTY,
        sequence: 0,
        timestamp_ns: 0,
        payload_length: payload.len() as u32,
    };
    near.write_all(&header.to_bytes()).await.unwrap();
    near.write_all(&payload).await.unwrap();
    let older = HostStatus::version_gap(&VersionGap::PeerOlder { peer: "protocol v2".into() }, VersionList::offered());
    assert!(rig.statuses.reaches(&older, T).await);
    assert!(rig.session.status().title().starts_with("Error: lain on the iPad is too old (it speaks protocol v2"));
    assert!(!rig.session.has_wifi_link());
    assert!(rig.platform.power().transitions().is_empty() && rig.platform.input().actions().is_empty());
    rig.session.stop().await;
}

/// An iPad that only offers newer versions shares none with this host: the link fails in the handshake, and
/// the owner is told to update this computer.
#[tokio::test(start_paused = true)]
async fn a_newer_wifi_peer_tells_the_owner_to_update_this_computer() {
    let secret = secret();
    let mut rig = WifiRig::new(stored(&secret), wifi_config());
    let newer = VersionList::new([VersionEntry { version: NEWEST_VERSION + 1, digest: [9; 8] }]);
    let dialer = wifi_dialer(&rig.wifi, &secret).versions(newer.clone());
    let opened = dialer.open(&secret).await;
    assert_eq!(
        opened.err(),
        Some(TransportError::NoCommonVersion { local: newer.clone(), peer: VersionList::offered().clone() })
    );
    let gap = HostStatus::version_gap(&VersionGap::PeerNewer { peer: format!("protocol {newer}") }, VersionList::offered());
    assert!(rig.statuses.reaches(&gap, T).await);
    assert!(rig.session.status().title().contains("update lain on this computer"));
    assert!(rig.platform.power().transitions().is_empty() && rig.platform.input().actions().is_empty());
    rig.session.stop().await;
}

/// A `Hello` framed in a version the link didn't agree on closes the link (it's a bug, not a gap).
#[tokio::test(start_paused = true)]
async fn a_wifi_hello_framed_in_another_version_than_agreed_closes_the_link() {
    let secret = secret();
    let rig = WifiRig::new(stored(&secret), wifi_config());
    let link = wifi_dialer(&rig.wifi, &secret).open(&secret).await.unwrap();
    assert_eq!(link.version, NEWEST_VERSION);
    assert!(eventually(T, || rig.session.has_wifi_link()).await, "delivered: the host waits for its Hello");
    link.realtime.set_version(SUPPORTED_VERSIONS[0]);
    link.realtime.send(&Message::Hello(wifi_hello())).unwrap();
    assert!(eventually(T, || !rig.session.has_wifi_link()).await);
    assert!(!rig.session.status().is_connected());
    assert!(rig.platform.power().transitions().is_empty() && rig.platform.input().actions().is_empty());
    rig.session.stop().await;
}

// MARK: Lifecycle

#[tokio::test(start_paused = true)]
async fn stop_during_the_hello_wait_closes_the_link() {
    let secret = secret();
    let rig = WifiRig::new(stored(&secret), wifi_config());
    // A link that never sends Hello.
    let link = wifi_dialer(&rig.wifi, &secret).open(&secret).await.unwrap();
    assert!(eventually(T, || rig.session.has_wifi_link()).await);

    let stopped = tokio::time::Instant::now();
    let stopping = rig.session.stop();
    assert!(within(Duration::from_secs(3), link.realtime.closed()).await.is_some());
    assert!(stopped.elapsed() < Duration::from_secs(2), "closed by the stop, not the 5 s Hello timeout");
    assert!(eventually(T, || !rig.session.has_wifi_link()).await);
    assert!(rig.platform.power().transitions().is_empty() && rig.platform.input().actions().is_empty());
    stopping.await;
}

#[tokio::test(start_paused = true)]
async fn a_link_that_never_says_hello_is_closed() {
    let secret = secret();
    let config = HostConfig {
        wifi: WifiAdmission { hello_timeout: Duration::from_millis(300), ..WifiAdmission::default() },
        ..wifi_config()
    };
    let rig = WifiRig::new(stored(&secret), config);
    let link = wifi_dialer(&rig.wifi, &secret).open(&secret).await.unwrap();
    assert!(within(Duration::from_secs(3), link.realtime.closed()).await.is_some());
    assert!(eventually(T, || !rig.session.has_wifi_link()).await);
    assert!(rig.platform.power().transitions().is_empty() && rig.platform.input().actions().is_empty());
    assert_eq!(rig.session.status(), HostStatus::WaitingForIPad);
    rig.session.stop().await;
}

// MARK: Keys

/// Swift: `anAuthenticatedUSBLinkKeepsTheListener`. The listener is `lain-wifi`'s here: the session signals
/// `secrets_changed` after every USB link-up, and an authenticated one writes nothing.
#[tokio::test]
async fn every_usb_link_up_signals_secrets_changed() {
    let secret = secret();
    let mut rig = Rig::new(RigOptions {
        stored: stored(&secret),
        usb_stored: usb_stored(&secret),
        devices: vec![],
        ..Default::default()
    })
    .await;
    let mut changed = rig.session.secrets_changed();
    assert_eq!(*changed.borrow_and_update(), 0);
    rig.mux.attach(FakeDevice::usb(7, SERIAL));
    let _usb = rig.usb.next_link(T).await.expect("a USB link");
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    assert!(within(T, changed.changed()).await.is_some());
    assert_eq!(*changed.borrow(), 1);
    assert_eq!(rig.secrets.snapshot(), stored(&secret).into_iter().collect(), "authenticated: nothing written");
    rig.session.stop().await;
}

/// Swift: `noPairedIPadMeansNoListenerUntilAUSBPairing`, the session's part: the first USB session pairs, its
/// `Pair` carries the host id so the iPad keeps the secret for Wi-Fi too, and the iPad then comes back over
/// Wi-Fi with that secret.
#[tokio::test]
async fn a_usb_pairing_lets_the_ipad_come_back_over_wifi() {
    let mut rig = Rig::new(RigOptions { devices: vec![], ..Default::default() }).await;
    let mut changed = rig.session.secrets_changed();
    rig.mux.attach(FakeDevice::usb(7, SERIAL));
    let usb = rig.usb.next_link(T).await.expect("a USB link");
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    assert!(within(T, changed.changed()).await.is_some());
    let secret = rig.secrets.snapshot().get(SERIAL).cloned().expect("paired");
    assert_eq!(rig.usb.secrets.snapshot().get(&PairingAccounts::mac(&identity().id)), Some(&secret));

    // Unplugged: the iPad comes back over Wi-Fi with that secret.
    usb.close();
    rig.mux.detach(7);
    assert!(rig.statuses.reaches(&HostStatus::WaitingForIPad, T).await);
    let ipad = rig.wifi_connect(&secret, wifi_hello()).await;
    assert_eq!(ipad.hello_ack().map(|a| a.host_id.clone()), Some(identity().id));
    rig.session.stop().await;
}

/// Swift: `aUSBRePairingRestartsTheListenerWithTheNewKey`, the session's part: the iPad lost its secret, the
/// host re-pairs over USB, and from then on only the new secret gets a Wi-Fi session (the old one is refused by
/// the acceptor; refusing it at TLS is `lain-wifi`'s, once it has re-read the keys).
#[tokio::test]
async fn a_usb_re_pairing_replaces_the_wifi_secret() {
    let old = secret();
    let mut rig = Rig::new(RigOptions { stored: stored(&old), devices: vec![], ..Default::default() }).await;
    rig.mux.attach(FakeDevice::usb(7, SERIAL));
    let usb = rig.usb.next_link(T).await.expect("a USB link");
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    let new = rig.secrets.snapshot().get(SERIAL).cloned().unwrap();
    assert_ne!(new, old);
    assert_eq!(*rig.session.secrets_changed().borrow(), 1);

    usb.close();
    rig.mux.detach(7);
    assert!(rig.statuses.reaches(&HostStatus::WaitingForIPad, T).await);
    let refused = WifiIPad::connect(&rig.wifi, &old, wifi_hello()).await;
    assert_eq!(refused.err().map(|e| e.to_string()), Some(TransportError::AuthenticationFailed.to_string()));
    let ipad = rig.wifi_connect(&new, wifi_hello()).await;
    assert!(ipad.hello_ack().is_some());
    rig.session.stop().await;
}

// MARK: Capture failures

/// Every video session fails on its own 20 ms after it starts (Swift: `FailingVideo`, SCK's
/// didStopWithError).
fn fail_every_capture(platform: &TestPlatform) -> tokio::task::JoinHandle<()> {
    let video = platform.video().clone();
    tokio::spawn(async move {
        let mut seen = 0;
        loop {
            let sessions = video.sessions();
            for session in sessions.iter().skip(seen) {
                let session = session.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    session.fail(PlatformError::Failed("capture stopped".into()));
                });
            }
            seen = sessions.len();
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
}

fn retry(interval: Duration) -> Tuning {
    Tuning { capture_retry_interval: interval, ..Tuning::default() }
}

#[tokio::test]
async fn the_capture_backoff_holds_every_transport() {
    let secret = secret();
    let config = HostConfig { tuning: retry(Duration::from_millis(1500)), ..wifi_config() };
    let mut rig = Rig::new(RigOptions {
        stored: stored(&secret),
        usb_stored: usb_stored(&secret),
        devices: vec![],
        config,
        ..Default::default()
    })
    .await;
    let failing = fail_every_capture(&rig.platform);

    // Capture fails right after each start, and the host ends the session. The first time, the next session
    // may start at once.
    let first = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(first.hello_ack().is_some());
    assert!(first.link.closed(T).await);
    assert!(eventually(T, || !rig.session.has_wifi_link()).await);
    let second = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(second.hello_ack().is_some(), "{:?}", second.reply);
    assert!(second.link.closed(T).await);
    assert!(eventually(T, || !rig.session.has_wifi_link()).await);

    // Twice in a row: nothing starts for a while, whichever transport it comes over.
    let ended = tokio::time::Instant::now();
    let third = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(third.is_busy(HostStatus::CAPTURE_BACKING_OFF), "{:?}", third.reply);
    rig.mux.attach(FakeDevice::usb(7, "IPAD-9"));
    assert!(rig.statuses.reaches(&HostStatus::capture_backing_off(), T).await, "not 'open lain on the iPad'");
    tokio::time::sleep_until(ended + Duration::from_millis(1000)).await;
    assert_eq!(rig.mux.connect_count(), 0, "the USB loop waits too");
    assert!(eventually(Duration::from_secs(3), || rig.mux.connect_count() > 0).await);
    assert!(rig.statuses.reaches(&HostStatus::Connecting, T).await, "once the backoff was over");
    failing.abort();
    rig.session.stop().await;
}

/// Replugging the iPad whose sessions kept failing capture is the owner's reset: it is dialed at once, not
/// after the backoff, and its count starts over.
#[tokio::test]
async fn replugging_the_ipad_starts_its_sessions_afresh() {
    let secret = secret();
    let config = HostConfig { tuning: retry(Duration::from_secs(5)), ..wifi_config() };
    let mut rig =
        Rig::new(RigOptions { stored: stored(&secret), usb_stored: usb_stored(&secret), config, ..Default::default() })
            .await;
    let failing = fail_every_capture(&rig.platform);
    // It redials at once the first time; after the second it backs off, and the status says so.
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.statuses.reaches(&HostStatus::capture_backing_off(), T).await);
    assert_eq!(rig.status().title(), "Error: backing off after capture failures");
    assert!(rig.usb.next_link(Duration::from_millis(500)).await.is_none());

    // The owner replugs the cable (usbmuxd numbers the iPad anew): it is dialed at once, and the next failure
    // redials at once again, as the first one did.
    rig.mux.detach(7);
    rig.mux.attach(FakeDevice::usb(8, SERIAL));
    let replugged = tokio::time::Instant::now();
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(replugged.elapsed() < Duration::from_secs(2));
    failing.abort();
    rig.session.stop().await;
}

/// The same with an iPhone charging on another port: unplugging the iPad hands the dialing to the iPhone,
/// which waits the backoff out. The replugged iPad goes ahead of it.
#[tokio::test]
async fn replugging_the_ipad_goes_ahead_of_a_device_waiting_out_the_backoff() {
    let secret = secret();
    let config = HostConfig { tuning: retry(Duration::from_secs(5)), ..wifi_config() };
    let mut rig = Rig::new(RigOptions {
        stored: stored(&secret),
        usb_stored: usb_stored(&secret),
        devices: vec![FakeDevice::usb(7, SERIAL), FakeDevice::usb(3, "IPHONE-3").refusing()],
        config,
        ..Default::default()
    })
    .await;
    let failing = fail_every_capture(&rig.platform);
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.statuses.reaches(&HostStatus::capture_backing_off(), T).await);

    // Unplugged: the iPhone is dialed next, and it waits the backoff out.
    rig.mux.detach(7);
    assert!(
        eventually(T, || rig.session.usb_device_dialed() == Some(3)
            && rig.status() == HostStatus::capture_backing_off())
        .await
    );
    while rig.statuses.next(Duration::from_millis(50)).await.is_some() {} // the statuses so far

    // Replugged: the iPad is dialed ahead of it at once, the status stops saying it backs off, and the next
    // failure redials at once again.
    rig.mux.attach(FakeDevice::usb(8, SERIAL));
    let replugged = tokio::time::Instant::now();
    assert!(eventually(Duration::from_secs(1), || rig.session.usb_device_dialed() == Some(8)).await);
    let next = rig.statuses.next(Duration::from_secs(1)).await;
    assert!(next.is_some_and(|s| s != HostStatus::capture_backing_off()));
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(replugged.elapsed() < Duration::from_secs(2));

    // The iPhone kept its place in line.
    rig.mux.detach(8);
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(3)).await);
    failing.abort();
    rig.session.stop().await;
}

/// A replug behind a device that is dialing (its backoff over) waits its turn, but it is the owner's reset all
/// the same: once the iPad is dialed, a capture failure redials at once.
#[tokio::test]
async fn a_replug_waiting_its_turn_still_starts_the_count_over() {
    let secret = secret();
    let config = HostConfig { tuning: retry(Duration::from_millis(1500)), ..wifi_config() };
    let mut rig = Rig::new(RigOptions {
        stored: stored(&secret),
        usb_stored: usb_stored(&secret),
        devices: vec![FakeDevice::usb(7, SERIAL), FakeDevice::usb(3, "IPHONE-3").refusing()],
        config,
        ..Default::default()
    })
    .await;
    let failing = fail_every_capture(&rig.platform);
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.statuses.reaches(&HostStatus::capture_backing_off(), T).await);

    // Unplugged: the iPhone is dialed next and, once it has waited the backoff out, dials in vain.
    rig.mux.detach(7);
    assert!(
        eventually(T, || rig.session.usb_device_dialed() == Some(3)
            && rig.status() == HostStatus::capture_backing_off())
        .await
    );
    assert!(eventually(Duration::from_secs(3), || rig.status() == HostStatus::Connecting).await);

    // Replugged: it waits until the iPhone's fast retries run out (about 2 s). Then its first failure redials at
    // once, not after twice the interval (a third failure in a row).
    rig.mux.attach(FakeDevice::usb(8, SERIAL));
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(rig.session.usb_device_dialed(), Some(3), "a device that is dialing keeps its turn");
    assert!(rig.usb.next_link(T).await.is_some());
    let first = tokio::time::Instant::now();
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(first.elapsed() < Duration::from_millis(1500));
    failing.abort();
    rig.session.stop().await;
}

// MARK: One lain display at a time

/// A takeover inside another takeover's wait: the iPad's second link waits for its first session's display to
/// go, and a third link displaces the second before it has. The third session waits for the first session's
/// display too, not only for the second's (which never existed).
#[tokio::test(start_paused = true)]
async fn a_takeover_during_a_takeover_waits_for_every_earlier_display() {
    let secret = secret();
    let rig = WifiRig::new(stored(&secret), wifi_config());
    rig.platform.display.set_removal(Duration::from_millis(800));
    let first = rig.connect(&secret, wifi_hello()).await;
    assert!(first.hello_ack().is_some() && rig.platform.display.live() == 1);

    // The iPad redials: the second link takes over and waits while the first session's display goes...
    let host = rig.wifi.clone();
    let key = secret.clone();
    let second = tokio::spawn(async move { WifiIPad::connect(&host, &key, wifi_hello()).await });
    assert!(first.link.closed(T).await);
    assert_eq!(rig.platform.display.live(), 1);
    // ...and redials again before it has gone.
    let third = rig.connect(&secret, wifi_hello()).await;
    assert!(third.hello_ack().is_some(), "{:?}", third.reply);
    let display = &rig.platform.display;
    assert_eq!((display.peak(), display.live(), display.created()), (1, 1, 2));
    assert!(second.await.unwrap().is_err(), "closed without a HelloAck");
    rig.session.stop().await;
}

/// The same with the cable going in while the second Wi-Fi link waits: the USB session waits for the first
/// session's display too.
#[tokio::test]
async fn the_cable_going_in_during_a_takeover_waits_for_every_earlier_display() {
    let secret = secret();
    let mut rig = Rig::new(RigOptions {
        stored: stored(&secret),
        usb_stored: usb_stored(&secret),
        devices: vec![],
        ..Default::default()
    })
    .await;
    rig.platform.display.set_removal(Duration::from_millis(800));
    let first = rig.wifi_connect(&secret, wifi_hello()).await;
    assert!(first.hello_ack().is_some() && rig.platform.display.live() == 1);

    let host = rig.wifi.clone();
    let key = secret.clone();
    let second = tokio::spawn(async move { WifiIPad::connect(&host, &key, wifi_hello()).await });
    assert!(first.link.closed(T).await);
    assert_eq!(rig.platform.display.live(), 1);
    rig.mux.attach(FakeDevice::usb(7, SERIAL));
    let mut usb = rig.usb.next_link(T).await.expect("a USB link");
    assert!(usb.hello_ack().await.is_some());
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    let display = &rig.platform.display;
    assert_eq!((display.peak(), display.live(), display.created()), (1, 1, 2));
    assert!(second.await.unwrap().is_err(), "closed without a HelloAck");
    rig.session.stop().await;
}

#[allow(dead_code)]
fn _uses(_: LinkDialer<WifiDialer>) {}
