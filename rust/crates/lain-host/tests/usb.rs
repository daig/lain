//! The session over USB, end to end: the fake usbmuxd in front of a client-role listener (Swift:
//! `Tests/LainHostCoreTests/HostSessionTests.swift`, case by case). Real time: the fake usbmuxd's sockets are
//! real (loopback and Unix sockets only).

mod common;

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use common::*;
use lain_host::{HostConfig, HostSession, HostStatus, Tuning};
use lain_platform::{InputAction, Monitor, PointF, RectF};
use lain_proto::*;
use lain_usbmux::fake::{FakeConnection, FakeDevice, FakeTarget, FakeUsbMuxd};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;

fn tuned(tuning: Tuning) -> RigOptions {
    RigOptions { config: HostConfig { tuning, ..RigOptions::default().config }, ..RigOptions::default() }
}

async fn connect(rig: &mut Rig) -> (ClientLink, HelloAck) {
    let mut link = rig.usb.next_link(T).await.expect("the host dials the iPad");
    let ack = link.hello_ack().await.expect("HelloAck");
    (link, ack)
}

fn scroll(dy: f32, phase: GesturePhase, momentum: MomentumPhase) -> Message {
    Message::Scroll(Scroll { dx: 0.0, dy, phase, momentum_phase: momentum })
}

#[tokio::test]
async fn handshake_input_and_release_on_close() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let (mut link, ack) = connect(&mut rig).await;

    // The display is the client's (2752×2064 at 2×: 1376×1032 points); Linux streams 4:2:0 8-bit (L3).
    assert_eq!(
        ack,
        HelloAck {
            codec: VideoCodec::Hevc,
            chroma: ChromaFormat::Yuv420,
            bit_depth: 8,
            display_mode: DisplayMode::Extend,
            bitrate: 60_000_000,
            refresh_rate: 120,
            display_point_width: 1376,
            display_point_height: 1032,
            audio_sample_rate: 48_000,
            audio_channels: 2,
            audio_encoding: AudioEncoding::Pcm16Le,
            double_click_interval_ms: 500,
            key_repeat_delay_ms: 225,
            key_repeat_interval_ms: 30,
            mac_input_source: "xkb:us+colemak".into(),
            host_id: identity().id,
            host_name: identity().name,
        }
    );
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    assert_eq!(rig.awake(), [true]);

    let command = ModifierFlags::COMMAND;
    let inputs = vec![
        Message::KeyEvent(KeyEvent { usage_page: 7, usage: 0xE3, is_down: true, is_repeat: false, modifiers: command }),
        Message::PointerMove(PointerMove { x: 10.0, y: 20.0, dx: 1.0, dy: 2.0, buttons: 0 }),
        Message::PointerButton(PointerButton {
            button: MouseButton::Left,
            is_down: true,
            click_count: 1,
            x: 10.0,
            y: 20.0,
            modifiers: command,
        }),
        Message::PointerMove(PointerMove { x: 12.0, y: 24.0, dx: 2.0, dy: 4.0, buttons: 1 }),
        Message::PointerButton(PointerButton {
            button: MouseButton::Left,
            is_down: false,
            click_count: 1,
            x: 12.0,
            y: 24.0,
            modifiers: command,
        }),
        scroll(-8.0, GesturePhase::Began, MomentumPhase::None),
        Message::KeyEvent(KeyEvent {
            usage_page: 7,
            usage: 0xE3,
            is_down: false,
            is_repeat: false,
            modifiers: ModifierFlags(0),
        }),
    ];
    for m in &inputs {
        link.send(m.clone());
    }
    let expected = routed(&inputs, false);
    assert!(!expected.is_empty());
    assert!(eventually(T, || rig.actions().len() >= expected.len()).await);
    assert_eq!(rig.actions(), expected);

    // Ping is answered with a Pong echoing t0.
    link.send(Message::Ping(Ping { id: 9, sent_at_ns: 1234 }));
    let Some(Message::Pong(pong)) = link.first(T, |m| matches!(m, Message::Pong(_))).await else { panic!("no Pong") };
    assert_eq!((pong.id, pong.ping_sent_at_ns), (9, 1234));

    link.close();
    // The scroll the client began is ended by the host: the client can't once the link is gone.
    let released = routed(&inputs, true);
    assert!(released.len() > expected.len(), "the open scroll is stopped");
    assert!(eventually(T, || rig.actions() == released).await, "{:?}", rig.actions());
    // (The session redials the still-attached fake iPad right away, so check the first release.)
    assert!(eventually(T, || rig.awake().starts_with(&[true, false])).await);
    assert!(rig.platform.power().activity_count() >= 1);
    // The iPad is still attached, so the session goes back to dialing it.
    assert!(rig.statuses.reaches(&HostStatus::Connecting, T).await);
    rig.session.stop().await;
}

