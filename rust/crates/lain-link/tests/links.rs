//! The dialer and acceptor roles. Ports of Swift's `LinkTests.swift` (`LinkEstablishment`, `LinkRoles`,
//! `Negotiation`, `SecretAccounts`), over memory streams with tokio's paused clock instead of loopback TCP
//! and real sleeps; plus the timeouts, mixed tokens and the acceptor's cancel and drop.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::*;
use lain_link::*;
use lain_platform::fake::MemorySecretStore;
use lain_proto::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
use tokio::time::Instant;

const HELLO_TIMEOUT: Duration = LinkAcceptor::<MemorySecretStore>::HELLO_TIMEOUT;

fn client(secrets: MemorySecretStore, accepts_pairing: bool) -> Acceptor<MemorySecretStore> {
    Acceptor::client(secrets, accepts_pairing, offered()).answering_hello()
}

async fn host_open<D: StreamDialer>(
    dialer: D,
    secrets: &MemorySecretStore,
    allow_pairing: bool,
) -> Result<(Link, Hello, bool), TransportError> {
    HostLink::open(dialer, secrets, "IPAD", allow_pairing, "", &offered()).await
}

fn host_id() -> String {
    let b: [u8; 16] = ChannelAuth::random_bytes();
    let h: String = b.iter().map(|x| format!("{x:02X}")).collect();
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

fn secret_of(store: &MemorySecretStore, account: &str) -> Option<Vec<u8>> {
    store.snapshot().get(account).cloned()
}

/// A peer written by hand: each dial hands the far end, and the connection's kind, to `serve`.
struct PeerDialer<F>(F);

impl<F: Fn(ConnectionKind, DuplexStream) + Send + Sync + 'static> StreamDialer for PeerDialer<F> {
    type Stream = DuplexStream;
    async fn dial(&self, kind: ConnectionKind) -> Result<DuplexStream, TransportError> {
        let (near, far) = memory_pair();
        (self.0)(kind, far);
        Ok(near)
    }
}

/// A peer that answers each connection's first bytes with `answer`, then closes.
fn answering(
    answer: impl Fn(ConnectionKind) -> Vec<u8> + Send + Sync + 'static,
) -> PeerDialer<impl Fn(ConnectionKind, DuplexStream)> {
    let answer = Arc::new(answer);
    PeerDialer(move |kind, mut far: DuplexStream| {
        let answer = answer.clone();
        tokio::spawn(async move {
            let mut buf = [0u8; 1024];
            let _ = far.read(&mut buf).await;
            far.write_all(&answer(kind)).await.unwrap();
            let _ = far.shutdown().await;
            // Keep the far end until the dialer is done with it.
            let _ = far.read_to_end(&mut Vec::new()).await;
        });
    })
}

fn err_msg(code: ErrorCode, message: &str) -> Message {
    Message::Error(ErrorMessage { code, message: message.into() })
}

// MARK: LinkEstablishment

#[tokio::test(start_paused = true)]
async fn the_first_connection_pairs_then_reuses_the_secret() {
    let mut client = client(store(&[]), true);
    let host_secrets = store(&[]);
    let (link, hello, paired) = host_open(client.dialer(), &host_secrets, true).await.unwrap();
    assert_eq!(hello, sample_hello());
    assert!(paired);
    let client_link = next(&mut client.links, T).await.unwrap();
    assert_eq!(client_link.link.session_token, link.session_token);
    let secret = secret_of(&host_secrets, "IPAD").unwrap();
    assert_eq!(secret_of(&client.secrets, "host"), Some(secret.clone()));
    drop(link);

    // Second session: authenticated with the stored secret, no pairing.
    let (link2, _, paired2) = host_open(client.dialer(), &host_secrets, false).await.unwrap();
    assert!(!paired2);
    assert_eq!(next(&mut client.links, T).await.unwrap().link.session_token, link2.session_token);
    assert_eq!(secret_of(&host_secrets, "IPAD"), Some(secret));
}

#[tokio::test(start_paused = true)]
async fn a_stale_secret_repairs_over_usb_only() {
    let client = client(store(&[("host", &secret())]), true);
    let stale = secret();
    assert_eq!(
        host_open(client.dialer(), &store(&[("IPAD", &stale)]), false).await.err(),
        Some(TransportError::AuthenticationFailed)
    );
    let host_secrets = store(&[("IPAD", &stale)]);
    let (_link, _, repaired) = host_open(client.dialer(), &host_secrets, true).await.unwrap();
    assert!(repaired);
    assert_ne!(secret_of(&host_secrets, "IPAD"), Some(stale));
    assert_eq!(secret_of(&host_secrets, "IPAD"), secret_of(&client.secrets, "host"));
}

#[tokio::test(start_paused = true)]
async fn no_secret_and_no_pairing_fails_before_dialing() {
    let (dialer, mut far) = MemoryDialer::new();
    assert_eq!(host_open(dialer, &store(&[]), false).await.err(), Some(TransportError::NoSecret));
    assert!(far.try_recv().is_err(), "nothing was dialed");
}

#[tokio::test(start_paused = true)]
async fn a_listener_without_pairing_rejects_pairing_requests() {
    let client = client(store(&[]), false);
    assert_eq!(host_open(client.dialer(), &store(&[]), true).await.err(), Some(TransportError::AuthenticationFailed));
    assert_eq!(secret_of(&client.secrets, "host"), None);
}

