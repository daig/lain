//! Test rigs: the daemon over `lain-platform`'s fakes, with the iPad's USB side behind the fake usbmuxd (a
//! client-role `lain-link` listener, as in `lain-host`'s tests) and its Wi-Fi side dialing the daemon's real
//! TLS-PSK listener on loopback with `lain-wifi`'s dialer. Loopback, Unix sockets and temp dirs only.
#![allow(dead_code)]

use std::future::Future;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lain_host::HostStatus;
use lain_hostd::{Config, Daemon, DaemonHandle, DaemonOptions, DaemonSetup, LoginItem};
use lain_input::{InputConfig, InputRouter};
use lain_link::{ChannelSender, ClientLinkListener, Link, LinkDialer, LinkTransport, PairingAccounts, TransportError};
use lain_platform::fake::{
    FakeAdvertiser, FakeAudio, FakeClock, FakeCursor, FakeDisplay, FakeInput, FakePlatform, FakePower, FakeSettings,
    FakeSetup, FakeVideo, MemorySecretStore,
};
use lain_platform::{HostIdentity, InputAction, InputSettings, Platform, RequirementState, SecretStore, ServiceAd};
use lain_proto::*;
use lain_usbmux::fake::{FakeDevice, FakeTarget, FakeUsbMuxd};
use lain_wifi::{LainTxt, WiFiDialer, WiFiListenerOptions, WiFiStatus};
use tokio::sync::{mpsc, watch};

/// How long a test waits for something that should happen.
pub const T: Duration = Duration::from_secs(5);

pub const SERIAL: &str = "IPAD-7";

pub fn identity() -> HostIdentity {
    HostIdentity { id: "0C3F8A52-6E1B-4D57-9A0E-2B7C4F1D8E36".into(), name: "Test Computer".into() }
}

pub fn hello() -> Hello {
    Hello {
        device_model: "iPad16,6".into(),
        pixel_width: 2752,
        pixel_height: 2064,
        scale: 2,
        max_refresh_rate: 120,
        decode_capabilities: DecodeCapabilities::HEVC_MAIN | DecodeCapabilities::HEVC_MAIN_444_10_HARDWARE,
        keyboard_type: KeyboardType::Ansi,
    }
}

pub fn settings() -> InputSettings {
    InputSettings {
        double_click_ms: 500,
        key_repeat_delay_ms: 225,
        key_repeat_interval_ms: 30,
        input_source: "xkb:us+colemak".into(),
    }
}

pub fn secret() -> Vec<u8> {
    lain_link::ChannelAuth::random_bytes::<32>().to_vec()
}

pub fn key(usage: u16, is_down: bool, modifiers: ModifierFlags) -> Message {
    Message::KeyEvent(KeyEvent { usage_page: KeyEvent::KEYBOARD_PAGE, usage, is_down, is_repeat: false, modifiers })
}

/// Some input, as the iPad sends it: Cmd-A typed, the pointer moved and clicked.
pub fn some_input() -> Vec<Message> {
    let cmd = ModifierFlags::COMMAND;
    vec![
        key(0xE3, true, cmd),
        key(0x04, true, cmd),
        key(0x04, false, cmd),
        key(0xE3, false, ModifierFlags(0)),
        Message::PointerMove(PointerMove { x: 10.0, y: 20.0, dx: 1.0, dy: 2.0, buttons: 0 }),
        Message::PointerButton(PointerButton {
            button: MouseButton::Left,
            is_down: true,
            click_count: 1,
            x: 10.0,
            y: 20.0,
            modifiers: ModifierFlags(0),
        }),
        Message::PointerButton(PointerButton {
            button: MouseButton::Left,
            is_down: false,
            click_count: 1,
            x: 10.0,
            y: 20.0,
            modifiers: ModifierFlags(0),
        }),
    ]
}

/// What `lain-input` makes of `messages` under `config`: the session must apply exactly this.
pub fn routed(config: InputConfig, messages: &[Message]) -> Vec<InputAction> {
    let mut router = InputRouter::new(config);
    let mut out = Vec::new();
    for m in messages {
        router.handle_at(m, 0, &mut out);
    }
    out
}

