//! Test helpers, ported from Swift's `LainTransportTests/Helpers.swift` where they have a counterpart.
#![allow(dead_code)]

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use lain_link::*;
use lain_platform::fake::MemorySecretStore;
use lain_platform::{PlatformError, SecretStore};
use lain_proto::*;
use tokio::io::DuplexStream;
use tokio::sync::mpsc;

pub const T: Duration = Duration::from_secs(2);

pub fn secret() -> Vec<u8> {
    ChannelAuth::random_bytes::<32>().to_vec()
}

pub fn token() -> [u8; 16] {
    ChannelAuth::random_bytes()
}

pub fn ping(id: u32, sent_at_ns: u64) -> Message {
    Message::Ping(Ping { id, sent_at_ns })
}

/// Version lists with fixed digests: equal fill bytes mean the same build of a version.
pub fn versions(entries: &[(u8, u8)]) -> VersionList {
    VersionList::new(entries.iter().map(|&(version, build)| VersionEntry { version, digest: [build; 8] }))
}

pub fn offered() -> VersionList {
    VersionList::offered().clone()
}

pub fn hello_msg(kind: ConnectionKind, token: [u8; 16], secret: Option<&[u8]>) -> Message {
    Message::ChannelHello(ChannelAuth::hello(kind, token, secret, &offered()))
}

