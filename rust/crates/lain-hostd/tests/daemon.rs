//! The daemon end to end over the fakes (the brief's acceptance): a client-role iPad over the fake usbmuxd (USB)
//! and over TLS-PSK on loopback (Wi-Fi) gets `HelloAck`, `DisplayLayout`, video frames and input round trips; a
//! USB pairing brings the Wi-Fi listener and its ad up; Wi-Fi off in the config, a missing host id, Wi-Fi
//! switched at run time, the setup source and the shutdown. Real time, loopback only.

mod common;

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use common::*;
use lain_host::HostStatus;
use lain_hostd::{OFF_IN_CONFIG, OFF_NO_IDENTITY, WifiControlError};
use lain_link::{LinkTransport, PairingAccounts};
use lain_linux_system::FileSecretStore;
use lain_platform::fake::MemorySecretStore;
use lain_platform::{Chroma, Monitor, PlatformError, RectF, RequirementState, SecretStore, SetupReport};
use lain_proto::*;
use lain_usbmux::fake::FakeDevice;
use lain_wifi::WiFiStatus;

fn paired(secret: &[u8]) -> (MemorySecretStore, RigOptions) {
    let host = MemorySecretStore::with([(SERIAL.to_owned(), secret.to_vec())]);
    let options = RigOptions {
        ipad_stored: vec![(PairingAccounts::USB_HOST.to_owned(), secret.to_vec())],
        ..RigOptions::default()
    };
    (host, options)
}

async fn refused(port: u16) -> bool {
    eventually(T, || std::net::TcpStream::connect(SocketAddr::from(([127, 0, 0, 1], port))).is_err()).await
}

/// The video connection's next `VideoConfig` and keyframe after a capture, then a P-frame after an ack.
async fn video_flows<S: SecretStore + Clone>(rig: &Rig<S>, link: &mut ClientLink) {
    let session = rig.platform.video().last_session().expect("video started");
    assert_eq!(session.config().chroma, Chroma::Yuv420);
    session.capture();
    let Some(Message::VideoConfig(config)) = link.first_video(T, |m| matches!(m, Message::VideoConfig(_))).await else {
        panic!("no VideoConfig")
    };
    assert_eq!((config.width, config.height, config.chroma), (2752, 2064, ChromaFormat::Yuv420));
    let Some(Message::VideoFrame(frame)) = link.first_video(T, |m| matches!(m, Message::VideoFrame(_))).await else {
        panic!("no VideoFrame")
    };
    assert!(frame.is_keyframe && frame.config_id == config.config_id);
    let _ = link.video.send(&Message::FrameAck(FrameAck { frame_id: frame.frame_id, received_at_ns: 1, bytes: 1 }));
    tokio::time::sleep(Duration::from_millis(20)).await;
    session.capture();
    let Some(Message::VideoFrame(next)) = link.first_video(T, |m| matches!(m, Message::VideoFrame(_))).await else {
        panic!("no second VideoFrame")
    };
    assert!(!next.is_keyframe && next.frame_id > frame.frame_id);
}

