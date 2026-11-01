//! The daemon end to end over the fakes (the brief's acceptance): a client-role iPad over the fake usbmuxd (USB)
//! and over TLS-PSK on loopback (Wi-Fi) gets `HelloAck`, `DisplayLayout`, video frames and input round trips; a
//! USB pairing brings the Wi-Fi listener and its ad up; Wi-Fi off in the config, a missing host id, Wi-Fi
//! switched at run time, the setup source and the shutdown. Real time, loopback only.

mod common;

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use common::*;
use lain_host::{HostConfig, HostStatus};
use lain_hostd::{Daemon, OFF_IN_CONFIG, OFF_NO_IDENTITY, WifiControlError};
use lain_link::{LinkTransport, PairingAccounts};
use lain_linux_system::FileSecretStore;
use lain_platform::fake::{FakePower, MemorySecretStore};
use lain_platform::{
    Advertiser, Chroma, Monitor, PlatformError, RectF, RequirementState, SecretStore, ServiceAd, SetupReport,
};
use lain_proto::*;
use lain_usbmux::fake::{FakeDevice, FakeTarget, FakeUsbMuxd};
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
    let mut rig = Rig::new(host, RigOptions { config: config("wifi = false\n"), ..options }).await;
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_config_file_reaches_the_ipad_and_the_desktop() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let file = config("bitrate_mbps = 25\n[input.modifiers]\ncommand = \"super\"\n");
    let mut rig = Rig::new(host, RigOptions { config: file.clone(), ..options }).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    let ack = link.hello_ack().await.expect("HelloAck");
    assert_eq!(ack.bitrate, 25_000_000, "bitrate_mbps reaches HelloAck");
    assert!(rig.connected(LinkTransport::Usb).await);
    assert_eq!(rig.platform.video().last_session().expect("video started").config().bitrate, 25_000_000);
    // Cmd-A arrives as Super+A, not the default Ctrl+A.
    let remapped = routed(file.input_config(), &some_input());
    assert_ne!(remapped, routed(lain_input::InputConfig::default(), &some_input()));
    assert_eq!(rig.input, file.input_config());
    rig.platform.input().take();
    for m in some_input() {
        link.send(m);
    }
    assert!(eventually(T, || rig.actions().len() >= remapped.len()).await);
    assert_eq!(rig.actions(), remapped);
    rig.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn refresh_setup_tells_the_ipad_at_once() {
    let secret = secret();
    let (host, options) = paired(&secret);
    // Polling never comes round: only refresh_setup can tell.
    let mut rig = Rig::new(host, RigOptions { setup_poll: Duration::from_secs(3600), ..options }).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    let first = link.host_setup(|_| true).await.expect("HostSetup");
    assert_eq!(first.state_of(SetupRequirement::StartAtLogin), Some(SetupState::Missing));

    // 4b's `lain autostart on`, through an Autostart other than the daemon's: setup_changed alone resends the
    // stale cache; refresh_setup asks again.
    rig.login.set(RequirementState::Granted);
    rig.handle.refresh_setup().await;
    let granted = link
        .host_setup(|s| s.state_of(SetupRequirement::StartAtLogin) == Some(SetupState::Granted))
        .await
        .expect("a new HostSetup");
    assert!(!granted.has_other_display);
    rig.shutdown().await;
}

// MARK: Review fixes, round 1

/// The daemon over the fakes with `advertiser`, paired, a USB iPad attached; `power` is the platform's.
async fn paired_usb_daemon<A: lain_platform::Advertiser>(
    advertiser: A,
    power: FakePower,
) -> (TestPlatform<MemorySecretStore>, Daemon<TestPlatform<MemorySecretStore>>, UsbIPad, FakeUsbMuxd) {
    let secret = secret();
    let host = MemorySecretStore::with([(SERIAL.to_owned(), secret.clone())]);
    let mut platform = TestPlatform::new(host, FakeLogin::new(RequirementState::Missing));
    platform.fake.power = power;
    let usb = UsbIPad::new(vec![(PairingAccounts::USB_HOST.to_owned(), secret)], hello()).await;
    let addr = SocketAddr::from(([127, 0, 0, 1], usb.listener.port()));
    let mux = FakeUsbMuxd::start(vec![FakeDevice::usb(7, SERIAL)], FakeTarget::Tcp(addr)).unwrap();
    let config = HostConfig { identity: Some(identity()), ..HostConfig::default() };
    let daemon = Daemon::start(platform.clone(), config, mux.client(), Some(advertiser), test_options(true)).await;
    (platform, daemon, usb, mux)
}

/// An Avahi that publishes but never answers a withdrawal.
#[derive(Clone, Default)]
struct HungWithdraw;

impl Advertiser for HungWithdraw {
    async fn advertise(&self, _ad: ServiceAd) -> lain_platform::Result<()> {
        Ok(())
    }
    async fn withdraw(&self) {
        std::future::pending::<()>().await
    }
}

/// An Avahi that takes 20 s to publish (each of `AvahiAdvertiser`'s calls may take 5 s, and a publish makes
/// several).
#[derive(Clone, Default)]
struct WedgedAvahi(Arc<Mutex<Vec<Option<ServiceAd>>>>);

impl Advertiser for WedgedAvahi {
    async fn advertise(&self, ad: ServiceAd) -> lain_platform::Result<()> {
        self.0.lock().unwrap().push(Some(ad));
        tokio::time::sleep(Duration::from_secs(20)).await;
        Ok(())
    }
    async fn withdraw(&self) {
        self.0.lock().unwrap().push(None);
    }
}