/// Polls `condition` every 5 ms until it holds or `within` passes.
pub async fn eventually(within: Duration, mut condition: impl FnMut() -> bool) -> bool {
    let deadline = tokio::time::Instant::now() + within;
    while tokio::time::Instant::now() < deadline {
        if condition() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    condition()
}

pub async fn within<F: Future>(d: Duration, f: F) -> Option<F::Output> {
    tokio::time::timeout(d, f).await.ok()
}

/// Waits until `watch` holds a value `pred` accepts, and returns it.
pub async fn reaches<V: Clone>(watch: &mut watch::Receiver<V>, pred: impl FnMut(&V) -> bool) -> Option<V> {
    within(T, watch.wait_for(pred)).await.and_then(|r| r.ok()).map(|v| v.clone())
}

// MARK: The platform

/// Start at Login as a cache the daemon refreshes (`lain_linux_system::Autostart` in the real daemon).
#[derive(Debug, Clone)]
pub struct FakeLogin {
    state: Arc<Mutex<RequirementState>>,
    /// What the next refresh learns.
    next: Arc<Mutex<RequirementState>>,
    refreshes: Arc<AtomicUsize>,
}

impl FakeLogin {
    pub fn new(state: RequirementState) -> Self {
        Self {
            state: Arc::new(Mutex::new(RequirementState::Unknown)),
            next: Arc::new(Mutex::new(state)),
            refreshes: Arc::default(),
        }
    }
    /// What systemd says from now on (learned at the next refresh).
    pub fn set(&self, state: RequirementState) {
        *self.next.lock().unwrap() = state;
    }
    pub fn refreshes(&self) -> usize {
        self.refreshes.load(Ordering::SeqCst)
    }
}

impl LoginItem for FakeLogin {
    fn cached(&self) -> RequirementState {
        *self.state.lock().unwrap()
    }
    async fn refresh(&self) {
        *self.state.lock().unwrap() = *self.next.lock().unwrap();
        self.refreshes.fetch_add(1, Ordering::SeqCst);
    }
}

/// [`FakePlatform`]'s fakes with the daemon's setup source and any secret store.
#[derive(Debug, Clone)]
pub struct TestPlatform<S> {
    pub fake: FakePlatform,
    pub setup: DaemonSetup<FakeSetup, FakeLogin>,
    pub secrets: S,
}

impl<S: SecretStore + Clone> TestPlatform<S> {
    pub fn new(secrets: S, login: FakeLogin) -> Self {
        let fake = FakePlatform::new();
        fake.settings.set(settings());
        Self { setup: DaemonSetup::new(fake.setup.clone(), login), fake, secrets }
    }
    pub fn input(&self) -> &FakeInput {
        &self.fake.input
    }
    pub fn power(&self) -> &FakePower {
        &self.fake.power
    }
    pub fn video(&self) -> &FakeVideo {
        &self.fake.video
    }
    pub fn display(&self) -> &FakeDisplay {
        &self.fake.display
    }
}

impl<S: SecretStore + Clone> Platform for TestPlatform<S> {
    type Display = FakeDisplay;
    type Video = FakeVideo;
    type Cursor = FakeCursor;
    type Input = FakeInput;
    type Power = FakePower;
    type Settings = FakeSettings;
    type Setup = DaemonSetup<FakeSetup, FakeLogin>;
    type Secrets = S;
    type Clock = FakeClock;
    type Audio = FakeAudio;

    fn display(&self) -> &FakeDisplay {
        &self.fake.display
    }
    fn video(&self) -> &FakeVideo {
        &self.fake.video
    }
    fn cursor(&self) -> &FakeCursor {
        &self.fake.cursor
    }
    fn input(&self) -> &FakeInput {
        &self.fake.input
    }
    fn power(&self) -> &FakePower {
        &self.fake.power
    }
    fn settings(&self) -> &FakeSettings {
        &self.fake.settings
    }
    fn setup(&self) -> &DaemonSetup<FakeSetup, FakeLogin> {
        &self.setup
    }
    fn secrets(&self) -> &S {
        &self.secrets
    }
    fn clock(&self) -> &FakeClock {
        &self.fake.clock
    }
    fn audio(&self) -> &FakeAudio {
        &self.fake.audio
    }
}

// MARK: The iPad

/// One link as the iPad sees it: what the host sends on realtime and video, and a way to send and close.
pub struct ClientLink {
    pub realtime: ChannelSender,
    pub video: ChannelSender,
    pub audio: ChannelSender,
    pub version: u8,
    pub transport: LinkTransport,
    pub received: mpsc::UnboundedReceiver<Message>,
    pub video_received: mpsc::UnboundedReceiver<Message>,
}

impl ClientLink {
    pub fn new(link: Link) -> Self {
        let Link { mut realtime, mut video, mut audio, version, transport, .. } = link;
        let (rt_tx, received) = mpsc::unbounded_channel();
        let (video_tx, video_received) = mpsc::unbounded_channel();
        let senders = (realtime.sender(), video.sender(), audio.sender());
        tokio::spawn(async move {
            while let Ok(env) = realtime.recv().await {
                let _ = rt_tx.send(env.message);
            }
        });
        tokio::spawn(async move {
            while let Ok(env) = video.recv().await {
                let _ = video_tx.send(env.message);
            }
        });
        tokio::spawn(async move { while audio.recv().await.is_ok() {} });
        Self { realtime: senders.0, video: senders.1, audio: senders.2, version, transport, received, video_received }
    }

    pub fn send(&self, message: Message) {
        let _ = self.realtime.send(&message);
    }

    pub fn close(&self) {
        self.realtime.close();
        self.video.close();
        self.audio.close();
    }

    /// The first realtime message within `d` that `pred` accepts, skipping the others.
    pub async fn first(&mut self, d: Duration, mut pred: impl FnMut(&Message) -> bool) -> Option<Message> {
        within(d, async {
            while let Some(m) = self.received.recv().await {
                if pred(&m) {
                    return Some(m);
                }
            }
            None
        })
        .await
        .flatten()
    }

    /// The first video-connection message within `d` that `pred` accepts.
    pub async fn first_video(&mut self, d: Duration, mut pred: impl FnMut(&Message) -> bool) -> Option<Message> {
        within(d, async {
            while let Some(m) = self.video_received.recv().await {
                if pred(&m) {
                    return Some(m);
                }
            }
            None
        })
        .await
        .flatten()
    }

    pub async fn hello_ack(&mut self) -> Option<HelloAck> {
        match self.first(T, |m| matches!(m, Message::HelloAck(_))).await {
            Some(Message::HelloAck(ack)) => Some(ack),
            _ => None,
        }
    }

    pub async fn host_setup(&mut self, mut pred: impl FnMut(&HostSetup) -> bool) -> Option<HostSetup> {
        match self.first(T, |m| matches!(m, Message::HostSetup(s) if pred(s))).await {
            Some(Message::HostSetup(s)) => Some(s),
            _ => None,
        }
    }

    /// Whether realtime closes within `d`.
    pub async fn closed(&self, d: Duration) -> bool {
        within(d, self.realtime.closed()).await.is_some()
    }
}

/// The iPad's USB side: its loopback listener (pairing accepted) with its own store; sends `Hello` on every link.
pub struct UsbIPad {
    pub secrets: MemorySecretStore,
    pub listener: ClientLinkListener<MemorySecretStore>,
    pub links: mpsc::UnboundedReceiver<ClientLink>,
}

impl UsbIPad {
    pub async fn new(stored: Vec<(String, Vec<u8>)>, hello: Hello) -> Self {
        let secrets = MemorySecretStore::with(stored);
        let (listener, mut events) = ClientLinkListener::bind(
            Some(0),
            secrets.clone(),
            PairingAccounts::USB_HOST,
            true,
            VersionList::offered().clone(),
        )
        .await
        .expect("bind the iPad's loopback listener");
        let (tx, links) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Some(accepted) = events.links.recv().await {
                let _ = accepted.link.realtime.send(&Message::Hello(hello.clone()));
                let _ = tx.send(ClientLink::new(accepted.link));
            }
        });
        Self { secrets, listener, links }
    }

    pub async fn next_link(&mut self, d: Duration) -> Option<ClientLink> {
        within(d, self.links.recv()).await.flatten()
    }

    /// The secret the iPad keeps for Wi-Fi to this host (`mac:<hostId>`), once paired.
    pub fn wifi_secret(&self) -> Option<Vec<u8>> {
        self.secrets.snapshot().get(&PairingAccounts::mac(&identity().id)).cloned()
    }
}

