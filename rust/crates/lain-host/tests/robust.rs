//! Lifecycle and robustness: takeovers and stops racing a slow display create, a client closing one
//! channel, fuzzed input, and nothing left alive after a drop. The robustness reviewer's probes (wave 3),
//! kept as tests where no other test covers them.

mod common;

use std::time::Duration;

use common::*;
use lain_proto::*;

fn stored(secret: &[u8]) -> Vec<(String, Vec<u8>)> {
    vec![(SERIAL.to_owned(), secret.to_vec())]
}

/// The same iPad coming back over Wi-Fi while its first session's display is still being created: at most one
/// display ever exists, and power never lapses.
#[tokio::test(start_paused = true)]
async fn a_takeover_during_a_slow_create_makes_one_display() {
    let secret = secret();
    let rig = WifiRig::new(stored(&secret), wifi_config());
    rig.platform.display.set_create_delay(Duration::from_secs(1));
    let (host, key) = (rig.wifi.clone(), secret.clone());
    let first = tokio::spawn(async move { WifiIPad::connect(&host, &key, wifi_hello()).await });
    tokio::time::sleep(Duration::from_millis(300)).await;
    let second = rig.connect(&secret, wifi_hello()).await;
    assert!(second.hello_ack().is_some(), "{:?}", second.reply);
    let _ = first.await.unwrap();
    let display = &rig.platform.display;
    assert_eq!((display.peak(), display.live()), (1, 1), "one display at a time");
    assert_eq!(rig.platform.power().transitions(), [true], "power never lapsed");
    rig.session.stop().await;
    assert_eq!(display.live(), 0);
    assert_eq!(rig.platform.power().transitions(), [true, false]);
}

/// `stop` while the display is still being created leaves nothing behind.
#[tokio::test(start_paused = true)]
async fn a_stop_during_a_slow_create_leaves_nothing() {
    let secret = secret();
    let rig = WifiRig::new(stored(&secret), wifi_config());
    rig.platform.display.set_create_delay(Duration::from_secs(1));
    let (host, key) = (rig.wifi.clone(), secret.clone());
    let first = tokio::spawn(async move { WifiIPad::connect(&host, &key, wifi_hello()).await });
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(rig.session.has_wifi_link());
    rig.session.stop().await;
    let _ = first.await.unwrap();
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(rig.platform.display.live(), 0);
    assert_eq!(rig.platform.power().transitions(), [true, false]);
}

/// Dropping the session with a live link releases power and input at once, closes the link, and removes the
/// display.
#[tokio::test(start_paused = true)]
async fn dropping_the_session_releases_everything() {
    let secret = secret();
    let rig = WifiRig::new(stored(&secret), wifi_config());
    let ipad = rig.connect(&secret, wifi_hello()).await;
    assert!(ipad.hello_ack().is_some());
    ipad.link.send(key(0x04, true));
    assert!(eventually(T, || !rig.platform.input().actions().is_empty()).await);
    let platform = rig.platform.clone();
    drop(rig.session);
    assert_eq!(platform.power().transitions(), [true, false]);
    assert_eq!(platform.input().actions(), routed(&[key(0x04, true)], true), "the held key is released");
    assert!(ipad.link.closed(T).await);
    assert!(eventually(T, || platform.display.live() == 0).await);
}

/// A client that closes only its video channel ends the whole session cleanly.
#[tokio::test(start_paused = true)]
async fn a_client_closing_only_video_ends_the_session() {
    let secret = secret();
    let rig = WifiRig::new(stored(&secret), wifi_config());
    let ipad = rig.connect(&secret, wifi_hello()).await;
    assert!(ipad.hello_ack().is_some());
    ipad.link.video.close();
    assert!(ipad.link.closed(T).await);
    assert!(eventually(T, || rig.platform.power().transitions() == [true, false]).await);
    assert!(eventually(T, || rig.platform.display.live() == 0).await);
    rig.session.stop().await;
}