/// The iPad's input reaches the desktop as `lain-input` maps it, and a Ping is answered.
async fn input_round_trips<S: SecretStore + Clone>(rig: &Rig<S>, link: &mut ClientLink) {
    rig.platform.input().take();
    let input = some_input();
    for m in &input {
        link.send(m.clone());
    }
    let expected = routed(rig.input, &input);
    assert!(!expected.is_empty());
    assert!(eventually(T, || rig.actions().len() >= expected.len()).await);
    assert_eq!(rig.actions(), expected);
    link.send(Message::Ping(Ping { id: 9, sent_at_ns: 1234 }));
    let Some(Message::Pong(pong)) = link.first(T, |m| matches!(m, Message::Pong(_))).await else { panic!("no Pong") };
    assert_eq!((pong.id, pong.ping_sent_at_ns), (9, 1234));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_usb_session_end_to_end() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let mut rig = Rig::new(host, options).await;
    let mut link = rig.usb.next_link(T).await.expect("the daemon dials the iPad");
    let ack = link.hello_ack().await.expect("HelloAck");
    assert_eq!((ack.host_id.as_str(), ack.host_name.as_str()), (identity().id.as_str(), identity().name.as_str()));
    assert_eq!(
        (ack.codec, ack.chroma, ack.bit_depth, ack.bitrate),
        (VideoCodec::Hevc, ChromaFormat::Yuv420, 8, 60_000_000)
    );
    assert_eq!((ack.display_point_width, ack.display_point_height), (1376, 1032));
    assert_eq!(ack.mac_input_source, "xkb:us+colemak");
    let Some(Message::DisplayLayout(layout)) = link.first(T, |m| matches!(m, Message::DisplayLayout(_))).await else {
        panic!("no DisplayLayout")
    };
    assert!(!layout.displays.is_empty(), "{layout:?}");
    // v4: the setup, with the daemon's Start at Login item.
    let setup = link.host_setup(|_| true).await.expect("HostSetup");
    assert_eq!(setup.state_of(SetupRequirement::StartAtLogin), Some(SetupState::Missing));
    assert!(setup.video_problem.is_empty());
    assert!(rig.connected(LinkTransport::Usb).await);
    assert!(rig.platform.power().is_awake());

    video_flows(&rig, &mut link).await;
    input_round_trips(&rig, &mut link).await;

    // The handle 4b builds on sees the session's video.
    assert!(rig.handle.video_stats().is_some_and(|v| v.sent >= 2));
    let lines = rig.handle.video_lines().expect("connected");
    assert_eq!(lines[0], "Video 2752×2064 4:2:0");
    assert_eq!(rig.handle.video_error(), None);
    assert_eq!(rig.handle.peer_version_note(), None);
    rig.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_usb_pairing_brings_wifi_up_and_the_ipad_comes_back_over_tls() {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(FileSecretStore::new(dir.path()));
    let mut rig = Rig::new(store.clone(), RigOptions { devices: vec![], ..RigOptions::default() }).await;

    // Nothing paired yet: nothing listens, nothing is advertised.
    let mut wifi = rig.handle.wifi_status();
    let off = WiFiStatus::Off("no paired iPad yet".into());
    assert_eq!(reaches(&mut wifi, |s| *s == off).await, Some(off));
    assert!(*rig.handle.wifi_enabled().borrow());
    assert!(rig.advertiser.history().is_empty());

    // The first USB session pairs; the listener re-reads the secrets and listens; the ad goes out.
    rig.mux.attach(FakeDevice::usb(7, SERIAL));
    let mut usb = rig.usb.next_link(T).await.expect("a USB link");
    assert!(usb.hello_ack().await.is_some());
    let secret = rig.usb.wifi_secret().expect("the iPad keeps the secret for Wi-Fi");
    assert_eq!(store.secret(SERIAL).await.unwrap(), Some(secret.clone()), "the host stores it under the serial");
    let port = rig.listening().await;
    assert_eq!(*rig.handle.wifi_status().borrow(), WiFiStatus::Listening { port, paired: 1 });
    assert!(eventually(T, || rig.advertiser.current() == Some(expected_ad(port))).await);
    assert_eq!(rig.advertiser.history(), vec![Some(expected_ad(port))]);

    // Unplugged, the iPad comes back over Wi-Fi with that secret: TLS-PSK, the handshake, a session.
    usb.close();
    rig.mux.detach(7);
    let mut status = rig.handle.status_watch();
    assert!(reaches(&mut status, |s| *s == HostStatus::WaitingForIPad).await.is_some());
    let (mut link, reply) = wifi_connect(port, &secret, hello()).await.expect("a Wi-Fi link");
    let Message::HelloAck(ack) = reply else { panic!("no HelloAck: {reply:?}") };
    assert_eq!(ack.host_id, identity().id);
    assert!(link.first(T, |m| matches!(m, Message::DisplayLayout(_))).await.is_some());
    assert!(rig.connected(lo()).await);
    video_flows(&rig, &mut link).await;
    input_round_trips(&rig, &mut link).await;

    // Another secret's PSK is refused at TLS.
    assert!(wifi_connect(port, &common::secret(), hello()).await.is_err());
    rig.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wifi_off_in_the_config_listens_for_nothing_and_usb_works() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let mut rig = Rig::new(host, RigOptions { wifi: false, ..options }).await;
    assert_eq!(*rig.handle.wifi_status().borrow(), WiFiStatus::Off(OFF_IN_CONFIG.into()));
    assert!(!*rig.handle.wifi_enabled().borrow());

    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    assert!(rig.connected(LinkTransport::Usb).await);
    input_round_trips(&rig, &mut link).await;
    // The USB link-up bumped secrets_changed; still nothing listens or is advertised.
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(*rig.handle.wifi_status().borrow(), WiFiStatus::Off(OFF_IN_CONFIG.into()));
    assert!(rig.advertiser.history().is_empty());
    rig.shutdown().await;
    assert!(rig.advertiser.history().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn without_a_host_id_the_daemon_is_usb_only() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let mut rig = Rig::new(host, RigOptions { identity: None, ..options }).await;
    assert_eq!(*rig.handle.wifi_status().borrow(), WiFiStatus::Off(OFF_NO_IDENTITY.into()));
    assert_eq!(rig.handle.set_wifi(true).await, Err(WifiControlError::NoIdentity));
    assert!(!*rig.handle.wifi_enabled().borrow());

    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    let ack = link.hello_ack().await.expect("HelloAck");
    assert_eq!((ack.host_id.as_str(), ack.host_name.as_str()), ("", ""), "Swift: identity nil");
    assert!(rig.connected(LinkTransport::Usb).await);
    input_round_trips(&rig, &mut link).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(*rig.handle.wifi_status().borrow(), WiFiStatus::Off(OFF_NO_IDENTITY.into()));
    assert!(rig.advertiser.history().is_empty());
    rig.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wifi_switched_off_and_on_at_run_time() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let mut rig = Rig::new(host, RigOptions { devices: vec![], ..options }).await;
    let port = rig.listening().await;
    assert!(eventually(T, || rig.advertiser.current() == Some(expected_ad(port))).await);

    // Off: the listener cancelled (its own Off("stopped")), the ad withdrawn, the port closed.
    rig.handle.set_wifi(false).await.unwrap();
    assert_eq!(*rig.handle.wifi_status().borrow(), WiFiStatus::Off("stopped".into()));
    assert!(!*rig.handle.wifi_enabled().borrow());
    assert_eq!(rig.advertiser.history(), vec![Some(expected_ad(port)), None]);
    assert!(refused(port).await, "the port is closed");
    // Idempotent.
    rig.handle.set_wifi(false).await.unwrap();
    assert_eq!(rig.advertiser.history().len(), 2);

    // On: a new listener, listening again, advertised again; an iPad gets a session.
    rig.handle.set_wifi(true).await.unwrap();
    assert!(*rig.handle.wifi_enabled().borrow());
    let again = rig.listening().await;
    assert!(eventually(T, || rig.advertiser.history().len() == 3).await);
    assert_eq!(rig.advertiser.history(), vec![Some(expected_ad(port)), None, Some(expected_ad(again))]);
    rig.handle.set_wifi(true).await.unwrap();
    assert_eq!(rig.advertiser.history().len(), 3, "idempotent");
    let (_link, reply) = wifi_connect(again, &secret, hello()).await.expect("a Wi-Fi link");
    assert!(matches!(reply, Message::HelloAck(_)), "{reply:?}");
    assert!(rig.connected(lo()).await);
    rig.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_shutdown_stops_everything_in_order() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let mut rig = Rig::new(host, options).await;
    let port = rig.listening().await;
    assert!(eventually(T, || rig.advertiser.current().is_some()).await);
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    assert!(rig.connected(LinkTransport::Usb).await);
    assert!(rig.platform.display().created().is_some());
    // A key held on the desktop when the host stops.
    link.send(key(0x04, true, ModifierFlags(0)));
    assert!(eventually(T, || !rig.actions().is_empty()).await);
    let held = rig.actions();

    rig.shutdown().await;
    // Input released (invariant 4), power released, lain's display destroyed, the ad withdrawn, nothing listens.
    let actions = rig.actions();
    assert!(actions.len() > held.len() && actions.starts_with(&held), "{actions:?}");
    assert_eq!(rig.platform.power().transitions().last(), Some(&false));
    assert!(!rig.platform.power().is_awake());
    assert!(rig.platform.display().created().is_none());
    assert!(rig.platform.display().destroy_count() >= 1);
    assert_eq!(rig.advertiser.history().last(), Some(&None));
    assert_eq!(rig.advertiser.current(), None);
    assert_eq!(*rig.handle.wifi_status().borrow(), WiFiStatus::Off("stopped".into()));
    assert!(refused(port).await);
    assert!(link.closed(T).await, "the iPad's link is closed");
    assert_eq!(rig.handle.status(), HostStatus::WaitingForIPad);
    // Nothing left to control.
    assert_eq!(rig.handle.set_wifi(true).await, Err(WifiControlError::Stopped));
    // And nothing dials the still-attached iPad again.
    let dials = rig.mux.connect_count();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(rig.mux.connect_count(), dials);
    assert!(rig.usb.next_link(Duration::from_millis(100)).await.is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn start_at_login_is_polled_and_reaches_the_ipad() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let mut rig = Rig::new(host, options).await;
    assert!(rig.login.refreshes() >= 1, "read once before the session starts");
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    let first = link.host_setup(|_| true).await.expect("HostSetup");
    assert_eq!(first.state_of(SetupRequirement::StartAtLogin), Some(SetupState::Missing));

    // `lain autostart on` elsewhere: the next poll learns it, and the iPad hears.
    rig.login.set(RequirementState::Granted);
    let granted = link
        .host_setup(|s| s.state_of(SetupRequirement::StartAtLogin) == Some(SetupState::Granted))
        .await
        .expect("a new HostSetup");
    assert!(!granted.has_other_display);
    rig.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_monitor_change_is_noticed_at_once() {
    let secret = secret();
    let (host, options) = paired(&secret);
    // Polling never comes round: only the monitors' watch can notice.
    let mut rig = Rig::new(host, RigOptions { setup_poll: Duration::from_secs(3600), ..options }).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    assert!(link.host_setup(|s| !s.has_other_display).await.is_some());

    rig.platform.fake.setup.set(SetupReport { items: vec![], has_other_display: true });
    let monitor = Monitor { id: 1, bounds: RectF::new(0.0, 0.0, 2560.0, 1440.0), primary: true, lain: false };
    rig.platform.display().set_physical(vec![monitor]);
    let setup = link.host_setup(|s| s.has_other_display).await.expect("a new HostSetup");
    assert_eq!(setup.state_of(SetupRequirement::StartAtLogin), Some(SetupState::Missing));
    rig.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_video_failure_is_reported_to_the_ipad_and_the_handle() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let mut rig = Rig::new(host, options).await;
    // As lain-linux-video refuses to start when the environment pin is missing.
    let why = "video refused to load the GPU libraries: __EGL_VENDOR_LIBRARY_FILENAMES isn't set";
    rig.platform.video().fail_next_start(PlatformError::Unavailable(why.into()));
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    let setup = link.host_setup(|s| !s.video_problem.is_empty()).await.expect("HostSetup with the problem");
    assert!(setup.video_problem.contains(why), "{}", setup.video_problem);
    assert!(rig.connected(LinkTransport::Usb).await);
    assert!(rig.handle.video_error().is_some_and(|e| e.contains(why)));
    let lines = rig.handle.video_lines().expect("connected");
    assert!(lines.len() == 1 && lines[0].starts_with("No video: ") && lines[0].contains(why), "{lines:?}");
    // Input still works (input only).
    input_round_trips(&rig, &mut link).await;
    rig.shutdown().await;
}