/// The iPad over Wi-Fi: `lain-link`'s dialer over `lain-wifi`'s TLS-PSK client, then `Hello`; the host's
/// reply (`HelloAck` or an error) and the link.
pub async fn wifi_connect(port: u16, secret: &[u8], hello: Hello) -> Result<(ClientLink, Message), TransportError> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let dialer = LinkDialer::new(WiFiDialer::new(addr, secret)).label("test.ipad.wifi");
    let mut link = dialer.open(secret).await?;
    link.realtime.send(&Message::Hello(hello)).map_err(|_| TransportError::Closed)?;
    let reply = LinkDialer::<WiFiDialer>::reply(&mut link, T).await?;
    Ok((ClientLink::new(link), reply.message))
}

pub fn lo() -> LinkTransport {
    LinkTransport::Network { interface: Some("lo".into()), peer_to_peer: false }
}

/// The ad the daemon must publish while listening on `port` (the brief: `LainTxt::service_ad(name, port, id,
/// None)`).
pub fn expected_ad(port: u16) -> ServiceAd {
    LainTxt::service_ad(&identity().name, port, &identity().id, None)
}

// MARK: The rig

pub struct RigOptions {
    /// The iPad's own store (empty: the first USB session pairs).
    pub ipad_stored: Vec<(String, Vec<u8>)>,
    pub devices: Vec<FakeDevice>,
    pub identity: Option<HostIdentity>,
    /// The config file, mapped as the binary maps it (`Config::host_config`, `Config::daemon_options`).
    pub config: Config,
    pub login: RequirementState,
    pub setup_poll: Duration,
}