#[tokio::test(start_paused = true)]
async fn connections_that_do_not_open_with_channel_hello_are_closed() {
    let client = client(store(&[]), true);
    // Wrong first message (a handshake frame, but not ChannelHello): rejected with an Error.
    let mut wrong = client.raw();
    wrong.send(&Message::Pair(Pair { secret: ChannelAuth::random_bytes(), host_id: String::new() })).unwrap();
    let reply = wrong.recv_timeout(T).await.unwrap();
    assert_eq!(reply.message, err_msg(ErrorCode::AUTHENTICATION_FAILED, "first message was pair"));
    // Silence: closed after the hello timeout, not before.
    let silent = client.raw();
    let start = Instant::now();
    assert_eq!(tokio::time::timeout(HELLO_TIMEOUT + T, silent.closed()).await, Ok(CloseReason::PeerClosed));
    assert!(start.elapsed() >= HELLO_TIMEOUT);
}

#[tokio::test(start_paused = true)]
async fn a_forged_video_connection_is_rejected() {
    let mut client = client(store(&[("host", &[1; 32])]), true);
    let token = token();
    let mut realtime = client.raw();
    realtime.send(&hello_msg(ConnectionKind::Realtime, token, Some(&[1; 32]))).unwrap();
    let mut forged = client.raw();
    forged.send(&hello_msg(ConnectionKind::Video, token, Some(&[2; 32]))).unwrap();
    assert_eq!(
        forged.recv_timeout(T).await.unwrap().message,
        err_msg(ErrorCode::AUTHENTICATION_FAILED, "bad HMAC on video")
    );
    assert_eq!(forged.recv_timeout(T).await, Err(TransportError::Closed));
    assert!(next(&mut client.links, Duration::from_millis(300)).await.is_none());
    assert!(matches!(realtime.recv_timeout(T).await.unwrap().message, Message::ChannelAccept(_)));
}

// MARK: LinkRoles

#[tokio::test(start_paused = true)]
async fn the_acceptor_reports_which_stored_account_matched() {
    let (usb, mac_a, mac_b) = (secret(), secret(), secret());
    let (id_a, id_b) = (host_id(), host_id());
    let (account_a, account_b) = (PairingAccounts::mac(&id_a), PairingAccounts::mac(&id_b));
    let mut client = client(store(&[("host", &usb), (&account_a, &mac_a), (&account_b, &mac_b)]), true);
    for (secret, account) in [(&mac_b, &account_b), (&usb, &"host".to_string()), (&mac_a, &account_a)] {
        let (link, _, paired) = host_open(client.dialer(), &store(&[("IPAD", secret)]), false).await.unwrap();
        assert!(!paired);
        let accepted = next(&mut client.links, T).await.unwrap();
        assert!(accepted.peer == *account && accepted.secret == *secret && !accepted.paired);
        assert_eq!(accepted.link.session_token, link.session_token);
        assert_eq!(accepted.link.transport, LinkTransport::Usb);
    }

    // The host's side: no primary account, every stored iPad is a candidate.
    let (a, b) = (secret(), secret());
    let mut host = Acceptor::host(store(&[("IPAD-1", &a), ("IPAD-2", &b)]));
    let link = LinkDialer::new(host.dialer()).open(&b).await.unwrap();
    let accepted = next(&mut host.links, T).await.unwrap();
    assert!(accepted.peer == "IPAD-2" && accepted.secret == b && accepted.link.session_token == link.session_token);
}

#[tokio::test(start_paused = true)]
async fn a_wrong_secret_is_answered_then_closed() {
    let mut host = Acceptor::host(store(&[("IPAD", &secret())]));
    let mut realtime = host.raw();
    realtime.send(&hello_msg(ConnectionKind::Realtime, token(), Some(&secret()))).unwrap();
    assert_eq!(realtime.recv_timeout(T).await.unwrap().message, err_msg(ErrorCode::AUTHENTICATION_FAILED, "bad HMAC"));
    assert_eq!(realtime.recv_timeout(T).await, Err(TransportError::Closed));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));
    assert!(next(&mut host.links, Duration::from_millis(200)).await.is_none());
}

#[tokio::test(start_paused = true)]
async fn unlistable_secrets_still_authenticate_the_usb_host() {
    let secret = secret();
    let store_ = ScriptedSecrets { fails_listing: true, ..ScriptedSecrets::new(&[("host", &secret)]) };
    let mut client = Acceptor::client(store_.clone(), true, offered()).answering_hello();
    let host_secrets = store(&[("IPAD", &secret)]);
    let (_link, _, paired) = host_open(client.dialer(), &host_secrets, true).await.unwrap();
    assert!(!paired);
    assert_eq!(next(&mut client.links, T).await.unwrap().peer, "host");
    assert_eq!(store_.write_count(), 0, "no Pair ever reached the client");
    assert_eq!(secret_of(&host_secrets, "IPAD"), Some(secret));
}

#[tokio::test(start_paused = true)]
async fn an_unreadable_primary_secret_answers_internal_and_never_repairs() {
    let secret = secret();
    let store_ = ScriptedSecrets { fails_secret_read: true, ..ScriptedSecrets::new(&[("host", &secret)]) };
    let mut client = Acceptor::client(store_.clone(), true, offered()).answering_hello();

    // On the wire: Error(internal), not authenticationFailed (which would make the host re-pair).
    let mut realtime = client.raw();
    realtime.send(&hello_msg(ConnectionKind::Realtime, token(), Some(&secret))).unwrap();
    let Message::Error(e) = realtime.recv_timeout(T).await.unwrap().message else { panic!("expected Error") };
    assert_eq!(e.code, ErrorCode::INTERNAL);
    assert!(matches!(next(&mut client.rejections, T).await, Some(TransportError::Secrets(_))));

    // HostLink fails this attempt as it is: the caller retries with the same secret.
    let host_secrets = store(&[("IPAD", &secret)]);
    let error = host_open(client.dialer(), &host_secrets, true).await.err();
    assert!(matches!(error, Some(TransportError::UnexpectedMessage(_))), "{error:?}");
    assert_eq!(secret_of(&host_secrets, "IPAD"), Some(secret));
    assert_eq!(store_.write_count(), 0);
    assert!(next(&mut client.links, Duration::from_millis(200)).await.is_none());
}