#[tokio::test]
async fn real_cursor_is_reflected_as_global_warp() {
    let mut rig = Rig::new(RigOptions::default()).await;
    rig.platform.display.fake.set_cursor(Some(PointF::new(300.0, 250.0)));
    let (mut link, _) = connect(&mut rig).await;
    let warp = link.first(T, |m| matches!(m, Message::CursorWarp(_))).await;
    assert_eq!(warp, Some(Message::CursorWarp(CursorWarp { x: 300.0, y: 250.0 })));

    // The desktop's own mouse moves it later, onto another monitor: reflected as is (no clamping).
    rig.platform.display.fake.set_cursor(Some(PointF::new(-1500.0, 700.0)));
    let second = link.first(T, |m| matches!(m, Message::CursorWarp(_))).await;
    assert_eq!(second, Some(Message::CursorWarp(CursorWarp { x: -1500.0, y: 700.0 })));
    rig.session.stop().await;
}

fn desktop() -> Vec<Monitor> {
    vec![
        Monitor { id: 1, bounds: RectF::new(0.0, 0.0, 1680.0, 1050.0), primary: true, lain: false },
        Monitor { id: 4, bounds: RectF::new(-1920.0, 0.0, 1920.0, 1080.0), primary: false, lain: false },
    ]
}

fn layout_of(monitors: &[(u32, f64, f64, f64, f64, bool)]) -> DisplayLayout {
    DisplayLayout {
        displays: monitors
            .iter()
            .map(|&(display_id, x, y, width, height, is_streamed)| LayoutDisplay {
                display_id,
                x,
                y,
                width,
                height,
                is_streamed,
            })
            .collect(),
    }
}

#[tokio::test]
async fn display_layout_follows_hello_ack() {
    let mut rig = Rig::new(RigOptions::default()).await;
    rig.platform.display.fake.set_physical(desktop());
    let (mut link, _) = connect(&mut rig).await;
    // The very next realtime message after HelloAck is the layout (before any warp): every monitor, lain's
    // display (to the right of the others, at the client's point size) marked as streamed.
    let next = link.next(T).await;
    let expected = layout_of(&[
        (1, 0.0, 0.0, 1680.0, 1050.0, false),
        (4, -1920.0, 0.0, 1920.0, 1080.0, false),
        (100, 1680.0, 0.0, 1376.0, 1032.0, true),
    ]);
    assert_eq!(next, Some(Message::DisplayLayout(expected)));
    rig.session.stop().await;
}

#[tokio::test]
async fn display_change_sends_a_new_layout_without_reconnecting() {
    let mut rig = Rig::new(RigOptions::default()).await;
    rig.platform.display.fake.set_physical(desktop());
    let (mut link, _) = connect(&mut rig).await;
    assert!(link.first(T, |m| matches!(m, Message::DisplayLayout(_))).await.is_some());
    link.send(key(0x04, true));
    assert!(eventually(T, || rig.actions().len() == 1).await);

    // The side monitor unplugged, while connected.
    rig.platform.display.fake.set_physical(vec![desktop()[0].clone()]);
    let changed = layout_of(&[(1, 0.0, 0.0, 1680.0, 1050.0, false), (100, 1680.0, 0.0, 1376.0, 1032.0, true)]);
    assert_eq!(
        link.first(T, |m| matches!(m, Message::DisplayLayout(_))).await,
        Some(Message::DisplayLayout(changed.clone()))
    );
    // Sent once per change, and the session goes on: no new link, nothing released, input still flows.
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(link.first(Duration::from_millis(100), |m| matches!(m, Message::DisplayLayout(_))).await, None);
    assert!(rig.usb.next_link(Duration::from_millis(100)).await.is_none());
    assert_eq!(rig.status(), HostStatus::connected_usb("iPad16,6"));
    link.send(key(0x04, false));
    assert!(eventually(T, || rig.actions().len() == 2).await);
    assert_eq!(rig.actions(), routed(&[key(0x04, true), key(0x04, false)], false));
    rig.session.stop().await;
}