/// Records, at each withdrawal, whether power was still held.
#[derive(Clone)]
struct OrderedAdvertiser {
    power: FakePower,
    withdrawn_while_awake: Arc<Mutex<Vec<bool>>>,
}

impl Advertiser for OrderedAdvertiser {
    async fn advertise(&self, _ad: ServiceAd) -> lain_platform::Result<()> {
        Ok(())
    }
    async fn withdraw(&self) {
        self.withdrawn_while_awake.lock().unwrap().push(self.power.is_awake());
    }
}

/// main's budget for the whole shutdown.
const MAINS_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_hung_withdrawal_doesnt_hold_up_the_session_stop() {
    let (platform, daemon, mut usb, _mux) = paired_usb_daemon(HungWithdraw, FakePower::default()).await;
    let mut wifi = daemon.handle().wifi_status();
    assert!(reaches(&mut wifi, |s| matches!(s, WiFiStatus::Listening { .. })).await.is_some());
    let mut link = usb.next_link(T).await.unwrap();
    assert!(link.hello_ack().await.is_some());
    assert!(eventually(T, || platform.power().is_awake()).await);
    assert!(within(MAINS_SHUTDOWN_TIMEOUT, daemon.shutdown()).await.is_some(), "the shutdown overran main's 5 s");
    assert!(!platform.power().is_awake());
    assert!(platform.display().created().is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_wedged_avahi_doesnt_keep_the_session_from_stopping() {
    let advertiser = WedgedAvahi::default();
    let (platform, daemon, mut usb, _mux) = paired_usb_daemon(advertiser.clone(), FakePower::default()).await;
    let handle = daemon.handle();
    let mut link = usb.next_link(T).await.unwrap();
    assert!(link.hello_ack().await.is_some());
    let mut status = handle.status_watch();
    let want = HostStatus::Connected { device_model: "iPad16,6".into(), via: LinkTransport::Usb };
    assert!(reaches(&mut status, |s| *s == want).await.is_some());
    // The Wi-Fi actor is inside the publish.
    assert!(eventually(T, || !advertiser.0.lock().unwrap().is_empty()).await);
    assert!(within(MAINS_SHUTDOWN_TIMEOUT, daemon.shutdown()).await.is_some(), "the shutdown overran main's 5 s");
    assert!(!platform.power().is_awake(), "session.stop() never ran");
    assert!(platform.display().created().is_none());
    assert!(link.closed(T).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_ad_is_withdrawn_before_the_session_stops() {
    let power = FakePower::default();
    let withdrawn = Arc::new(Mutex::new(Vec::new()));
    let advertiser = OrderedAdvertiser { power: power.clone(), withdrawn_while_awake: withdrawn.clone() };
    let (platform, daemon, mut usb, _mux) = paired_usb_daemon(advertiser, power).await;
    let mut wifi = daemon.handle().wifi_status();
    assert!(reaches(&mut wifi, |s| matches!(s, WiFiStatus::Listening { .. })).await.is_some());
    let mut link = usb.next_link(T).await.unwrap();
    assert!(link.hello_ack().await.is_some());
    assert!(eventually(T, || platform.power().is_awake()).await);
    within(T, daemon.shutdown()).await.expect("the daemon stops");
    assert!(!platform.power().is_awake());
    assert_eq!(*withdrawn.lock().unwrap(), vec![true], "the ad outlived the session's release");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn runtime_off_without_a_pairing_says_stopped() {
    let mut rig = Rig::new(MemorySecretStore::default(), RigOptions { devices: vec![], ..RigOptions::default() }).await;
    let mut wifi = rig.handle.wifi_status();
    let off = WiFiStatus::Off("no paired iPad yet".into());
    assert_eq!(reaches(&mut wifi, |s| *s == off).await, Some(off));
    rig.handle.set_wifi(false).await.unwrap();
    assert_eq!(*rig.handle.wifi_status().borrow(), WiFiStatus::Off("stopped".into()));
    rig.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn wifi_off_is_the_listeners_own_cancel() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let mut rig = Rig::new(host, RigOptions { devices: vec![], ..options }).await;
    rig.listening().await;
    let started = std::time::Instant::now();
    rig.handle.set_wifi(false).await.unwrap();
    // Well under the 1 s fallback: the listener answered the cancel itself.
    assert!(started.elapsed() < Duration::from_millis(500), "took {:?}", started.elapsed());
    assert_eq!(*rig.handle.wifi_status().borrow(), WiFiStatus::Off("stopped".into()));
    rig.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn dropping_the_daemon_stops_the_session() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let rig = Rig::new(host, options).await;
    let Rig { platform, daemon, handle, mut usb, mux, .. } = rig;
    let link = usb.next_link(T).await.unwrap();
    assert!(eventually(T, || platform.power().is_awake()).await);
    let mut wifi = handle.wifi_status();
    drop(handle);
    drop(daemon);
    assert!(eventually(T, || !platform.power().is_awake()).await, "power still held");
    assert!(link.closed(T).await, "the link is still up");
    // The Wi-Fi actor is gone too: its status watch closed.
    assert!(within(T, async { while wifi.changed().await.is_ok() {} }).await.is_some(), "the Wi-Fi actor runs on");
    drop(mux);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn nothing_polls_after_the_shutdown() {
    let secret = secret();
    let (host, options) = paired(&secret);
    let mut rig = Rig::new(host, RigOptions { devices: vec![], ..options }).await;
    tokio::time::sleep(Duration::from_millis(120)).await;
    rig.shutdown().await;
    let after = rig.login.refreshes();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(rig.login.refreshes(), after, "the setup poll outlived the shutdown");
}