#[tokio::test(start_paused = true)]
async fn an_acceptor_that_does_not_pair_refuses_pairing() {
    let store_ = ScriptedSecrets::default();
    // Like the host's Wi-Fi acceptor: wireless never pairs (D13).
    let mut host = Acceptor::host(store_.clone());
    // Refused in place of its ChannelAccept, so the dialer's open fails.
    let pair = Pair { secret: ChannelAuth::random_bytes(), host_id: String::new() };
    assert_eq!(
        LinkDialer::new(host.dialer()).open_pairing(&pair).await.err(),
        Some(TransportError::AuthenticationFailed)
    );
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));
    assert_eq!(store_.write_count(), 0);
    assert!(next(&mut host.links, Duration::from_millis(200)).await.is_none());
}

#[tokio::test(start_paused = true)]
async fn the_client_dials_and_the_host_accepts() {
    let secret = secret();
    let path = LinkTransport::Network { interface: Some("lo".into()), peer_to_peer: false };
    let options = AcceptorOptions { transport: Some(path.clone()), ..AcceptorOptions::default() };
    let mut host = Acceptor::new(store(&[("IPAD-SERIAL", &secret)]), options);
    // Through a MemoryDialer, its far ends fed to the acceptor as a listener would.
    let (dialer, mut far_ends) = MemoryDialer::new();
    let acceptor = host.acceptor.clone();
    tokio::spawn(async move {
        while let Some(connection) = far_ends.recv().await {
            acceptor.accept(connection.stream);
        }
    });
    let mut link = LinkDialer::new(dialer).label("lain.client").transport(path.clone()).open(&secret).await.unwrap();
    assert_eq!(link.transport, path);
    // The client sends Hello first, whichever side dialed (§7.1).
    link.realtime.send(&Message::Hello(sample_hello())).unwrap();

    let mut accepted = next(&mut host.links, T).await.unwrap();
    assert!(accepted.peer == "IPAD-SERIAL" && accepted.secret == secret && !accepted.paired);
    assert_eq!(accepted.link.session_token, link.session_token);
    assert_eq!(accepted.link.transport, path);
    assert_eq!(accepted.link.realtime.recv_timeout(T).await.unwrap().message, Message::Hello(sample_hello()));
    accepted.link.realtime.send(&Message::HelloAck(sample_hello_ack())).unwrap();
    let reply = LinkDialer::<MemoryDialer>::reply(&mut link, T).await.unwrap();
    assert_eq!(reply.message, Message::HelloAck(sample_hello_ack()));
    for (accepting, dialing) in accepted.link.channels_mut().into_iter().zip(link.channels_mut()) {
        accepting.send(&ping(1, 2)).unwrap();
        assert_eq!(dialing.recv_timeout(T).await.unwrap().message, ping(1, 2));
        dialing.send(&ping(3, 4)).unwrap();
        assert_eq!(accepting.recv_timeout(T).await.unwrap().message, ping(3, 4));
    }
}

#[tokio::test(start_paused = true)]
async fn video_and_audio_may_arrive_before_realtime() {
    let secret = secret();
    let mut host = Acceptor::host(store(&[("IPAD", &secret)]));
    let token = token();
    let (mut video, mut audio) = (host.raw(), host.raw());
    video.send(&hello_msg(ConnectionKind::Video, token, Some(&secret))).unwrap();
    audio.send(&hello_msg(ConnectionKind::Audio, token, Some(&secret))).unwrap();
    assert!(next(&mut host.links, Duration::from_millis(300)).await.is_none(), "both wait for their realtime");

    let mut realtime = host.raw();
    realtime.send(&hello_msg(ConnectionKind::Realtime, token, Some(&secret))).unwrap();
    let accepted = next(&mut host.links, T).await.unwrap();
    assert!(accepted.link.session_token == token && accepted.peer == "IPAD");
    // Each was answered at the session's version once it joined.
    for channel in [&mut realtime, &mut video, &mut audio] {
        let Message::ChannelAccept(a) = channel.recv_timeout(T).await.unwrap().message else {
            panic!("no ChannelAccept")
        };
        assert_eq!(a.chosen, NEWEST_VERSION);
        channel.set_version(a.chosen);
    }
    accepted.link.video.send(&ping(7, 0)).unwrap();
    assert_eq!(video.recv_timeout(T).await.unwrap().message, ping(7, 0));
}

#[tokio::test(start_paused = true)]
async fn a_late_join_for_a_delivered_session_is_closed() {
    let secret = secret();
    let mut host = Acceptor::host(store(&[("IPAD", &secret)]));
    let mut link = LinkDialer::new(host.dialer()).open(&secret).await.unwrap();
    let accepted = next(&mut host.links, T).await.unwrap();

    // Another video connection for the delivered session: closed at once, and the delivered one stays.
    let late = host.raw();
    late.send(&hello_msg(ConnectionKind::Video, link.session_token, Some(&secret))).unwrap();
    assert!(tokio::time::timeout(Duration::from_secs(1), late.closed()).await.is_ok(), "well before the hello timeout");
    assert!(next(&mut host.links, Duration::from_millis(200)).await.is_none());
    accepted.link.video.send(&ping(3, 0)).unwrap();
    assert_eq!(link.video.recv_timeout(T).await.unwrap().message, ping(3, 0));
}

