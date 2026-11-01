//! Test rigs (Swift: `Tests/LainHostCoreTests/TestDoubles.swift` and the rigs of `HostSessionTests` and
//! `HostSessionWiFiTests`): the platform fakes with a clock on tokio's time line, the fake usbmuxd in front of a
//! client-role USB listener (the iPad's USB side), and a client-role dialer over memory streams bound to a
//! pairing (the iPad's Wi-Fi side, as `lain-wifi` hands its TLS streams in). Loopback and memory only.
#![allow(dead_code)]

use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lain_host::{HostConfig, HostSession, HostStatus};
use lain_input::{InputConfig, InputRouter};
use lain_link::{
    BoundStream, ByteStream, ChannelSender, ClientLinkListener, DialError, Link, LinkDialer, LinkTransport,
    PairingAccounts, StreamDialer, TransportError, memory_pair,
};
use lain_platform::fake::{
    FakeClock, FakeCursor, FakeDisplay, FakeInput, FakePlatform, FakePower, FakeSettings, FakeSetup, FakeSource,
    FakeVideo, MemorySecretStore,
};
use lain_platform::{
    Clock, DisplayBackend, DisplaySpec, InputAction, InputSettings, Monitor, Platform, PointF, Result as PResult,
    StreamedDisplay,
};
use lain_proto::*;
use lain_usbmux::UsbMuxClient;
use lain_usbmux::fake::{FakeDevice, FakeTarget, FakeUsbMuxd};
use tokio::sync::{broadcast, mpsc, watch};

/// How long a test waits for something that should happen.
pub const T: Duration = Duration::from_secs(5);

pub const SERIAL: &str = "IPAD-7";

pub fn identity() -> lain_platform::HostIdentity {
    lain_platform::HostIdentity { id: "0C3F8A52-6E1B-4D57-9A0E-2B7C4F1D8E36".into(), name: "Test Computer".into() }
}

/// The iPad's `Hello` over USB (Swift: `HostSessionTests.hello`): ISO keyboard.
pub fn hello() -> Hello {
    Hello {
        device_model: "iPad16,6".into(),
        pixel_width: 2752,
        pixel_height: 2064,
        scale: 2,
        max_refresh_rate: 120,
        decode_capabilities: DecodeCapabilities::HEVC_MAIN | DecodeCapabilities::HEVC_MAIN_444_10_HARDWARE,
        keyboard_type: KeyboardType::Iso,
    }
}

/// The iPad's `Hello` over Wi-Fi (Swift: `HostSessionWiFiTests.wifiHello`): ANSI.
pub fn wifi_hello() -> Hello {
    Hello { keyboard_type: KeyboardType::Ansi, ..hello() }
}

/// Swift: `HostSessionTests.settings`.
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

pub fn key(usage: u16, is_down: bool) -> Message {
    Message::KeyEvent(KeyEvent {
        usage_page: KeyEvent::KEYBOARD_PAGE,
        usage,
        is_down,
        is_repeat: false,
        modifiers: ModifierFlags(0),
    })
}