impl Default for RigOptions {
    fn default() -> Self {
        Self {
            ipad_stored: Vec::new(),
            devices: vec![FakeDevice::usb(7, SERIAL)],
            identity: Some(identity()),
            config: Config::default(),
            login: RequirementState::Missing,
            setup_poll: Duration::from_millis(50),
        }
    }
}

/// `text` as `config.toml`.
pub fn config(text: &str) -> Config {
    Config::parse(std::path::Path::new("/test/lain/config.toml"), text).expect("a valid config")
}

pub fn test_options(wifi: bool) -> DaemonOptions {
    DaemonOptions {
        wifi,
        listener: WiFiListenerOptions::loopback(),
        setup_poll: Duration::from_millis(50),
        status_poll: Duration::from_millis(50),
        video_log_interval: Duration::from_millis(200),
        ..DaemonOptions::default()
    }
}

/// The daemon over the fakes, the fake usbmuxd in front of the iPad's USB side, and a recording advertiser.
pub struct Rig<S: SecretStore + Clone> {
    pub platform: TestPlatform<S>,
    pub login: FakeLogin,
    pub advertiser: FakeAdvertiser,
    pub usb: UsbIPad,
    pub mux: FakeUsbMuxd,
    pub daemon: Option<Daemon<TestPlatform<S>>>,
    pub handle: DaemonHandle<TestPlatform<S>>,
    pub input: InputConfig,
}

impl<S: SecretStore + Clone> Rig<S> {
    pub async fn new(secrets: S, options: RigOptions) -> Self {
        let login = FakeLogin::new(options.login);
        let platform = TestPlatform::new(secrets, login.clone());
        let usb = UsbIPad::new(options.ipad_stored, hello()).await;
        let addr = SocketAddr::from(([127, 0, 0, 1], usb.listener.port()));
        let mux = FakeUsbMuxd::start(options.devices, FakeTarget::Tcp(addr)).expect("fake usbmuxd");
        let advertiser = FakeAdvertiser::default();
        let config = options.config.host_config(options.identity, VersionList::offered().clone());
        let input = config.input;
        let daemon_options =
            DaemonOptions { setup_poll: options.setup_poll, ..test_options(options.config.daemon_options().wifi) };
        let daemon =
            Daemon::start(platform.clone(), config, mux.client(), Some(advertiser.clone()), daemon_options).await;
        let handle = daemon.handle();
        Self { platform, login, advertiser, usb, mux, daemon: Some(daemon), handle, input }
    }

    pub fn status(&self) -> HostStatus {
        self.handle.status()
    }

    pub fn actions(&self) -> Vec<InputAction> {
        self.platform.input().actions()
    }

    /// Waits for the Wi-Fi status to be `Listening` and returns its port.
    pub async fn listening(&self) -> u16 {
        let mut status = self.handle.wifi_status();
        let listening = reaches(&mut status, |s| matches!(s, WiFiStatus::Listening { .. })).await;
        listening
            .and_then(|s| s.port())
            .unwrap_or_else(|| panic!("not listening: {:?}", self.handle.wifi_status().borrow()))
    }

    pub async fn connected(&self, via: LinkTransport) -> bool {
        let mut status = self.handle.status_watch();
        let want = HostStatus::Connected { device_model: "iPad16,6".into(), via };
        reaches(&mut status, |s| *s == want).await.is_some()
    }

    pub async fn shutdown(&mut self) {
        if let Some(daemon) = self.daemon.take() {
            within(T, daemon.shutdown()).await.expect("the daemon stops within 5 s");
        }
    }
}