#[tokio::test(start_paused = true)]
async fn a_session_whose_video_and_audio_never_come_is_dropped() {
    let secret = secret();
    let mut host = Acceptor::host(store(&[("IPAD", &secret)]));
    let token = token();
    let realtime = host.raw();
    realtime.send(&hello_msg(ConnectionKind::Realtime, token, Some(&secret))).unwrap();
    assert!(tokio::time::timeout(Duration::from_secs(1), realtime.closed()).await.is_err(), "accepted; waiting");
    assert!(tokio::time::timeout(HELLO_TIMEOUT + T, realtime.closed()).await.is_ok());

    // A join after the drop is closed at once.
    let video = host.raw();
    video.send(&hello_msg(ConnectionKind::Video, token, Some(&secret))).unwrap();
    assert!(tokio::time::timeout(Duration::from_secs(1), video.closed()).await.is_ok());
    assert!(next(&mut host.links, Duration::from_millis(100)).await.is_none());
}

/// Mixed tokens: a video connection under another session's token never completes this one, and both it
/// (an orphan whose realtime never comes) and the incomplete session are closed after the hello timeout.
#[tokio::test(start_paused = true)]
async fn mixed_tokens_never_make_a_link() {
    let secret = secret();
    let mut host = Acceptor::host(store(&[("IPAD", &secret)]));
    let (a, b) = (token(), token());
    let (mut realtime, video, mut audio) = (host.raw(), host.raw(), host.raw());
    realtime.send(&hello_msg(ConnectionKind::Realtime, a, Some(&secret))).unwrap();
    video.send(&hello_msg(ConnectionKind::Video, b, Some(&secret))).unwrap();
    audio.send(&hello_msg(ConnectionKind::Audio, a, Some(&secret))).unwrap();
    assert!(matches!(realtime.recv_timeout(T).await.unwrap().message, Message::ChannelAccept(_)));
    assert!(matches!(audio.recv_timeout(T).await.unwrap().message, Message::ChannelAccept(_)));
    let start = Instant::now();
    for channel in [&realtime, &video, &audio] {
        assert!(tokio::time::timeout(HELLO_TIMEOUT + T, channel.closed()).await.is_ok());
    }
    assert!(start.elapsed() >= HELLO_TIMEOUT - Duration::from_millis(500));
    assert!(next(&mut host.links, Duration::from_millis(100)).await.is_none());
    // An orphan is closed without an answer.
    let mut orphan = host.raw();
    orphan.send(&hello_msg(ConnectionKind::Audio, token(), Some(&secret))).unwrap();
    assert_eq!(orphan.recv_timeout(HELLO_TIMEOUT + T).await, Err(TransportError::Closed));
}

#[tokio::test(start_paused = true)]
async fn cancel_closes_only_what_was_not_delivered() {
    let secret = secret();
    let mut host = Acceptor::host(store(&[("IPAD", &secret)]));
    let mut link = LinkDialer::new(host.dialer()).open(&secret).await.unwrap();
    let accepted = next(&mut host.links, T).await.unwrap();
    let pending = host.raw();
    pending.send(&hello_msg(ConnectionKind::Realtime, token(), Some(&secret))).unwrap();
    let handshaking = host.raw();
    assert!(tokio::time::timeout(Duration::from_millis(300), pending.closed()).await.is_err());

    host.acceptor.cancel();
    assert!(host.acceptor.is_cancelled());
    assert!(tokio::time::timeout(Duration::from_secs(1), pending.closed()).await.is_ok());
    assert!(tokio::time::timeout(Duration::from_secs(1), handshaking.closed()).await.is_ok());
    // The delivered link is the consumer's.
    accepted.link.realtime.send(&ping(5, 0)).unwrap();
    assert_eq!(link.realtime.recv_timeout(T).await.unwrap().message, ping(5, 0));
    // A connection after the cancel is closed at once.
    let after = host.raw();
    assert!(tokio::time::timeout(Duration::from_millis(100), after.closed()).await.is_ok());
}

#[tokio::test(start_paused = true)]
async fn dropping_the_acceptor_closes_everything_undelivered_and_ends_its_events() {
    let secret = secret();
    let Acceptor { acceptor, mut links, mut rejections, .. } = Acceptor::host(store(&[("IPAD", &secret)]));
    let dialer = AcceptingDialer { acceptor: acceptor.clone(), bind: None };
    let waiting = MessageChannel::new(dialer.connect(), "waiting");
    waiting.send(&hello_msg(ConnectionKind::Video, token(), Some(&secret))).unwrap();
    let silent = MessageChannel::new(dialer.connect(), "silent");
    drop(dialer);
    tokio::time::sleep(Duration::from_millis(10)).await;
    drop(acceptor);
    for channel in [&waiting, &silent] {
        assert!(tokio::time::timeout(Duration::from_millis(100), channel.closed()).await.is_ok());
    }
    // Every task let go of the acceptor: both event streams end.
    assert!(tokio::time::timeout(Duration::from_millis(100), links.recv()).await.unwrap().is_none());
    assert!(tokio::time::timeout(Duration::from_millis(100), rejections.recv()).await.unwrap().is_none());
}

#[tokio::test(start_paused = true)]
async fn pairing_stores_the_secret_for_usb_and_for_wifi_together() {
    let id = host_id();
    let mut client = client(store(&[]), true);
    let host_secrets = store(&[]);
    let (_link, _, paired) =
        HostLink::open(client.dialer(), &host_secrets, "IPAD", true, &id, &offered()).await.unwrap();
    assert!(paired);
    let secret = secret_of(&host_secrets, "IPAD").unwrap();
    let expected: std::collections::BTreeMap<_, _> =
        [("host".to_string(), secret.clone()), (PairingAccounts::mac(&id), secret.clone())].into();
    assert_eq!(client.secrets.snapshot(), expected);
    let accepted = next(&mut client.links, T).await.unwrap();
    assert!(accepted.paired && accepted.peer == "host" && accepted.secret == secret);

    // A malformed host id never becomes an account: USB only.
    let other = self::client(store(&[]), true);
    let (_link2, _, _) =
        HostLink::open(other.dialer(), &store(&[]), "IPAD", true, &id.to_lowercase(), &offered()).await.unwrap();
    assert_eq!(other.secrets.snapshot().keys().collect::<Vec<_>>(), ["host"]);
}