pub fn sample_hello() -> Hello {
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

pub fn sample_hello_ack() -> HelloAck {
    HelloAck {
        codec: VideoCodec::Hevc,
        chroma: ChromaFormat::Yuv444,
        bit_depth: 10,
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
        mac_input_source: "com.apple.keylayout.Colemak".into(),
        host_id: String::new(),
        host_name: String::new(),
    }
}

/// The next value within `within`, else `None`.
pub async fn next<T>(rx: &mut mpsc::UnboundedReceiver<T>, within: Duration) -> Option<T> {
    tokio::time::timeout(within, rx.recv()).await.ok().flatten()
}

/// A secret store whose reads fail on demand and that counts writes (the acceptor's read rules, §7.7 D29:
/// a pairing writes, a re-authentication doesn't). Swift: `ScriptedSecrets`.
/// Also, on demand: writes that fail, or calls that never finish (a Secret Service waiting on a locked
/// keyring's prompt), counted while in flight.
#[derive(Clone, Default)]
pub struct ScriptedSecrets {
    pub inner: MemorySecretStore,
    pub fails_secret_read: bool,
    pub fails_listing: bool,
    pub fails_store: bool,
    pub hangs: bool,
    pub writes: Arc<AtomicUsize>,
    pub in_flight: Arc<AtomicUsize>,
}

impl ScriptedSecrets {
    pub fn new(initial: &[(&str, &[u8])]) -> Self {
        Self { inner: store(initial), ..Self::default() }
    }

    pub fn write_count(&self) -> usize {
        self.writes.load(Ordering::SeqCst)
    }

    pub fn in_flight(&self) -> usize {
        self.in_flight.load(Ordering::SeqCst)
    }

    /// With `hangs`, never returns; counted in `in_flight` until dropped.
    async fn maybe_hang(&self) {
        if self.hangs {
            let _guard = InFlight::new(&self.in_flight);
            std::future::pending::<()>().await;
        }
    }
}

struct InFlight(Arc<AtomicUsize>);

impl InFlight {
    fn new(count: &Arc<AtomicUsize>) -> Self {
        count.fetch_add(1, Ordering::SeqCst);
        Self(count.clone())
    }
}

impl Drop for InFlight {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

impl SecretStore for ScriptedSecrets {
    async fn secret(&self, account: &str) -> lain_platform::Result<Option<Vec<u8>>> {
        self.maybe_hang().await;
        if self.fails_secret_read {
            return Err(PlatformError::Denied("scripted read failure".into()));
        }
        self.inner.secret(account).await
    }
    async fn set_secret(&self, account: &str, secret: &[u8]) -> lain_platform::Result<()> {
        self.maybe_hang().await;
        if self.fails_store {
            return Err(PlatformError::Denied("scripted store failure".into()));
        }
        self.writes.fetch_add(1, Ordering::SeqCst);
        self.inner.set_secret(account, secret).await
    }
    async fn remove_secret(&self, account: &str) -> lain_platform::Result<()> {
        self.inner.remove_secret(account).await
    }
    async fn all_secrets(&self) -> lain_platform::Result<BTreeMap<String, Vec<u8>>> {
        self.maybe_hang().await;
        if self.fails_listing {
            return Err(PlatformError::Denied("scripted listing failure".into()));
        }
        self.inner.all_secrets().await
    }
}

pub fn store(initial: &[(&str, &[u8])]) -> MemorySecretStore {
    MemorySecretStore::with(initial.iter().map(|(a, s)| (a.to_string(), s.to_vec())))
}

/// A dialer whose every dial is accepted, in memory, by `acceptor`; with `bind`, both ends are
/// pairing-bound to that secret over a network path (as Wi-Fi TLS-PSK binds them). Swift's tests dial a
/// loopback `TCPListener` feeding the acceptor instead.
pub struct AcceptingDialer<S: SecretStore> {
    pub acceptor: Arc<LinkAcceptor<S>>,
    pub bind: Option<Vec<u8>>,
}

pub fn wifi_path() -> LinkTransport {
    LinkTransport::Network { interface: Some("lo".into()), peer_to_peer: false }
}

impl<S: SecretStore> AcceptingDialer<S> {
    /// One end, accepted; the other returned.
    pub fn connect(&self) -> Box<dyn ByteStream> {
        let (near, far) = memory_pair();
        match &self.bind {
            Some(secret) => {
                self.acceptor.accept(BoundStream::new(far, secret.clone(), wifi_path()));
                Box::new(BoundStream::new(near, secret.clone(), wifi_path()))
            }
            None => {
                self.acceptor.accept(far);
                Box::new(near)
            }
        }
    }
}

impl<S: SecretStore> StreamDialer for AcceptingDialer<S> {
    type Stream = Box<dyn ByteStream>;
    async fn dial(&self, _kind: ConnectionKind) -> Result<Self::Stream, TransportError> {
        Ok(self.connect())
    }
}

/// A `LinkAcceptor` fed in memory, as the host's Wi-Fi acceptor is fed by its listener. Swift:
/// `AcceptorHarness`.
pub struct Acceptor<S: SecretStore> {
    pub acceptor: Arc<LinkAcceptor<S>>,
    pub links: mpsc::UnboundedReceiver<AcceptedLink>,
    pub rejections: mpsc::UnboundedReceiver<TransportError>,
    pub secrets: S,
}

impl<S: SecretStore + Clone> Acceptor<S> {
    pub fn new(secrets: S, options: AcceptorOptions) -> Self {
        let (acceptor, events) = LinkAcceptor::new(secrets.clone(), options);
        Self { acceptor: Arc::new(acceptor), links: events.links, rejections: events.rejections, secrets }
    }

    /// The host's side: no primary account, every stored iPad is a candidate, no pairing.
    pub fn host(secrets: S) -> Self {
        Self::new(secrets, AcceptorOptions { label: "test.acceptor".into(), ..AcceptorOptions::default() })
    }

    /// The client's USB listener (Swift: `ClientLinkListener`'s acceptor): primary account "host", pairing
    /// stored for USB and Wi-Fi, if `accepts_pairing`.
    pub fn client(secrets: S, accepts_pairing: bool, versions: VersionList) -> Self {
        let pairing =
            if accepts_pairing { Pairing::client(secrets.clone(), PairingAccounts::USB_HOST) } else { Pairing::Refuse };
        Self::new(
            secrets,
            AcceptorOptions {
                primary_account: Some(PairingAccounts::USB_HOST.into()),
                pairing,
                label: "test.client".into(),
                transport: None,
                versions,
            },
        )
    }

    /// Every link this client accepts answers `Hello` at once, as ClientSession does. Swift:
    /// `AcceptingClient`.
    pub fn answering_hello(mut self) -> Self {
        let (tx, rx) = mpsc::unbounded_channel();
        let mut links = std::mem::replace(&mut self.links, rx);
        tokio::spawn(async move {
            while let Some(accepted) = links.recv().await {
                accepted.link.realtime.send(&Message::Hello(sample_hello())).unwrap();
                if tx.send(accepted).is_err() {
                    return;
                }
            }
        });
        self
    }

    pub fn dialer(&self) -> AcceptingDialer<S> {
        AcceptingDialer { acceptor: self.acceptor.clone(), bind: None }
    }

    pub fn bound_dialer(&self, secret: &[u8]) -> AcceptingDialer<S> {
        AcceptingDialer { acceptor: self.acceptor.clone(), bind: Some(secret.to_vec()) }
    }

    /// A raw connection, for writing handshakes by hand. Swift: `rawChannel(to:)`.
    pub fn raw(&self) -> MessageChannel {
        MessageChannel::new(self.dialer().connect(), "raw")
    }

    /// A raw connection whose transport authenticated `tls` (as Wi-Fi TLS-PSK would).
    pub fn raw_bound(&self, tls: &[u8]) -> MessageChannel {
        MessageChannel::new(self.bound_dialer(tls).connect(), "raw.bound")
    }

    /// A raw byte stream, unframed.
    pub fn raw_bytes(&self) -> DuplexStream {
        let (near, far) = memory_pair();
        self.acceptor.accept(far);
        near
    }
}

/// `bytes` with its header's version byte replaced (a frame in another version's framing).
pub fn reframed(mut bytes: Vec<u8>, version: u8) -> Vec<u8> {
    bytes[2] = version;
    bytes
}

/// A legacy (v1–v2) peer's first frame: a pairing `ChannelHello` in its own framing (header `version`;
/// payload: version, kind, token, all-zero HMAC). The v3 codec can't write it. Swift: `legacyChannelHello`.
pub fn legacy_channel_hello(version: u8) -> Vec<u8> {
    let mut payload = vec![version, ConnectionKind::Realtime.raw()];
    payload.extend_from_slice(&token());
    payload.extend_from_slice(&ChannelAuth::PAIRING_MAC);
    let header = FrameHeader {
        version,
        ty: MessageType::ChannelHello,
        flags: HeaderFlags::EMPTY,
        sequence: 0,
        timestamp_ns: 0,
        payload_length: payload.len() as u32,
    };
    let mut out = header.to_bytes().to_vec();
    out.extend_from_slice(&payload);
    out
}

/// Reads one whole frame's bytes from a raw stream.
pub async fn read_frame(stream: &mut (impl tokio::io::AsyncRead + Unpin)) -> std::io::Result<Vec<u8>> {
    use tokio::io::AsyncReadExt;
    let mut frame = vec![0u8; HEADER_SIZE];
    stream.read_exact(&mut frame).await?;
    let length = u32::from_le_bytes(frame[20..24].try_into().unwrap()) as usize;
    frame.resize(HEADER_SIZE + length, 0);
    stream.read_exact(&mut frame[HEADER_SIZE..]).await?;
    Ok(frame)
}

/// A handshake-layer frame of about 60 KB (an `Error` with a long text), which any channel parses.
pub fn bulky_frame() -> Vec<u8> {
    let message = Message::Error(ErrorMessage { code: ErrorCode::INTERNAL, message: "x".repeat(60_000) });
    MessageCodec::encode(&message, 0, 0, None, Some(HANDSHAKE_VERSION))
}

/// Writes [`bulky_frame`]s to `stream` until one write makes no progress for 500 ms (the far end stopped
/// reading) or `limit` bytes are written; returns the bytes written. Under tokio's paused clock the wait
/// costs no real time.
pub async fn flood(stream: &mut (impl tokio::io::AsyncWrite + Unpin), limit: usize) -> usize {
    use tokio::io::AsyncWriteExt;
    let frame = bulky_frame();
    let mut written = 0;
    while written < limit {
        match tokio::time::timeout(Duration::from_millis(500), stream.write_all(&frame)).await {
            Ok(Ok(())) => written += frame.len(),
            _ => break,
        }
    }
    written
}