#[tokio::test]
async fn a_warp_is_resent_after_a_new_layout() {
    let mut rig = Rig::new(RigOptions::default()).await;
    rig.platform.display.fake.set_physical(desktop());
    rig.platform.display.fake.set_cursor(Some(PointF::new(300.0, 250.0)));
    let (mut link, _) = connect(&mut rig).await;
    let warp = |x, y| Message::CursorWarp(CursorWarp { x, y });
    assert!(link.first(T, |m| *m == warp(300.0, 250.0)).await.is_some());
    // The owner drags lain's display left of the primary with the cursor on it: the cursor's new position is
    // reported before the layout that contains it reaches the client.
    rig.platform.display.fake.set_cursor(Some(PointF::new(-1000.0, 500.0)));
    assert!(link.first(T, |m| *m == warp(-1000.0, 500.0)).await.is_some());
    rig.platform.display.fake.move_lain(PointF::new(-3296.0, 0.0));
    assert!(link.first(T, |m| matches!(m, Message::DisplayLayout(_))).await.is_some());
    // So it is sent again after the layout (the client may have clamped the first one).
    let again = link.first(Duration::from_secs(2), |m| matches!(m, Message::CursorWarp(_))).await;
    assert_eq!(again, Some(warp(-1000.0, 500.0)));
    rig.session.stop().await;
}

#[tokio::test]
async fn detach_releases_everything() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let (link, _) = connect(&mut rig).await;
    link.send(key(0x04, true));
    assert!(eventually(T, || rig.actions().len() == 1).await);
    rig.mux.detach(7);
    let released = routed(&[key(0x04, true)], true);
    assert!(eventually(T, || rig.actions() == released).await);
    assert!(rig.statuses.reaches(&HostStatus::WaitingForIPad, T).await);
    assert!(eventually(T, || rig.awake() == [true, false]).await);
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(rig.actions(), released, "released exactly once");
    rig.session.stop().await;
}

#[tokio::test]
async fn stop_releases_everything() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let (link, _) = connect(&mut rig).await;
    link.send(key(0x04, true));
    assert!(eventually(T, || rig.actions().len() == 1).await);
    let stopped = rig.session.stop();
    // Synchronous: released before stop() returns.
    assert_eq!(rig.actions(), routed(&[key(0x04, true)], true));
    assert!(!rig.platform.power().is_awake());
    stopped.await;
    // And the display is gone once its future completes.
    assert_eq!(rig.platform.display.live(), 0);
    assert_eq!(rig.status(), HostStatus::WaitingForIPad);
}