#[tokio::test(start_paused = true)]
async fn a_legacy_peer_is_told_why_in_its_own_framing() {
    let mut client = client(store(&[]), true);
    // A v2 host's first frame: a pairing ChannelHello in a v2 header.
    let mut v2 = client.raw_bytes();
    v2.write_all(&legacy_channel_hello(2)).await.unwrap();
    let mut answer = Vec::new();
    v2.read_to_end(&mut answer).await.unwrap();
    assert!(answer.len() > HEADER_SIZE);
    assert_eq!(answer[2], 2, "framed in v2…");
    let Message::Error(e) = MessageCodec::decode(&reframed(answer.clone(), HANDSHAKE_VERSION)).unwrap().message else {
        panic!("not an Error")
    };
    assert_eq!(e.code, ErrorCode::VERSION_MISMATCH, "…with the Error layout v2 already had");
    assert_eq!(next(&mut client.rejections, T).await, Some(TransportError::VersionMismatch { remote: 2 }));
    assert!(client.secrets.snapshot().is_empty());
    assert!(client.links.try_recv().is_err());

    // A dialer that gets such an answer (here from a peer on v2) says so, instead of just "closed".
    let peer = answering(move |_| answer.clone());
    assert_eq!(host_open(peer, &store(&[]), true).await.err(), Some(TransportError::VersionMismatch { remote: 2 }));
}

#[tokio::test(start_paused = true)]
async fn a_legacy_acceptors_answer_in_our_framing_is_a_version_mismatch() {
    // A v2 acceptor answers our handshake frame with Error(versionMismatch) framed in our header's version
    // (it can't read our ChannelHello).
    let peer = answering(|_| MessageCodec::legacy_version_mismatch(HANDSHAKE_VERSION, "v2 here", 0, 0));
    assert_eq!(LinkDialer::new(peer).open(&secret()).await.err(), Some(TransportError::VersionMismatch { remote: 0 }));
}

// MARK: Timeouts

#[tokio::test(start_paused = true)]
async fn an_acceptor_that_never_answers_times_the_dialer_out() {
    let silent = PeerDialer(|_, far: DuplexStream| {
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_secs(60)).await;
            drop(far);
        });
    });
    let start = Instant::now();
    assert_eq!(LinkDialer::new(silent).open(&secret()).await.err(), Some(TransportError::Timeout));
    let waited = start.elapsed();
    assert!(waited >= HostLink::HANDSHAKE_TIMEOUT && waited < HostLink::HANDSHAKE_TIMEOUT + Duration::from_secs(1));
    assert_eq!(LinkDialer::<MemoryDialer>::ACCEPT_TIMEOUT, Duration::from_secs(5));
}

#[tokio::test(start_paused = true)]
async fn a_client_that_never_says_hello_times_the_host_out_and_nothing_is_stored() {
    // The client's acceptor, but nobody answers Hello on its links.
    let mut client = Acceptor::client(store(&[]), true, offered());
    let host_secrets = store(&[]);
    let start = Instant::now();
    assert_eq!(host_open(client.dialer(), &host_secrets, true).await.err(), Some(TransportError::Timeout));
    assert!(start.elapsed() >= HostLink::HANDSHAKE_TIMEOUT);
    assert!(host_secrets.snapshot().is_empty(), "a pairing is stored only once Hello arrives");
    // The link the client got was closed by the host's failure.
    let accepted = next(&mut client.links, T).await.unwrap();
    assert!(tokio::time::timeout(T, accepted.link.realtime.closed()).await.is_ok());
}

#[tokio::test(start_paused = true)]
async fn a_pairing_connection_must_send_pair_within_the_hello_timeout() {
    let client = client(store(&[]), true);
    let mut realtime = client.raw();
    realtime.send(&hello_msg(ConnectionKind::Realtime, token(), None)).unwrap();
    let start = Instant::now();
    assert_eq!(realtime.recv_timeout(HELLO_TIMEOUT + T).await, Err(TransportError::Closed));
    assert!(start.elapsed() >= HELLO_TIMEOUT);
    assert!(client.secrets.snapshot().is_empty());
}

// MARK: Negotiation

#[tokio::test(start_paused = true)]
async fn the_highest_common_version_wins() {
    let cases = [
        (versions(&[(4, 1), (5, 1)]), versions(&[(4, 1), (5, 1)]), 5),
        (versions(&[(4, 1)]), versions(&[(4, 1), (5, 1)]), 4), // an older dialer
        (versions(&[(4, 1), (5, 1)]), versions(&[(4, 1)]), 4), // an older acceptor
        (versions(&[(4, 1), (5, 1)]), versions(&[(4, 1), (5, 2)]), 4), // two builds of v5: v4 is common
        (versions(&[(5, 1), (6, 1)]), versions(&[(4, 1), (5, 1)]), 5),
    ];
    for (dialer_versions, acceptor_versions, expected) in cases {
        let mut client = Acceptor::client(store(&[]), true, acceptor_versions.clone()).answering_hello();
        let pair = Pair { secret: ChannelAuth::random_bytes(), host_id: String::new() };
        let mut link =
            LinkDialer::new(client.dialer()).versions(dialer_versions.clone()).open_pairing(&pair).await.unwrap();
        assert_eq!(link.version, expected);
        assert_eq!(link.peer_versions.as_ref(), Some(&acceptor_versions));
        assert!(link.channels().iter().all(|c| c.version() == Some(expected)));
        let accepted = next(&mut client.links, T).await.unwrap();
        assert_eq!(accepted.link.version, expected);
        assert_eq!(accepted.link.peer_versions.as_ref(), Some(&dialer_versions));
        assert!(accepted.link.channels().iter().all(|c| c.version() == Some(expected)));
        // The session's first message arrives framed in the agreed version.
        let hello = link.realtime.recv_timeout(T).await.unwrap();
        assert_eq!((hello.header.version, hello.message), (expected, Message::Hello(sample_hello())));
    }
}

