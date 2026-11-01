//! A Wi-Fi link end to end over loopback (§7.7 D29): the client role (`lain-link`'s `LinkDialer` over a
//! [`WiFiDialer`] holding one pairing's PSK) dials the host role: a [`WiFiListener`] holding every paired
//! iPad's PSK, feeding one `LinkAcceptor` (`Pairing::Refuse`, no primary account) as `lain-host` will. Port
//! of Swift's `WiFiLinkTests.swift`.

mod common;

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::time::Duration;

use common::{T, pattern};
use lain_link::*;
use lain_platform::fake::MemorySecretStore;
use lain_proto::*;
use lain_wifi::*;
use tokio::sync::mpsc;

fn lo() -> LinkTransport {
    LinkTransport::Network { interface: Some("lo".into()), peer_to_peer: false }
}

fn stored() -> BTreeMap<String, Vec<u8>> {
    (1..=3).map(|i| (format!("IPAD-{i}"), ChannelAuth::random_bytes::<32>().to_vec())).collect()
}

/// The host's Wi-Fi side as the daemon wires it: the listener's streams go into `lain-host`'s acceptor.
/// Swift: `WiFiHost`.
struct WiFiHost {
    secrets: MemorySecretStore,
    links: mpsc::UnboundedReceiver<AcceptedLink>,
    rejections: mpsc::UnboundedReceiver<TransportError>,
    listener: WiFiListener,
    addr: SocketAddr,
    _acceptor: tokio::task::JoinHandle<()>,
}

impl WiFiHost {
    async fn new(stored: &BTreeMap<String, Vec<u8>>) -> Self {
        let secrets = MemorySecretStore::with(stored.clone());
        let (tx, mut streams) = mpsc::channel::<Box<dyn ByteStream>>(16);
        let listener = WiFiListener::new(secrets.clone(), WiFiListenerOptions::loopback(), tx);
        listener.refresh();
        let mut status = listener.status();
        let status = tokio::time::timeout(T, status.wait_for(|s| s.port().is_some())).await.unwrap().unwrap().clone();
        assert_eq!(status, WiFiStatus::Listening { port: status.port().unwrap(), paired: stored.len() });
        let addr = SocketAddr::from(([127, 0, 0, 1], status.port().unwrap()));
        let options = AcceptorOptions { label: "test.wifi".into(), ..AcceptorOptions::default() };
        assert!(options.primary_account.is_none() && matches!(options.pairing, Pairing::Refuse));
        let (acceptor, events) = LinkAcceptor::new(secrets.clone(), options);
        let feed = tokio::spawn(async move {
            while let Some(stream) = streams.recv().await {
                acceptor.accept(stream);
            }
        });
        Self { secrets, links: events.links, rejections: events.rejections, listener, addr, _acceptor: feed }
    }

    /// One link attempt from the client with `secret`'s PSK.
    fn dialer(&self, secret: &[u8]) -> LinkDialer<WiFiDialer> {
        LinkDialer::new(WiFiDialer::new(self.addr, secret)).label("test.client.wifi")
    }

    /// One connection written by hand: TLS with `secret`'s PSK, then whatever the test sends.
    async fn raw_channel(&self, secret: &[u8], kind: ConnectionKind) -> MessageChannel {
        let stream = WiFiDialer::new(self.addr, secret).dial(kind).await.unwrap();
        MessageChannel::new(stream, format!("test.raw.{kind:?}"))
    }
}

async fn next<T>(rx: &mut mpsc::UnboundedReceiver<T>, within: Duration) -> Option<T> {
    tokio::time::timeout(within, rx.recv()).await.ok().flatten()
}

fn hello_msg(kind: ConnectionKind, token: [u8; 16], secret: Option<&[u8]>) -> Message {
    Message::ChannelHello(ChannelAuth::hello(kind, token, secret, VersionList::offered()))
}

fn err_msg(message: &str) -> Message {
    Message::Error(ErrorMessage { code: ErrorCode::AUTHENTICATION_FAILED, message: message.into() })
}

fn wifi_error(error: TransportError) -> Option<WiFiError> {
    match error {
        TransportError::Dial(e) => e.downcast_ref::<WiFiError>().cloned(),
        _ => None,
    }
}