#[tokio::test]
async fn detach_during_momentum_ends_it_on_the_desktop() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let (link, _) = connect(&mut rig).await;
    let fling = [
        scroll(-8.0, GesturePhase::Began, MomentumPhase::None),
        scroll(0.0, GesturePhase::Ended, MomentumPhase::None),
        scroll(-30.0, GesturePhase::None, MomentumPhase::Began),
    ];
    for m in &fling {
        link.send(m.clone());
    }
    let sent = routed(&fling, false);
    assert!(eventually(T, || rig.actions().len() >= sent.len()).await);
    rig.mux.detach(7); // the fling's momentum end will never arrive from the client
    let released = routed(&fling, true);
    // Whatever the desktop's scroll sequence still holds open is ended (lain-input drops the client's own
    // momentum by default and has already stopped the sequence, so the release may add nothing).
    assert!(eventually(T, || rig.actions() == released).await, "{:?}", rig.actions());
    assert!(matches!(released.last(), Some(InputAction::ScrollStop { .. })), "{released:?}");
    rig.session.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn detach_right_after_registration_leaves_no_assertion_and_no_connected_status() {
    // The iPad goes away between registering the connection and taking the power assertion.
    let once = Arc::new(AtomicBool::new(false));
    let mux_slot: Arc<std::sync::Mutex<Option<Arc<FakeUsbMuxd>>>> = Arc::default();
    let detached = Arc::new(tokio::sync::Notify::new());
    let mut tuning = Tuning::default();
    {
        let once = once.clone();
        let mux_slot = mux_slot.clone();
        let detached = detached.clone();
        tuning.after_registering = Some(Arc::new(move || {
            let first = !once.swap(true, Ordering::SeqCst);
            let mux = mux_slot.lock().unwrap().clone();
            let detached = detached.clone();
            Box::pin(async move {
                if first && let Some(mux) = mux {
                    mux.detach(7);
                    // Wait until the session has seen the detach.
                    let _ = tokio::time::timeout(T, detached.notified()).await;
                }
            })
        }));
    }
    let platform = TestPlatform::new(Default::default());
    let mut usb = UsbIPad::new(&[], hello(), VersionList::offered().clone()).await;
    let addr = std::net::SocketAddr::from(([127, 0, 0, 1], usb.listener.port()));
    let mux = Arc::new(FakeUsbMuxd::start(vec![FakeDevice::usb(7, SERIAL)], FakeTarget::Tcp(addr)).unwrap());
    *mux_slot.lock().unwrap() = Some(mux.clone());
    let config = HostConfig { tuning, ..HostConfig::default() };
    let session = HostSession::start(platform.clone(), config, mux.client(), None);
    let mut statuses = Statuses(session.status_changes());
    assert!(eventually(T, || once.load(Ordering::SeqCst)).await);
    assert!(statuses.reaches(&HostStatus::WaitingForIPad, T).await);
    detached.notify_one();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(session.status(), HostStatus::WaitingForIPad);
    assert!(!platform.power().is_awake());
    assert!(platform.power().transitions().is_empty(), "never taken: {:?}", platform.power().transitions());
    assert!(platform.input().actions().is_empty());
    let _ = usb.next_link(Duration::from_millis(10)).await;
    session.stop().await;
}

#[tokio::test]
async fn a_device_without_lain_does_not_block_the_ipad() {
    let tuning = Tuning {
        fast_retries: 2,
        fast_retry_interval: Duration::from_millis(10),
        slow_retry_interval: Duration::from_millis(50),
        ..Tuning::default()
    };
    // usbmuxd lists an iPhone (charging, no lain) before the iPad.
    let options = RigOptions {
        devices: vec![FakeDevice::usb(3, "IPHONE-3").refusing(), FakeDevice::usb(7, SERIAL)],
        ..tuned(tuning)
    };
    let mut rig = Rig::new(options).await;
    let _ = connect(&mut rig).await;
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    rig.session.stop().await;
}

#[tokio::test]
async fn the_ipad_is_dialed_when_the_active_device_detaches() {
    let tuning = Tuning { fast_retries: 1_000, fast_retry_interval: Duration::from_millis(10), ..Tuning::default() };
    let options = RigOptions {
        devices: vec![FakeDevice::usb(3, "IPHONE-3").refusing(), FakeDevice::usb(7, SERIAL)],
        ..tuned(tuning)
    };
    let mut rig = Rig::new(options).await;
    assert!(eventually(T, || rig.session.usb_device_dialed() == Some(3) && rig.status() == HostStatus::Connecting).await);
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(rig.usb.next_link(Duration::from_millis(100)).await.is_none(), "only the iPhone is being dialed");
    assert_eq!(rig.mux.connect_count(), 0);
    rig.mux.detach(3);
    assert!(rig.usb.next_link(T).await.is_some());
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    rig.session.stop().await;
}