#[tokio::test(start_paused = true)]
async fn no_common_version_is_reported_on_both_sides_and_nothing_pairs() {
    let (dialing, accepting) = (versions(&[(3, 1), (4, 1)]), versions(&[(5, 1), (6, 1)]));
    let mut client = Acceptor::client(store(&[]), true, accepting.clone()).answering_hello();
    let pair = Pair { secret: ChannelAuth::random_bytes(), host_id: String::new() };
    let error = LinkDialer::new(client.dialer()).versions(dialing.clone()).open_pairing(&pair).await.err().unwrap();
    assert_eq!(error, TransportError::NoCommonVersion { local: dialing.clone(), peer: accepting.clone() });
    assert_eq!(
        next(&mut client.rejections, T).await,
        Some(TransportError::NoCommonVersion { local: accepting, peer: dialing.clone() })
    );
    assert!(client.secrets.snapshot().is_empty(), "a pairing waits for a version");
    assert!(client.links.try_recv().is_err());
    assert_eq!(VersionGap::from_error(&error, &dialing), Some(VersionGap::PeerNewer { peer: "protocol v5–v6".into() }));
}

#[test]
fn gaps_name_the_side_to_update() {
    let v34 = versions(&[(3, 1), (4, 1)]);
    let older = |p: &str| VersionGap::PeerOlder { peer: p.into() };
    let newer = |p: &str| VersionGap::PeerNewer { peer: p.into() };
    assert_eq!(VersionGap::from_lists(&versions(&[(5, 1), (6, 1)]), &v34), older("protocol v3–v4"));
    assert_eq!(VersionGap::from_lists(&v34, &versions(&[(5, 1)])), newer("protocol v5"));
    assert_eq!(
        VersionGap::from_lists(&versions(&[(4, 1)]), &versions(&[(4, 2)])),
        VersionGap::DifferentBuilds { version: 4 }
    );
    assert_eq!(
        VersionGap::from_error(&TransportError::VersionMismatch { remote: 2 }, &offered()),
        Some(older("protocol v2"))
    );
    assert_eq!(
        VersionGap::from_error(&TransportError::VersionMismatch { remote: 0 }, &offered()),
        Some(older("a protocol from before v3"))
    );
    assert_eq!(VersionGap::from_error(&TransportError::Closed, &offered()), None);
    assert_eq!(VersionGap::from_advertised(&v34, &[4, 5]), None, "shared: the handshake decides");
    assert_eq!(VersionGap::from_advertised(&v34, &[2]), Some(older("protocol v2")));
    assert_eq!(VersionGap::from_advertised(&v34, &[5, 6]), Some(newer("protocol v5–v6")));
    assert_eq!(VersionGap::from_advertised(&v34, &[]), Some(older("an unknown protocol")));
    // A legacy frame from a newer major version (not the handshake's) says to update this side.
    assert_eq!(VersionGap::legacy(9, &v34), newer("protocol v9"));
    assert_eq!(VersionGap::legacy(HANDSHAKE_VERSION, &v34), older("protocol v255"));
}

#[tokio::test(start_paused = true)]
async fn an_accept_that_isnt_the_highest_common_version_fails_the_link() {
    // A peer (or a bug) that picks a lower version than both sides share.
    let accept = Message::ChannelAccept(ChannelAccept { chosen: 3, versions: versions(&[(3, 1), (4, 1)]) });
    let peer = answering(move |_| MessageCodec::encode(&accept, 0, 0, None, None));
    let error = LinkDialer::new(peer).versions(versions(&[(3, 1), (4, 1)])).open(&secret()).await.err();
    assert_eq!(error, Some(TransportError::UnexpectedMessage("ChannelAccept chose v3 of v3–v4, offered v3–v4".into())));
}

#[tokio::test(start_paused = true)]
async fn connections_answered_in_different_versions_fail_the_link() {
    let peer = answering(|kind| {
        let accept = match kind {
            ConnectionKind::Realtime => ChannelAccept { chosen: 4, versions: versions(&[(3, 1), (4, 1)]) },
            _ => ChannelAccept { chosen: 3, versions: versions(&[(3, 1)]) },
        };
        MessageCodec::encode(&Message::ChannelAccept(accept), 0, 0, None, None)
    });
    let error = LinkDialer::new(peer).versions(versions(&[(3, 1), (4, 1)])).open(&secret()).await.err();
    assert_eq!(error, Some(TransportError::UnexpectedMessage("connections answered v4 and v3".into())));
}

#[tokio::test(start_paused = true)]
async fn video_must_offer_what_its_realtime_offered() {
    let secret = secret();
    let v34 = versions(&[(3, 1), (4, 1)]);
    let mut client = Acceptor::client(store(&[("host", &secret)]), true, v34.clone()).answering_hello();
    let token = token();
    let mut realtime = client.raw();
    realtime
        .send(&Message::ChannelHello(ChannelAuth::hello(ConnectionKind::Realtime, token, Some(&secret), &v34)))
        .unwrap();
    assert_eq!(
        realtime.recv_timeout(T).await.unwrap().message,
        Message::ChannelAccept(ChannelAccept { chosen: 4, versions: v34.clone() })
    );
    let mut video = client.raw();
    let v3 = versions(&[(3, 1)]);
    video.send(&Message::ChannelHello(ChannelAuth::hello(ConnectionKind::Video, token, Some(&secret), &v3))).unwrap();
    assert_eq!(
        video.recv_timeout(T).await.unwrap().message,
        err_msg(ErrorCode::AUTHENTICATION_FAILED, "video offers v3, its realtime v3–v4")
    );
    assert_eq!(
        next(&mut client.rejections, T).await,
        Some(TransportError::UnexpectedMessage("connections offer different versions".into()))
    );
}