/// What `lain-input`'s router makes of `messages` (and of a release after them, if `release`): the session
/// must apply exactly this, in order.
pub fn routed(messages: &[Message], release: bool) -> Vec<InputAction> {
    let mut router = InputRouter::new(InputConfig::default());
    let mut out = Vec::new();
    for m in messages {
        router.handle_at(m, 0, &mut out);
    }
    if release {
        router.release_all(&mut out);
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

// MARK: The platform

/// Monotonic nanoseconds on tokio's time line, so paused-time tests and the platform agree.
#[derive(Debug, Clone)]
pub struct TokioClock(tokio::time::Instant);

impl Default for TokioClock {
    fn default() -> Self {
        Self(tokio::time::Instant::now())
    }
}

impl Clock for TokioClock {
    fn now_ns(&self) -> u64 {
        1_000_000_000 + self.0.elapsed().as_nanos() as u64
    }
}

#[derive(Debug, Default)]
struct DisplayCounts {
    live: usize,
    peak: usize,
    created: usize,
    removal: Duration,
}

/// [`FakeDisplay`], with a removal that takes `removal` (as a virtual display leaves the monitor list a
/// while after it is released; Swift: `SlowDisplays`) and counts of how many exist.
#[derive(Debug, Clone, Default)]
pub struct TestDisplay {
    pub fake: FakeDisplay,
    counts: Arc<Mutex<DisplayCounts>>,
}

impl TestDisplay {
    pub fn set_removal(&self, removal: Duration) {
        self.counts.lock().unwrap().removal = removal;
    }
    pub fn live(&self) -> usize {
        self.counts.lock().unwrap().live
    }
    pub fn peak(&self) -> usize {
        self.counts.lock().unwrap().peak
    }
    pub fn created(&self) -> usize {
        self.counts.lock().unwrap().created
    }
}

impl DisplayBackend for TestDisplay {
    type Source = FakeSource;

    async fn create(&self, spec: DisplaySpec) -> PResult<(StreamedDisplay, FakeSource)> {
        let created = self.fake.create(spec).await;
        if created.is_ok() {
            let mut c = self.counts.lock().unwrap();
            c.live += 1;
            c.created += 1;
            c.peak = c.peak.max(c.live);
        }
        created
    }

    async fn destroy(&self) {
        if self.fake.created().is_none() {
            return;
        }
        let removal = self.counts.lock().unwrap().removal;
        if !removal.is_zero() {
            tokio::time::sleep(removal).await;
        }
        if self.fake.created().is_some() {
            self.fake.destroy().await;
            self.counts.lock().unwrap().live -= 1;
        }
    }

    fn monitors(&self) -> watch::Receiver<Vec<Monitor>> {
        self.fake.monitors()
    }

    fn cursor_location(&self) -> Option<PointF> {
        self.fake.cursor_location()
    }
}

/// [`FakePlatform`]'s fakes with a [`TestDisplay`] and a [`TokioClock`]. Clone it to drive the fakes.
#[derive(Debug, Clone)]
pub struct TestPlatform {
    pub fake: FakePlatform,
    pub display: TestDisplay,
    pub clock: TokioClock,
}

impl TestPlatform {
    pub fn new(secrets: MemorySecretStore) -> Self {
        let mut fake = FakePlatform::new();
        fake.secrets = secrets;
        fake.settings.set(settings());
        Self {
            display: TestDisplay { fake: fake.display.clone(), ..Default::default() },
            fake,
            clock: TokioClock::default(),
        }
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
}

impl Platform for TestPlatform {
    type Display = TestDisplay;
    type Video = FakeVideo;
    type Cursor = FakeCursor;
    type Input = FakeInput;
    type Power = FakePower;
    type Settings = FakeSettings;
    type Setup = FakeSetup;
    type Secrets = MemorySecretStore;
    type Clock = TokioClock;

    fn display(&self) -> &TestDisplay {
        &self.display
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
    fn setup(&self) -> &FakeSetup {
        &self.fake.setup
    }
    fn secrets(&self) -> &MemorySecretStore {
        &self.fake.secrets
    }
    fn clock(&self) -> &TokioClock {
        &self.clock
    }
}

// Silence an unused-import lint for FakeClock in builds of tests that don't use it.
pub type _Unused = FakeClock;

// MARK: The iPad

/// One link as the iPad sees it: what the host sends on realtime and video, and a way to send and close.
pub struct ClientLink {
    pub realtime: ChannelSender,
    pub video: ChannelSender,
    pub audio: ChannelSender,
    pub version: u8,
    pub transport: LinkTransport,
    pub received: mpsc::UnboundedReceiver<Message>,
    pub video_received: mpsc::UnboundedReceiver<Envelope>,
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
                let _ = video_tx.send(env);
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

    /// The next realtime message within `d`.
    pub async fn next(&mut self, d: Duration) -> Option<Message> {
        within(d, self.received.recv()).await.flatten()
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

    pub async fn hello_ack(&mut self) -> Option<HelloAck> {
        match self.first(T, |m| matches!(m, Message::HelloAck(_))).await {
            Some(Message::HelloAck(ack)) => Some(ack),
            _ => None,
        }
    }

    /// Whether realtime closes within `d`.
    pub async fn closed(&self, d: Duration) -> bool {
        within(d, self.realtime.closed()).await.is_some()
    }
}

/// The iPad's USB side (Swift: `USBIPad`): its loopback listener (pairing accepted) with its own store; sends
/// `Hello` on every link.
pub struct UsbIPad {
    pub secrets: MemorySecretStore,
    pub listener: ClientLinkListener<MemorySecretStore>,
    pub links: mpsc::UnboundedReceiver<ClientLink>,
}

impl UsbIPad {
    pub async fn new(stored: &[(&str, &[u8])], hello: Hello, versions: VersionList) -> Self {
        let secrets = MemorySecretStore::with(stored.iter().map(|(a, s)| ((*a).to_owned(), s.to_vec())));
        let (listener, mut events) =
            ClientLinkListener::bind(Some(0), secrets.clone(), PairingAccounts::USB_HOST, true, versions)
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
}

/// The path a network link runs over in these tests.
pub fn lan() -> LinkTransport {
    LinkTransport::Network { interface: Some("lo".into()), peer_to_peer: false }
}

/// Dials the host's network side: each connection is a memory pair whose far end, bound to `secret` as TLS
/// would bind it, goes to the host as `lain-wifi` would hand it in.
pub struct WifiDialer {
    pub host: mpsc::Sender<Box<dyn ByteStream>>,
    pub secret: Vec<u8>,
}

impl StreamDialer for WifiDialer {
    type Stream = tokio::io::DuplexStream;

    async fn dial(&self, _kind: ConnectionKind) -> Result<Self::Stream, TransportError> {
        let (near, far) = memory_pair();
        let bound: Box<dyn ByteStream> = Box::new(BoundStream::new(far, self.secret.clone(), lan()));
        self.host.send(bound).await.map_err(|_| {
            TransportError::Dial(DialError::new(std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "no host")))
        })?;
        Ok(near)
    }
}

pub fn wifi_dialer(host: &mpsc::Sender<Box<dyn ByteStream>>, secret: &[u8]) -> LinkDialer<WifiDialer> {
    LinkDialer::new(WifiDialer { host: host.clone(), secret: secret.to_vec() }).label("test.ipad.wifi")
}

/// The iPad over Wi-Fi (Swift: `WiFiIPad`): one link under a pairing's secret, then `Hello`; keeps the
/// host's reply (`HelloAck` or `Error(busy)`) and records what follows.
pub struct WifiIPad {
    pub link: ClientLink,
    pub reply: Message,
}

impl WifiIPad {
    pub async fn connect(
        host: &mpsc::Sender<Box<dyn ByteStream>>,
        secret: &[u8],
        hello: Hello,
    ) -> Result<Self, TransportError> {
        let dialer = wifi_dialer(host, secret);
        let mut link = dialer.open(secret).await?;
        link.realtime.send(&Message::Hello(hello)).map_err(|_| TransportError::Closed)?;
        let reply = LinkDialer::<WifiDialer>::reply(&mut link, T).await?;
        Ok(Self { link: ClientLink::new(link), reply: reply.message })
    }

    pub fn hello_ack(&self) -> Option<&HelloAck> {
        match &self.reply {
            Message::HelloAck(ack) => Some(ack),
            _ => None,
        }
    }

    pub fn is_busy(&self, why: &str) -> bool {
        self.reply == Message::Error(ErrorMessage { code: ErrorCode::BUSY, message: why.into() })
    }
}

// MARK: The rig

/// Every status the session publishes, in order (Swift: the `onStatus` inbox).
pub struct Statuses(pub broadcast::Receiver<HostStatus>);

impl Statuses {
    pub async fn next(&mut self, d: Duration) -> Option<HostStatus> {
        within(d, self.0.recv()).await.and_then(|r| r.ok())
    }

    /// Waits for `status`, skipping the ones before it.
    pub async fn reaches(&mut self, status: &HostStatus, d: Duration) -> bool {
        within(d, async {
            while let Ok(s) = self.0.recv().await {
                if &s == status {
                    return true;
                }
            }
            false
        })
        .await
        .unwrap_or(false)
    }
}

pub struct RigOptions {
    /// The host's pairings (iPad serial → secret).
    pub stored: Vec<(String, Vec<u8>)>,
    /// The iPad's own store.
    pub usb_stored: Vec<(String, Vec<u8>)>,
    pub devices: Vec<FakeDevice>,
    pub config: HostConfig,
    pub usb_hello: Hello,
    pub client_versions: VersionList,
}

impl Default for RigOptions {
    fn default() -> Self {
        Self {
            stored: Vec::new(),
            usb_stored: Vec::new(),
            devices: vec![FakeDevice::usb(7, SERIAL)],
            config: HostConfig { identity: Some(identity()), ..HostConfig::default() },
            usb_hello: hello(),
            client_versions: VersionList::offered().clone(),
        }
    }
}

/// A host session over the fakes, with the iPad's USB side behind the fake usbmuxd and its Wi-Fi side
/// handing streams in (Swift: the `Rig`s).
pub struct Rig {
    pub platform: TestPlatform,
    pub secrets: MemorySecretStore,
    pub usb: UsbIPad,
    pub mux: FakeUsbMuxd,
    pub wifi: mpsc::Sender<Box<dyn ByteStream>>,
    pub statuses: Statuses,
    pub session: HostSession<TestPlatform>,
}

impl Rig {
    pub async fn new(options: RigOptions) -> Self {
        let secrets = MemorySecretStore::with(options.stored);
        let platform = TestPlatform::new(secrets.clone());
        let usb_stored: Vec<(&str, &[u8])> =
            options.usb_stored.iter().map(|(a, s)| (a.as_str(), s.as_slice())).collect();
        let usb = UsbIPad::new(&usb_stored, options.usb_hello, options.client_versions).await;
        let addr = std::net::SocketAddr::from(([127, 0, 0, 1], usb.listener.port()));
        let mux = FakeUsbMuxd::start(options.devices, FakeTarget::Tcp(addr)).expect("fake usbmuxd");
        let (wifi, wifi_rx) = mpsc::channel(16);
        let session = HostSession::start(platform.clone(), options.config, mux.client(), Some(wifi_rx));
        let statuses = Statuses(session.status_changes());
        Self { platform, secrets, usb, mux, wifi, statuses, session }
    }

    pub fn status(&self) -> HostStatus {
        self.session.status()
    }

    pub fn actions(&self) -> Vec<InputAction> {
        self.platform.input().actions()
    }

    /// `set_awake` calls so far.
    pub fn awake(&self) -> Vec<bool> {
        self.platform.power().transitions()
    }

    pub async fn wifi_connect(&self, secret: &[u8], hello: Hello) -> WifiIPad {
        WifiIPad::connect(&self.wifi, secret, hello).await.expect("a Wi-Fi link")
    }
}

/// A host session with no usbmuxd at all (its socket doesn't exist: "no iPad" on Linux), for network-only
/// tests that may run on paused time.
pub struct WifiRig {
    pub platform: TestPlatform,
    pub wifi: mpsc::Sender<Box<dyn ByteStream>>,
    pub statuses: Statuses,
    pub session: HostSession<TestPlatform>,
}

impl WifiRig {
    pub fn new(stored: Vec<(String, Vec<u8>)>, config: HostConfig) -> Self {
        let platform = TestPlatform::new(MemorySecretStore::with(stored));
        let (wifi, wifi_rx) = mpsc::channel(16);
        let usbmux = UsbMuxClient::new("/nonexistent/lain-test/usbmuxd");
        let session = HostSession::start(platform.clone(), config, usbmux, Some(wifi_rx));
        let statuses = Statuses(session.status_changes());
        Self { platform, wifi, statuses, session }
    }

    pub async fn connect(&self, secret: &[u8], hello: Hello) -> WifiIPad {
        WifiIPad::connect(&self.wifi, secret, hello).await.expect("a Wi-Fi link")
    }
}

pub fn wifi_config() -> HostConfig {
    HostConfig { identity: Some(identity()), ..HostConfig::default() }
}

pub fn connected_via(transport: LinkTransport) -> HostStatus {
    HostStatus::Connected { device_model: "iPad16,6".into(), via: transport }
}