fn sample_hello() -> Hello {
    Hello {
        device_model: "iPad16,6".into(),
        pixel_width: 2752,
        pixel_height: 2064,
        scale: 2,
        max_refresh_rate: 120,
        decode_capabilities: DecodeCapabilities::HEVC_MAIN,
        keyboard_type: KeyboardType::Ansi,
    }
}

fn sample_hello_ack() -> HelloAck {
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
        double_click_interval_ms: 400,
        key_repeat_delay_ms: 500,
        key_repeat_interval_ms: 30,
        mac_input_source: "us".into(),
        host_id: String::new(),
        host_name: String::new(),
    }
}

fn ping(id: u32, sent_at_ns: u64) -> Message {
    Message::Ping(Ping { id, sent_at_ns })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_client_dials_and_the_host_accepts_over_tls_psk() {
    let stored = stored();
    let mut host = WiFiHost::new(&stored).await;
    for (account, secret) in &stored {
        let mut link = host.dialer(secret).open(secret).await.unwrap();
        let mut accepted = next(&mut host.links, T).await.expect("a link");
        assert!(accepted.peer == *account && accepted.secret == *secret && !accepted.paired);
        assert_eq!(accepted.link.session_token, link.session_token);
        // One loopback path for both ends; every host-side channel is bound to this pairing's secret.
        assert_eq!(link.transport, lo());
        assert_eq!(accepted.link.transport, lo());
        for channel in accepted.link.channels() {
            assert!(channel.is_bound_to_secret(secret));
            assert_eq!(*channel.link_transport(), lo());
            for (other_account, other) in &stored {
                assert_eq!(channel.is_bound_to_secret(other), other_account == account);
            }
        }

        // The client sends Hello first, whichever side dialed (§7.1); the host answers HelloAck.
        link.realtime.send(&Message::Hello(sample_hello())).unwrap();
        assert_eq!(accepted.link.realtime.recv_timeout(T).await.unwrap().message, Message::Hello(sample_hello()));
        accepted.link.realtime.send(&Message::HelloAck(sample_hello_ack())).unwrap();
        let reply = LinkDialer::<WiFiDialer>::reply(&mut link, T).await.unwrap();
        assert_eq!(reply.message, Message::HelloAck(sample_hello_ack()));
        for (accepting, dialing) in accepted.link.channels_mut().into_iter().zip(link.channels_mut()) {
            accepting.send(&ping(1, 2)).unwrap();
            assert_eq!(dialing.recv_timeout(T).await.unwrap().message, ping(1, 2));
            dialing.send(&ping(3, 4)).unwrap();
            assert_eq!(accepting.recv_timeout(T).await.unwrap().message, ping(3, 4));
        }
        // A keyframe-sized frame to the client and its ack back.
        let keyframe = Message::VideoFrame(VideoFrame {
            frame_id: 1,
            config_id: 1,
            capture_time_ns: 1,
            encode_done_ns: 2,
            is_keyframe: true,
            data: pattern(1_300_000, 5),
        });
        let ack = Message::FrameAck(FrameAck { frame_id: 1, received_at_ns: 3, bytes: 1_300_000 });
        accepted.link.video.send(&keyframe).unwrap();
        assert_eq!(link.video.recv_timeout(Duration::from_secs(5)).await.unwrap().message, keyframe);
        link.video.send(&ack).unwrap();
        assert_eq!(accepted.link.video.recv_timeout(T).await.unwrap().message, ack);
        link.close();
        accepted.link.close();
    }
    assert_eq!(host.secrets.snapshot(), stored); // nothing written
    assert!(next(&mut host.rejections, Duration::from_millis(100)).await.is_none());
    assert_eq!(host.listener.listener_starts(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_wrong_secret_fails_at_tls_and_nothing_is_delivered() {
    let stored = stored();
    let mut host = WiFiHost::new(&stored).await;
    // A secret the host doesn't hold: its PSK identity is unknown there.
    let stranger = ChannelAuth::random_bytes::<32>();
    let error = host.dialer(&stranger).open(&stranger).await.unwrap_err();
    assert_eq!(wifi_error(error), Some(WiFiError::UnknownIdentity));
    // A known identity with another key.
    let known = &stored["IPAD-1"];
    let forged = WiFiPsk::from_parts(WiFiPsk::new(known).identity(), *WiFiPsk::new(&stranger).key());
    let error = LinkDialer::new(WiFiDialer::with_psk(host.addr, forged)).open(known).await.unwrap_err();
    assert_eq!(wifi_error(error), Some(WiFiError::WrongKey));
    // Neither reached the acceptor.
    assert!(next(&mut host.links, Duration::from_millis(300)).await.is_none());
    assert!(next(&mut host.rejections, Duration::from_millis(100)).await.is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pairing_hello_is_refused_even_under_a_valid_psk() {
    let stored = stored();
    let mut host = WiFiHost::new(&stored).await;
    // Wireless never pairs (D13): a zero-HMAC hello plus Pair on a connection TLS accepted.
    let secret = &stored["IPAD-1"];
    let mut realtime = host.raw_channel(secret, ConnectionKind::Realtime).await;
    realtime.send(&hello_msg(ConnectionKind::Realtime, ChannelAuth::random_bytes(), None)).unwrap();
    realtime.send(&Message::Pair(Pair { secret: ChannelAuth::random_bytes(), host_id: String::new() })).unwrap();
    assert_eq!(realtime.recv_timeout(T).await.unwrap().message, err_msg("pairing not accepted here"));
    assert!(tokio::time::timeout(Duration::from_secs(3), realtime.closed()).await.is_ok());
    // A dialer's open fails the same way.
    let pair = Pair { secret: ChannelAuth::random_bytes(), host_id: String::new() };
    assert_eq!(host.dialer(secret).open_pairing(&pair).await.err(), Some(TransportError::AuthenticationFailed));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));
    assert!(next(&mut host.links, Duration::from_millis(300)).await.is_none());
    assert_eq!(host.secrets.snapshot(), stored);
}

/// The acceptor takes on a TLS stream only the `ChannelHello` of the pairing its PSK proved.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_channel_hello_under_another_pairing_than_its_tls_key_is_refused() {
    let stored = stored();
    let mut host = WiFiHost::new(&stored).await;
    let (one, two) = (&stored["IPAD-1"], &stored["IPAD-2"]);

    // TLS under IPAD-1's key, ChannelHello under IPAD-2's secret (which the host also holds).
    async fn refusal(host: &WiFiHost, tls: &[u8], hmac: &[u8]) -> Message {
        let mut channel = host.raw_channel(tls, ConnectionKind::Realtime).await;
        channel.send(&hello_msg(ConnectionKind::Realtime, ChannelAuth::random_bytes(), Some(hmac))).unwrap();
        channel.recv_timeout(T).await.unwrap().message
    }
    assert_eq!(refusal(&host, one, two).await, err_msg("HMAC under another pairing than the TLS key"));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));
    // A dialer's open fails in place of its ChannelAccept.
    assert_eq!(
        LinkDialer::new(WiFiDialer::new(host.addr, one)).open(two).await.err(),
        Some(TransportError::AuthenticationFailed)
    );
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));

    // Under a secret the host doesn't hold at all.
    assert_eq!(refusal(&host, one, &ChannelAuth::random_bytes::<32>()).await, err_msg("bad HMAC"));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));

    // Video joining a well-bound realtime over another pairing's TLS key: refused, and the session is never
    // delivered.
    let token = ChannelAuth::random_bytes();
    let realtime = host.raw_channel(one, ConnectionKind::Realtime).await;
    let mut video = host.raw_channel(two, ConnectionKind::Video).await;
    let audio = host.raw_channel(one, ConnectionKind::Audio).await;
    realtime.send(&hello_msg(ConnectionKind::Realtime, token, Some(one))).unwrap();
    video.send(&hello_msg(ConnectionKind::Video, token, Some(one))).unwrap();
    audio.send(&hello_msg(ConnectionKind::Audio, token, Some(one))).unwrap();
    assert_eq!(video.recv_timeout(T).await.unwrap().message, err_msg("video under another pairing than its TLS key"));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));
    assert!(next(&mut host.links, Duration::from_millis(500)).await.is_none());
    assert_eq!(host.secrets.snapshot(), stored);
}