// MARK: Refusals and the acceptor's state, pinned (Swift: `Link.swift` `handlePair`, `join`, `finished`)

#[tokio::test(start_paused = true)]
async fn a_pairing_hello_followed_by_anything_but_pair_is_refused() {
    let mut client = Acceptor::client(store(&[]), true, offered());
    let mut raw = client.raw();
    raw.send(&hello_msg(ConnectionKind::Realtime, token(), None)).unwrap();
    raw.send(&hello_msg(ConnectionKind::Realtime, token(), None)).unwrap();
    let reply = raw.recv_timeout(T).await.unwrap();
    assert_eq!(reply.header.version, HANDSHAKE_VERSION);
    assert_eq!(reply.message, err_msg(ErrorCode::AUTHENTICATION_FAILED, "expected Pair, got channelHello"));
    assert_eq!(raw.recv_timeout(T).await, Err(TransportError::Closed));
    assert_eq!(next(&mut client.rejections, T).await, Some(TransportError::UnexpectedMessage("channelHello".into())));
    assert!(client.secrets.snapshot().is_empty());
}

#[tokio::test(start_paused = true)]
async fn a_pairing_hello_without_pair_closes_silently_at_the_hello_timeout() {
    let mut client = Acceptor::client(store(&[]), true, offered());
    let mut raw = client.raw();
    raw.send(&hello_msg(ConnectionKind::Realtime, token(), None)).unwrap();
    let start = Instant::now();
    // No Error frame: the first thing received is the close.
    assert_eq!(raw.recv_timeout(Duration::from_secs(10)).await, Err(TransportError::Closed));
    assert!(start.elapsed() >= HELLO_TIMEOUT);
    assert!(next(&mut client.rejections, Duration::from_millis(100)).await.is_none());
}

/// A store failure answers `Error(internal)`, which HostLink fails on as it is: it neither re-pairs nor
/// stores.
#[tokio::test(start_paused = true)]
async fn a_pairing_the_client_cannot_store_answers_internal_and_the_host_stores_nothing() {
    let store_ = ScriptedSecrets { fails_store: true, ..ScriptedSecrets::default() };
    let mut client = Acceptor::client(store_.clone(), true, offered()).answering_hello();
    let mut raw = client.raw();
    raw.send(&hello_msg(ConnectionKind::Realtime, token(), None)).unwrap();
    raw.send(&Message::Pair(Pair { secret: ChannelAuth::random_bytes(), host_id: String::new() })).unwrap();
    assert_eq!(
        raw.recv_timeout(T).await.unwrap().message,
        err_msg(ErrorCode::INTERNAL, "could not store pairing secret")
    );
    assert_eq!(
        next(&mut client.rejections, T).await,
        Some(TransportError::Secrets(lain_platform::PlatformError::Denied("scripted store failure".into())))
    );

    let host_secrets = store(&[]);
    assert_eq!(
        host_open(client.dialer(), &host_secrets, true).await.err(),
        Some(TransportError::UnexpectedMessage("Error(internal): could not store pairing secret".into()))
    );
    assert!(host_secrets.snapshot().is_empty());
    assert!(store_.inner.snapshot().is_empty());
    assert!(next(&mut client.links, Duration::from_millis(200)).await.is_none());
}

/// A secret store that never answers (a locked keyring's prompt) holds a connection no longer than the
/// hello timeout, in either role: it is answered `Error(internal)` (retry, don't re-pair), reported, and
/// nothing stays parked however often the dialer retries.
#[tokio::test(start_paused = true)]
async fn a_secret_store_that_never_answers_is_given_up_at_the_hello_timeout() {
    let secret = secret();
    let hung = |initial: &[(&str, &[u8])]| ScriptedSecrets { hangs: true, ..ScriptedSecrets::new(initial) };
    let acceptors =
        [Acceptor::host(hung(&[("IPAD", &secret)])), Acceptor::client(hung(&[("host", &secret)]), true, offered())];
    for mut acceptor in acceptors {
        let mut raws = Vec::new();
        for _ in 0..5 {
            let raw = acceptor.raw();
            raw.send(&hello_msg(ConnectionKind::Realtime, token(), Some(&secret))).unwrap();
            raws.push(raw);
        }
        let start = Instant::now();
        for raw in &mut raws {
            assert_eq!(
                raw.recv_timeout(HELLO_TIMEOUT + T).await.unwrap().message,
                err_msg(ErrorCode::INTERNAL, "could not read the pairing secrets")
            );
            assert_eq!(raw.recv_timeout(T).await, Err(TransportError::Closed));
        }
        assert!(start.elapsed() >= HELLO_TIMEOUT && start.elapsed() < HELLO_TIMEOUT + T);
        for _ in 0..5 {
            let rejection = next(&mut acceptor.rejections, T).await;
            assert!(
                matches!(rejection, Some(TransportError::Secrets(lain_platform::PlatformError::Unavailable(_)))),
                "{rejection:?}"
            );
        }
        assert_eq!(acceptor.secrets.in_flight(), 0, "no read outlives its connection's hello timeout");
    }
}

#[tokio::test(start_paused = true)]
async fn a_pairing_store_that_never_finishes_answers_internal_at_the_hello_timeout() {
    let store_ = ScriptedSecrets { hangs: true, ..ScriptedSecrets::default() };
    let mut client = Acceptor::client(store_.clone(), true, offered()).answering_hello();
    let host_secrets = store(&[]);
    let start = Instant::now();
    assert_eq!(
        host_open(client.dialer(), &host_secrets, true).await.err(),
        Some(TransportError::UnexpectedMessage("Error(internal): could not store pairing secret".into()))
    );
    assert!(start.elapsed() >= HELLO_TIMEOUT);
    assert!(matches!(next(&mut client.rejections, T).await, Some(TransportError::Secrets(_))));
    assert_eq!(store_.in_flight(), 0);
    assert!(host_secrets.snapshot().is_empty());
}