/// lain on the iPad speaking another protocol, behind the fake usbmuxd: a v1 app can't parse our frames and
/// closes each connection without a word (`answer` `None`); a newer one answers in its own framing, then
/// closes. Swift: `OtherProtocolIPad`.
fn other_protocol_ipad(answer: Option<Vec<u8>>) -> (FakeUsbMuxd, tokio::task::JoinHandle<()>) {
    let (tx, mut rx) = mpsc::unbounded_channel::<FakeConnection>();
    let mux = FakeUsbMuxd::start(vec![FakeDevice::usb(7, SERIAL)], FakeTarget::Handoff(tx)).unwrap();
    let task = tokio::spawn(async move {
        while let Some(mut connection) = rx.recv().await {
            let answer = answer.clone();
            tokio::spawn(async move {
                let mut buf = [0u8; 256];
                if matches!(connection.stream.read(&mut buf).await, Ok(n) if n > 0)
                    && let Some(answer) = answer
                {
                    let _ = connection.stream.write_all(&answer).await;
                }
                // Dropping the stream closes it.
            });
        }
    });
    (mux, task)
}

#[tokio::test]
async fn a_v1_app_closing_right_after_channel_hello_is_asked_to_update() {
    let (mux, task) = other_protocol_ipad(None);
    let tuning = Tuning { fast_retry_interval: Duration::from_millis(250), ..Tuning::default() };
    let platform = TestPlatform::new(Default::default());
    let session =
        HostSession::start(platform.clone(), HostConfig { tuning, ..HostConfig::default() }, mux.client(), None);
    let mut statuses = Statuses(session.status_changes());
    // Dialing as usual until it has closed on us three times in a row: three link attempts of three connections
    // each (the fourth is 250 ms away).
    assert!(statuses.reaches(&HostStatus::Connecting, T).await);
    let local = VersionList::offered().clone();
    assert_eq!(statuses.next(T).await, Some(HostStatus::ipad_needs_update(&local)));
    assert_eq!(mux.connect_count(), 9);
    assert_eq!(
        session.status().title(),
        format!("Error: lain on the iPad is too old (it speaks an older protocol, this computer protocol {local}): update it")
    );
    // Unplugged, it is just waiting again.
    mux.detach(7);
    assert!(statuses.reaches(&HostStatus::WaitingForIPad, T).await);
    session.stop().await;
    task.abort();
}

#[tokio::test]
async fn a_legacy_app_answering_version_mismatch_is_asked_to_update() {
    // A v2 app answers our handshake frame in our header's version (it can't read our ChannelHello).
    let answer = MessageCodec::legacy_version_mismatch(HANDSHAKE_VERSION, "lain here speaks protocol v2", 0, 0);
    let (mux, task) = other_protocol_ipad(Some(answer));
    let tuning = Tuning { fast_retry_interval: Duration::from_secs(1), ..Tuning::default() };
    let platform = TestPlatform::new(Default::default());
    let session =
        HostSession::start(platform.clone(), HostConfig { tuning, ..HostConfig::default() }, mux.client(), None);
    let mut statuses = Statuses(session.status_changes());
    let local = VersionList::offered().clone();
    let older = HostStatus::version_gap(
        &lain_link::VersionGap::PeerOlder { peer: "a protocol from before v3".into() },
        &local,
    );
    assert!(statuses.reaches(&older, T).await);
    assert!(session.status().title().contains("update it"));
    assert_eq!(mux.connect_count(), 3, "the first link attempt said so");
    session.stop().await;
    task.abort();
}

#[tokio::test]
async fn same_device_reattach_finishes_the_old_connection_first() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let (link, _) = connect(&mut rig).await;
    link.send(key(0x04, true));
    assert!(eventually(T, || rig.actions().len() == 1).await);
    rig.mux.attach(FakeDevice::usb(7, SERIAL));
    let second = rig.usb.next_link(T).await.expect("a new link");
    // The old session was released before the new one's input.
    assert!(eventually(T, || rig.status() == HostStatus::connected_usb("iPad16,6")).await);
    second.send(key(0x05, true));
    let mut expected = routed(&[key(0x04, true)], true);
    expected.extend(routed(&[key(0x05, true)], false));
    assert!(eventually(T, || rig.actions() == expected).await, "{:?}", rig.actions());
    // As in Swift (begins 2, ends 1): the old session ends before the new one begins.
    assert_eq!(rig.awake(), [true, false, true]);
    assert!(link.closed(T).await);
    rig.session.stop().await;
}