/// 20,000 random input messages (NaN, infinities, extreme values, any usage, phase and button) neither panic
/// nor wedge the session: it still answers a Ping, and stops cleanly.
#[tokio::test(start_paused = true)]
async fn fuzzed_input_never_wedges_the_session() {
    let secret = secret();
    let rig = WifiRig::new(stored(&secret), wifi_config());
    let mut ipad = rig.connect(&secret, wifi_hello()).await;
    assert!(ipad.hello_ack().is_some());
    let f64s = [0.0, -0.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY, f64::MAX, -f64::MAX, 1e-300, 1.0, -1e30, 500.0];
    let f32s = [0.0f32, f32::NAN, f32::INFINITY, f32::NEG_INFINITY, f32::MAX, -f32::MAX, 1e-40, 1.0, -1e30, 3.0];
    // xorshift64: deterministic, so a failure reproduces.
    let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut r = || {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        x
    };
    let phases = [
        GesturePhase::None,
        GesturePhase::MayBegin,
        GesturePhase::Began,
        GesturePhase::Changed,
        GesturePhase::Ended,
        GesturePhase::Cancelled,
    ];
    let momenta = [MomentumPhase::None, MomentumPhase::Began, MomentumPhase::Changed, MomentumPhase::Ended];
    for i in 0..20_000u32 {
        let message = match r() % 6 {
            0 => Message::KeyEvent(KeyEvent {
                usage_page: if r() % 4 == 0 { (r() % 65536) as u16 } else { KeyEvent::KEYBOARD_PAGE },
                usage: (r() % 65536) as u16,
                is_down: r() % 2 == 0,
                is_repeat: r() % 5 == 0,
                modifiers: ModifierFlags((r() % (1 << 32)) as u32),
            }),
            1 => Message::PointerMove(PointerMove {
                x: f64s[(r() % 11) as usize],
                y: f64s[(r() % 11) as usize],
                dx: f32s[(r() % 10) as usize],
                dy: f32s[(r() % 10) as usize],
                buttons: (r() % 256) as u8,
            }),
            2 => Message::PointerButton(PointerButton {
                button: [MouseButton::Left, MouseButton::Right, MouseButton::Other][(r() % 3) as usize],
                is_down: r() % 2 == 0,
                click_count: (r() % 256) as u8,
                x: f64s[(r() % 11) as usize],
                y: f64s[(r() % 11) as usize],
                modifiers: ModifierFlags((r() % (1 << 32)) as u32),
            }),
            3 => Message::Scroll(Scroll {
                dx: f32s[(r() % 10) as usize],
                dy: f32s[(r() % 10) as usize],
                phase: phases[(r() % 6) as usize],
                momentum_phase: momenta[(r() % 4) as usize],
            }),
            4 => Message::Gesture(Gesture {
                kind: if r() % 2 == 0 { GestureKind::Magnify } else { GestureKind::Rotate },
                phase: phases[(r() % 6) as usize],
                value: f32s[(r() % 10) as usize],
            }),
            _ => Message::Ping(Ping { id: i, sent_at_ns: r() }),
        };
        ipad.link.send(message);
        if i % 200 == 0 {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
    ipad.link.send(Message::Ping(Ping { id: 999_999, sent_at_ns: 1 }));
    let pong = ipad.link.first(Duration::from_secs(30), |m| matches!(m, Message::Pong(p) if p.id == 999_999)).await;
    assert!(pong.is_some(), "the session stopped answering");
    rig.session.stop().await;
    assert_eq!(rig.platform.power().transitions(), [true, false]);
}

/// After a drop with a live Wi-Fi session and a link still waiting for its Hello, the engine's state is freed
/// (no task keeps it alive: its `secrets_changed` sender goes), the Wi-Fi intake is closed, and no display is
/// left.
#[tokio::test(start_paused = true)]
async fn a_dropped_session_is_freed_with_wifi_links_open() {
    let secret = secret();
    let rig = WifiRig::new(stored(&secret), wifi_config());
    rig.platform.display.set_removal(Duration::from_millis(500));
    let ipad = rig.connect(&secret, wifi_hello()).await;
    assert!(ipad.hello_ack().is_some());
    let (host, key) = (rig.wifi.clone(), secret.clone());
    let _pending = tokio::spawn(async move {
        let link = wifi_dialer(&host, &key).open(&key).await;
        tokio::time::sleep(Duration::from_secs(60)).await;
        drop(link);
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    let mut secrets = rig.session.secrets_changed();
    let wifi = rig.wifi.clone();
    drop(rig.session);
    let freed = within(Duration::from_secs(10), async { while secrets.changed().await.is_ok() {} }).await;
    assert!(freed.is_some(), "the engine's state is still alive 10 s after the drop");
    assert!(wifi.is_closed());
    assert_eq!(rig.platform.display.live(), 0);
}

/// The same over USB, with the fake usbmuxd: power is released at once and the engine's state is freed.
#[tokio::test]
async fn a_dropped_usb_session_is_freed() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let mut usb = rig.usb.next_link(T).await.expect("a USB link");
    assert!(usb.hello_ack().await.is_some());
    let mut secrets = rig.session.secrets_changed();
    let platform = rig.platform.clone();
    drop(rig.session);
    assert_eq!(platform.power().transitions(), [true, false]);
    let freed = within(Duration::from_secs(10), async { while secrets.changed().await.is_ok() {} }).await;
    assert!(freed.is_some(), "the engine's state is still alive 10 s after the drop");
    assert!(usb.closed(T).await);
}
