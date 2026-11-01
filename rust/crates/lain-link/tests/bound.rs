//! Pairing-bound streams: the host's Wi-Fi acceptor, whose connections TLS-PSK already authenticated.
//! Port of Swift's `WiFiLinkTests.swift` minus the TLS itself (that is `lain-wifi`'s): the TLS layer is
//! stood in for by a [`BoundStream`] over memory, bound to the secret its PSK would have proved. The two
//! TLS-only tests (a wrong secret failing at TLS, the negotiated suite) belong to `lain-wifi`.

mod common;

use std::time::Duration;

use common::*;
use lain_link::*;
use lain_proto::*;

fn stored() -> Vec<(String, Vec<u8>)> {
    (1..=3).map(|i| (format!("IPAD-{i}"), secret())).collect()
}

fn wifi_host(stored: &[(String, Vec<u8>)]) -> Acceptor<ScriptedSecrets> {
    let entries: Vec<(&str, &[u8])> = stored.iter().map(|(a, s)| (a.as_str(), s.as_slice())).collect();
    Acceptor::new(
        ScriptedSecrets::new(&entries),
        AcceptorOptions { label: "test.wifi".into(), ..AcceptorOptions::default() },
    )
}

fn err_msg(message: &str) -> Message {
    Message::Error(ErrorMessage { code: ErrorCode::AUTHENTICATION_FAILED, message: message.into() })
}

#[tokio::test(start_paused = true)]
async fn the_client_dials_and_the_host_accepts_over_bound_streams() {
    let stored = stored();
    let mut host = wifi_host(&stored);
    for (account, secret) in &stored {
        let mut link = LinkDialer::new(host.bound_dialer(secret)).label("test.client.wifi").open(secret).await.unwrap();
        let mut accepted = next(&mut host.links, T).await.unwrap();
        assert!(accepted.peer == *account && accepted.secret == *secret && !accepted.paired);
        assert_eq!(accepted.link.session_token, link.session_token);
        // Both ends say the path their stream runs over.
        assert_eq!(link.transport, wifi_path());
        assert_eq!(accepted.link.transport, wifi_path());
        for channel in accepted.link.channels() {
            assert!(channel.is_bound_to_secret(secret));
        }

        // The client sends Hello first, whichever side dialed (§7.1); the host answers HelloAck.
        link.realtime.send(&Message::Hello(sample_hello())).unwrap();
        assert_eq!(accepted.link.realtime.recv_timeout(T).await.unwrap().message, Message::Hello(sample_hello()));
        accepted.link.realtime.send(&Message::HelloAck(sample_hello_ack())).unwrap();
        let reply = LinkDialer::<AcceptingDialer<ScriptedSecrets>>::reply(&mut link, T).await.unwrap();
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
            data: (0..1_300_000u32).map(|i| (i * 5) as u8).collect(),
        });
        let ack = Message::FrameAck(FrameAck { frame_id: 1, received_at_ns: 3, bytes: 1_300_000 });
        accepted.link.video.send(&keyframe).unwrap();
        assert_eq!(link.video.recv_timeout(Duration::from_secs(5)).await.unwrap().message, keyframe);
        link.video.send(&ack).unwrap();
        assert_eq!(accepted.link.video.recv_timeout(T).await.unwrap().message, ack);
    }
    assert_eq!(host.secrets.write_count(), 0);
    assert!(next(&mut host.rejections, Duration::from_millis(100)).await.is_none());
}

#[tokio::test(start_paused = true)]
async fn a_pairing_hello_is_refused_even_on_a_bound_stream() {
    let stored = stored();
    let mut host = wifi_host(&stored);
    // Wireless never pairs (D13): a zero-HMAC hello plus Pair on a connection TLS accepted.
    let secret = &stored[0].1;
    let mut realtime = host.raw_bound(secret);
    realtime.send(&hello_msg(ConnectionKind::Realtime, token(), None)).unwrap();
    realtime.send(&Message::Pair(Pair { secret: ChannelAuth::random_bytes(), host_id: String::new() })).unwrap();
    assert_eq!(realtime.recv_timeout(T).await.unwrap().message, err_msg("pairing not accepted here"));
    assert!(tokio::time::timeout(Duration::from_secs(3), realtime.closed()).await.is_ok());
    // A dialer's open fails the same way.
    let pair = Pair { secret: ChannelAuth::random_bytes(), host_id: String::new() };
    let error = LinkDialer::new(host.bound_dialer(secret)).open_pairing(&pair).await.err();
    assert_eq!(error, Some(TransportError::AuthenticationFailed));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));
    assert!(next(&mut host.links, Duration::from_millis(300)).await.is_none());
    assert_eq!(host.secrets.write_count(), 0);
    assert_eq!(host.secrets.inner.snapshot(), stored.into_iter().collect());
}