/// A video connection under an unknown token waits, unauthenticated, for its realtime; whatever it sends
/// meanwhile is held only up to `INBOUND_BUFFER`, then its writes wait. (Swift buffers without bound.)
#[tokio::test(start_paused = true)]
async fn a_waiting_connection_cannot_make_the_acceptor_buffer_without_bound() {
    let host = Acceptor::host(store(&[("IPAD", &secret())]));
    let mut raw = host.raw_bytes();
    let hello = hello_msg(ConnectionKind::Video, token(), Some(&secret()));
    raw.write_all(&MessageCodec::encode(&hello, 0, 0, None, None)).await.unwrap();
    let written = flood(&mut raw, 3 * INBOUND_BUFFER).await;
    let slack = 2 * bulky_frame().len() + 64 * 1024 + MEMORY_STREAM_BUFFER;
    assert!(written < INBOUND_BUFFER + slack, "an unauthenticated peer pushed {written} bytes that nobody reads");
}

#[tokio::test(start_paused = true)]
async fn a_replaced_video_connection_is_closed() {
    let secret = secret();
    let mut host = Acceptor::host(store(&[("IPAD", &secret)]));
    let token = token();
    let mut realtime = host.raw();
    realtime.send(&hello_msg(ConnectionKind::Realtime, token, Some(&secret))).unwrap();
    assert!(matches!(realtime.recv_timeout(T).await.unwrap().message, Message::ChannelAccept(_)));
    let mut first = host.raw();
    first.send(&hello_msg(ConnectionKind::Video, token, Some(&secret))).unwrap();
    assert!(matches!(first.recv_timeout(T).await.unwrap().message, Message::ChannelAccept(_)));
    let mut second = host.raw();
    second.send(&hello_msg(ConnectionKind::Video, token, Some(&secret))).unwrap();
    assert!(matches!(second.recv_timeout(T).await.unwrap().message, Message::ChannelAccept(_)));
    assert!(tokio::time::timeout(Duration::from_millis(100), first.closed()).await.is_ok(), "the first is closed");
    let audio = host.raw();
    audio.send(&hello_msg(ConnectionKind::Audio, token, Some(&secret))).unwrap();
    let accepted = next(&mut host.links, T).await.unwrap();
    // The link's video is the second connection.
    second.set_version(accepted.link.version);
    accepted.link.video.send(&ping(9, 0)).unwrap();
    assert_eq!(second.recv_timeout(T).await.unwrap().message, ping(9, 0));
}

#[tokio::test(start_paused = true)]
async fn a_second_realtime_for_one_session_is_closed() {
    let secret = secret();
    let host = Acceptor::host(store(&[("IPAD", &secret)]));
    let token = token();
    let mut first = host.raw();
    first.send(&hello_msg(ConnectionKind::Realtime, token, Some(&secret))).unwrap();
    assert!(matches!(first.recv_timeout(T).await.unwrap().message, Message::ChannelAccept(_)));
    let mut second = host.raw();
    second.send(&hello_msg(ConnectionKind::Realtime, token, Some(&secret))).unwrap();
    assert_eq!(second.recv_timeout(T).await, Err(TransportError::Closed), "closed without an answer");
    assert!(first.close_reason().is_none(), "the first stays");
}

/// The newest 64 finished tokens close a late join at once; an older one waits out the hello timeout like
/// any orphan.
#[tokio::test(start_paused = true)]
async fn sixty_four_finished_tokens_are_remembered() {
    let secret = secret();
    let mut host = Acceptor::host(store(&[("IPAD", &secret)]));
    let mut tokens = Vec::new();
    for _ in 0..65 {
        let link = LinkDialer::new(host.dialer()).open(&secret).await.unwrap();
        next(&mut host.links, T).await.unwrap();
        tokens.push(link.session_token);
    }
    let remembered = host.raw();
    remembered.send(&hello_msg(ConnectionKind::Video, tokens[1], Some(&secret))).unwrap();
    assert!(tokio::time::timeout(Duration::from_millis(100), remembered.closed()).await.is_ok());
    let evicted = host.raw();
    evicted.send(&hello_msg(ConnectionKind::Video, tokens[0], Some(&secret))).unwrap();
    assert!(tokio::time::timeout(Duration::from_secs(1), evicted.closed()).await.is_err(), "waits");
    assert!(tokio::time::timeout(HELLO_TIMEOUT, evicted.closed()).await.is_ok());
}

// MARK: SecretAccounts

#[test]
fn account_names() {
    let id = host_id();
    assert_eq!(PairingAccounts::USB_HOST, "host");
    assert_eq!(PairingAccounts::mac(&id), format!("mac:{id}"));
    assert_eq!(PairingAccounts::host_id_from_account(&PairingAccounts::mac(&id)), Some(id.as_str()));
    assert_eq!(PairingAccounts::host_id_from_account(PairingAccounts::USB_HOST), None);
    assert_eq!(PairingAccounts::host_id_from_account(&PairingAccounts::mac(&id.to_lowercase())), None);
    assert!(PairingAccounts::is_canonical_host_id(&id));
    assert!(PairingAccounts::is_canonical_host_id(ProtocolSamples::HOST_ID));
    for bad in [
        id.to_lowercase(),
        String::new(),
        format!("{{{id}}}"),
        format!("{id} "),
        format!("mac:{id}"),
        id.replace('-', ""),
    ] {
        assert!(!PairingAccounts::is_canonical_host_id(&bad), "{bad}");
    }
}