#[tokio::test(start_paused = true)]
async fn a_channel_hello_under_another_pairing_than_its_tls_key_is_refused() {
    let stored = stored();
    let mut host = wifi_host(&stored);
    let (one, two) = (&stored[0].1, &stored[1].1);

    // TLS under IPAD-1's key, ChannelHello under IPAD-2's secret (which the host also holds).
    async fn refusal(host: &Acceptor<ScriptedSecrets>, tls: &[u8], hmac: &[u8]) -> Message {
        let mut channel = host.raw_bound(tls);
        channel.send(&hello_msg(ConnectionKind::Realtime, token(), Some(hmac))).unwrap();
        channel.recv_timeout(T).await.unwrap().message
    }
    assert_eq!(refusal(&host, one, two).await, err_msg("HMAC under another pairing than the TLS key"));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));
    // A dialer's open fails in place of its ChannelAccept.
    assert_eq!(
        LinkDialer::new(host.bound_dialer(one)).open(two).await.err(),
        Some(TransportError::AuthenticationFailed)
    );
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));

    // Under a secret the host doesn't hold at all.
    assert_eq!(refusal(&host, one, &secret()).await, err_msg("bad HMAC"));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));

    // Video joining a well-bound realtime over another pairing's TLS key: refused, and the session is never
    // delivered.
    let token = token();
    let realtime = host.raw_bound(one);
    let mut video = host.raw_bound(two);
    let audio = host.raw_bound(one);
    realtime.send(&hello_msg(ConnectionKind::Realtime, token, Some(one))).unwrap();
    video.send(&hello_msg(ConnectionKind::Video, token, Some(one))).unwrap();
    audio.send(&hello_msg(ConnectionKind::Audio, token, Some(one))).unwrap();
    assert_eq!(video.recv_timeout(T).await.unwrap().message, err_msg("video under another pairing than its TLS key"));
    assert_eq!(next(&mut host.rejections, T).await, Some(TransportError::AuthenticationFailed));
    assert!(next(&mut host.links, Duration::from_millis(500)).await.is_none());
    assert_eq!(host.secrets.write_count(), 0);
}

/// `BoundStream` passes bytes through untouched and binds in constant time to exactly its secret.
#[tokio::test]
async fn a_bound_stream_is_bound_to_its_secret_only() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (a, b) = memory_pair();
    let mut bound = BoundStream::new(a, vec![7; 32], wifi_path());
    assert_eq!(bound.pairing_secret(), Some(&[7u8; 32][..]));
    assert_eq!(bound.link_transport(), wifi_path());
    let channel = MessageChannel::new(BoundStream::new(b, vec![7; 32], wifi_path()), "bound");
    assert!(channel.is_bound_to_secret(&[7; 32]));
    assert!(!channel.is_bound_to_secret(&[7; 31]));
    assert!(!channel.is_bound_to_secret(&[8; 32]));
    let plain = MessageChannel::new(memory_pair().0, "plain");
    assert!(plain.is_bound_to_secret(&[1; 32]), "an unbound stream can't tell: true");
    let unbound = BoundStream::unbound(memory_pair().0, wifi_path());
    assert_eq!((unbound.pairing_secret(), unbound.link_transport()), (None, wifi_path()));
    assert!(MessageChannel::new(unbound, "unbound").is_bound_to_secret(&[1; 32]));
    bound
        .write_all(&MessageCodec::encode(&hello_msg(ConnectionKind::Audio, token(), None), 0, 0, None, None))
        .await
        .unwrap();
    drop(channel);
    let mut rest = Vec::new();
    bound.read_to_end(&mut rest).await.unwrap();
}
