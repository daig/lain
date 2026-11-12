//! `MessageChannel` and the streams under it. Ports of Swift's `StreamTests.swift` (`Streams`, `Channels`,
//! `ChannelVersions`, `Secrets`) and `LinkTests.swift`'s `ChannelVersionMismatch`, plus the Rust channel's
//! own guarantees (one close reason, send order, nothing outliving a close).

mod common;

use std::time::Duration;

use common::*;
use futures::StreamExt;
use lain_link::*;
use lain_proto::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Two channels over memory, both at the newest version. Swift: `Channels.pair()`.
fn pair() -> (MessageChannel, MessageChannel) {
    let (a, b) = memory_pair();
    let options = |label: &str| ChannelOptions { version: Some(NEWEST_VERSION), ..ChannelOptions::new(label) };
    (MessageChannel::with_options(a, options("a")), MessageChannel::with_options(b, options("b")))
}

fn at(stream: impl ByteStream, version: Option<u8>) -> MessageChannel {
    MessageChannel::with_options(stream, ChannelOptions { version, ..ChannelOptions::new("t") })
}

// MARK: Channels

#[tokio::test(start_paused = true)]
async fn buffers_until_read_and_counts_sequence() {
    let (a, mut b) = pair();
    for i in 0..3 {
        a.send(&ping(i, 0)).unwrap();
    }
    tokio::time::sleep(Duration::from_millis(20)).await;
    for i in 0..3 {
        let env = b.recv_timeout(T).await.unwrap();
        assert_eq!(env.message, ping(i, 0));
        assert_eq!(env.header.sequence, i);
    }
}

#[tokio::test(start_paused = true)]
async fn receive_takes_exactly_one_and_times_out() {
    let (a, mut b) = pair();
    a.send(&ping(1, 0)).unwrap();
    a.send(&Message::ReleaseAll(ReleaseAll { reason: ReleaseReason::FocusLost })).unwrap();
    assert_eq!(b.recv_timeout(T).await.unwrap().message, ping(1, 0));
    assert_eq!(
        b.recv_timeout(T).await.unwrap().message,
        Message::ReleaseAll(ReleaseAll { reason: ReleaseReason::FocusLost })
    );
    assert_eq!(b.recv_timeout(Duration::from_millis(50)).await, Err(TransportError::Timeout));
    // A timeout leaves the channel open.
    a.send(&ping(2, 0)).unwrap();
    assert_eq!(b.recv_timeout(T).await.unwrap().message, ping(2, 0));
}

#[tokio::test(start_paused = true)]
async fn garbage_closes_the_channel() {
    let (mut a, b) = memory_pair();
    let mut cb = MessageChannel::new(b, "b");
    a.write_all(&[0xEE; 64]).await.unwrap();
    assert_eq!(cb.recv_timeout(T).await, Err(TransportError::Closed));
    assert_eq!(cb.close_reason(), Some(CloseReason::Malformed(ProtocolError::BadMagic(0xEEEE))));
    // The peer sees the close.
    let mut rest = Vec::new();
    assert_eq!(a.read_to_end(&mut rest).await.unwrap(), 0);
}

#[tokio::test(start_paused = true)]
async fn messages_received_before_a_close_are_still_delivered() {
    let (a, mut b) = pair();
    a.send(&ping(1, 0)).unwrap();
    a.send(&ping(2, 0)).unwrap();
    a.close();
    assert_eq!(b.closed().await, CloseReason::PeerClosed);
    assert_eq!(b.recv().await.unwrap().message, ping(1, 0));
    assert_eq!(b.recv().await.unwrap().message, ping(2, 0));
    assert_eq!(b.recv().await, Err(TransportError::Closed));
}

#[tokio::test(start_paused = true)]
async fn one_close_reason_whatever_the_cause() {
    // close(): the first cause wins; the peer sees EOF.
    let (a, b) = pair();
    a.close();
    a.close();
    assert_eq!(a.closed().await, CloseReason::Local);
    assert_eq!(b.closed().await, CloseReason::PeerClosed);
    assert_eq!(a.send(&ping(1, 0)), Err(SendError::Closed));

    // Dropping the channel, and a sender's close.
    let (a, b) = pair();
    let sender = a.sender();
    drop(a);
    assert_eq!(sender.closed().await, CloseReason::Local);
    assert_eq!(sender.send(&ping(1, 0)), Err(SendError::Closed));
    assert_eq!(b.closed().await, CloseReason::PeerClosed);
    let (a, b) = pair();
    b.sender().close();
    assert_eq!(a.closed().await, CloseReason::PeerClosed);
    assert_eq!(b.close_reason(), Some(CloseReason::Local));

    // A protocol error (found when the frame is read), and an EOF from a raw peer.
    let (mut raw, b) = memory_pair();
    let mut b = MessageChannel::new(b, "b");
    raw.write_all(&MessageCodec::encode(&ping(1, 0), 0, 0, None, None)).await.unwrap();
    assert_eq!(b.recv().await, Err(TransportError::Closed));
    assert_eq!(b.closed().await, CloseReason::WrongVersion("a ping frame in v5 on a channel at the handshake".into()));
    let mut rest = Vec::new();
    assert_eq!(raw.read_to_end(&mut rest).await.unwrap(), 0, "the peer sees the close");
    let (raw, b) = memory_pair();
    let b = MessageChannel::new(b, "b");
    drop(raw);
    assert_eq!(b.closed().await, CloseReason::PeerClosed);
}

#[tokio::test(start_paused = true)]
async fn sends_keep_their_order_and_are_stamped() {
    let (a, mut b) = pair();
    let senders: Vec<_> = (0..4).map(|_| a.sender()).collect();
    let before = lain_platform::clock::now_ns();
    for round in 0..50u32 {
        for (i, s) in senders.iter().enumerate() {
            s.send(&ping(round * 4 + i as u32, 0)).unwrap();
        }
    }
    let after = lain_platform::clock::now_ns();
    for n in 0..200u32 {
        let env = b.recv_timeout(T).await.unwrap();
        assert_eq!(env.header.sequence, n);
        assert_eq!(env.message, ping(n, 0));
        assert!((before..=after).contains(&env.header.timestamp_ns));
        assert_eq!(env.header.version, NEWEST_VERSION);
    }
}

#[tokio::test(start_paused = true)]
async fn a_channel_reads_as_a_stream_that_ends_at_the_close() {
    let (a, b) = pair();
    let sender = b.sender();
    let mut stream = Box::pin(b.into_stream());
    a.send(&ping(1, 0)).unwrap();
    a.send(&ping(2, 0)).unwrap();
    assert_eq!(stream.next().await.unwrap().message, ping(1, 0));
    assert_eq!(stream.next().await.unwrap().message, ping(2, 0));
    drop(a);
    assert!(stream.next().await.is_none());
    assert_eq!(sender.close_reason(), Some(CloseReason::PeerClosed));
}

#[tokio::test(start_paused = true)]
async fn a_close_sends_what_was_queued_first() {
    let (a, mut b) = pair();
    let frame = Message::VideoFrame(VideoFrame {
        frame_id: 1,
        config_id: 1,
        capture_time_ns: 1,
        encode_done_ns: 2,
        is_keyframe: true,
        data: vec![0xAB; 1_300_000],
    });
    a.send(&frame).unwrap();
    assert!(a.pending_bytes() > 1_300_000 || a.pending_bytes() == 0);
    drop(a);
    assert_eq!(b.recv_timeout(T).await.unwrap().message, frame);
    assert_eq!(b.recv_timeout(T).await, Err(TransportError::Closed));
}

#[tokio::test(start_paused = true)]
async fn a_peer_that_never_reads_cant_keep_a_closed_channel_alive() {
    let (a, mut far) = memory_pair();
    let a = at(a, Some(NEWEST_VERSION));
    let sender = a.sender();
    // More than the memory stream holds: the writer waits on the far end.
    let big = Message::VideoFrame(VideoFrame {
        frame_id: 1,
        config_id: 1,
        capture_time_ns: 1,
        encode_done_ns: 2,
        is_keyframe: false,
        data: vec![0; 4 * MEMORY_STREAM_BUFFER],
    });
    a.send(&big).unwrap();
    tokio::time::sleep(Duration::from_millis(10)).await;
    assert!(sender.pending_bytes() > 0, "the writer is stuck behind the unread far end");
    drop(a);
    tokio::time::sleep(CLOSE_LINGER + Duration::from_millis(10)).await;
    // The writer gave up: the far end reads what was written, then EOF.
    let mut all = Vec::new();
    far.read_to_end(&mut all).await.unwrap();
    assert!(all.len() < 4 * MEMORY_STREAM_BUFFER);
}

/// What the peer sends and nobody reads is held up to `INBOUND_BUFFER`; then the channel stops reading, the
/// peer's writes wait (backpressure), and reading lets them go on. Swift buffers without bound.
#[tokio::test(start_paused = true)]
async fn unread_messages_are_bounded_and_reading_resumes_the_stream() {
    let (a, mut peer) = memory_pair();
    let mut channel = at(a, None);
    let limit = 3 * INBOUND_BUFFER;
    let written = flood(&mut peer, limit).await;
    // The budget, plus what the parser and the memory pipe hold: a frame, a read chunk, the pipe.
    let slack = 2 * bulky_frame().len() + 64 * 1024 + MEMORY_STREAM_BUFFER;
    assert!(written < INBOUND_BUFFER + slack, "{written} bytes taken while nobody reads (limit {limit})");
    assert!(written > INBOUND_BUFFER - slack, "only {written} bytes before the writes waited");
    assert!(channel.close_reason().is_none(), "backpressure, not a close");
    // Reading frees room: the peer's writes go on.
    for _ in 0..20 {
        let r = channel.recv_timeout(T).await.unwrap();
        assert!(matches!(r.message, Message::Error(_)));
    }
    assert!(flood(&mut peer, 1).await > 0, "writes resume once messages are read");
}

// MARK: ChannelVersions

#[tokio::test(start_paused = true)]
async fn a_channel_switches_from_the_handshake_to_its_version() {
    let (a, b) = memory_pair();
    let (ca, mut cb) = (MessageChannel::new(a, "a"), MessageChannel::new(b, "b"));
    let accept = ChannelAccept { chosen: 4, versions: VersionList::supported().clone() };
    ca.send(&Message::ChannelAccept(accept.clone())).unwrap();
    ca.set_version(4);
    ca.send(&ping(1, 0)).unwrap();
    let first = cb.recv_timeout(T).await.unwrap();
    assert_eq!(first.header.version, HANDSHAKE_VERSION);
    assert_eq!(first.message, Message::ChannelAccept(accept));
    cb.set_version(4); // before reading the session frame that follows
    let second = cb.recv_timeout(T).await.unwrap();
    assert_eq!((second.header.version, second.message), (4, ping(1, 0)));
}

#[tokio::test(start_paused = true)]
async fn a_frame_in_another_version_closes_the_channel() {
    let (a, b) = memory_pair();
    let (ca, mut cb) = (at(a, Some(5)), at(b, Some(4)));
    ca.send(&ping(1, 0)).unwrap();
    assert_eq!(cb.recv_timeout(T).await, Err(TransportError::Closed));
    let reason = cb.close_reason().unwrap();
    assert_eq!(reason, CloseReason::WrongVersion("a ping frame in v5 on a channel at v4".into()));
    assert_eq!(reason.error(), TransportError::UnexpectedMessage("a ping frame in v5 on a channel at v4".into()));
    // Nothing more is delivered, even what was already buffered.
    ca.send(&ping(2, 0)).unwrap();
    assert_eq!(cb.recv_timeout(T).await, Err(TransportError::Closed));
}

#[tokio::test(start_paused = true)]
async fn a_session_frame_before_the_version_is_set_closes_the_channel() {
    let (a, b) = memory_pair();
    let (ca, mut cb) = (at(a, Some(4)), at(b, None));
    ca.send(&ping(1, 0)).unwrap();
    assert_eq!(cb.recv_timeout(T).await, Err(TransportError::Closed));
    let Some(CloseReason::WrongVersion(why)) = cb.close_reason() else { panic!("{:?}", cb.close_reason()) };
    assert!(why.contains("on a channel at the handshake"), "{why}");
}

#[tokio::test(start_paused = true)]
async fn a_message_missing_at_the_channels_version_is_not_sent() {
    let (a, mut b) = memory_pair();
    let a = at(a, Some(4));
    let stats = Message::StatsRequest(StatsRequest { interval_ms: 250 });
    assert!(matches!(a.send(&stats), Err(SendError::Unrepresentable(_))));
    // Nor a session message in the handshake layer.
    let (c, _d) = memory_pair();
    assert!(matches!(MessageChannel::new(c, "c").send(&ping(1, 0)), Err(SendError::Unrepresentable(_))));
    // The channel is still fine: the next message is sequence 0.
    a.send(&ping(1, 0)).unwrap();
    let frame = read_frame(&mut b).await.unwrap();
    assert_eq!(MessageCodec::decode(&frame).unwrap().header.sequence, 0);
}

// MARK: ChannelVersionMismatch

#[tokio::test(start_paused = true)]
async fn a_legacy_frame_is_the_close_error() {
    let (mut a, b) = memory_pair();
    let mut channel = MessageChannel::new(b, "b");
    a.write_all(&reframed(MessageCodec::encode(&ping(1, 0), 0, 0, None, None), 2)).await.unwrap();
    assert_eq!(channel.recv_timeout(T).await, Err(TransportError::VersionMismatch { remote: 2 }));
    assert_eq!(channel.close_reason().unwrap().error(), TransportError::VersionMismatch { remote: 2 });
}

#[tokio::test(start_paused = true)]
async fn only_an_acceptor_answers_and_only_a_mismatched_first_frame() {
    async fn answer(acceptor: bool, first: &[Message]) -> Vec<u8> {
        let (mut a, b) = memory_pair();
        let channel = MessageChannel::with_options(
            b,
            ChannelOptions { answer_version_mismatch: acceptor, ..ChannelOptions::new("b") },
        );
        for m in first {
            a.write_all(&MessageCodec::encode(m, 0, 0, None, None)).await.unwrap();
        }
        a.write_all(&reframed(MessageCodec::encode(&ping(1, 0), 0, 0, None, None), 1)).await.unwrap();
        let mut got = Vec::new();
        a.read_to_end(&mut got).await.unwrap();
        drop(channel);
        got
    }
    let answered = answer(true, &[]).await;
    assert!(answered.len() > HEADER_SIZE && answered[2] == 1 && answered[3] == MessageType::Error.raw());
    let Message::Error(e) = MessageCodec::decode(&reframed(answered, HANDSHAKE_VERSION)).unwrap().message else {
        panic!("not an Error")
    };
    assert_eq!(e.code, ErrorCode::VERSION_MISMATCH);
    assert_eq!(e.message, format!("lain here speaks protocol {}", VersionList::supported()));
    assert!(answer(false, &[]).await.is_empty());
    let hello = ProtocolSamples::all().iter().find(|m| m.ty() == MessageType::ChannelHello).unwrap().clone();
    assert!(answer(true, &[hello]).await.is_empty());
}

// MARK: Streams

#[tokio::test]
async fn tcp_carries_large_frames_intact() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let client = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let (server, _) = listener.accept().await.unwrap();
    let (client, mut server) = (at(client, Some(NEWEST_VERSION)), at(server, Some(NEWEST_VERSION)));
    let total = 5 * 1024 * 1024;
    let payload: Vec<u8> = (0..total).map(|i: usize| (i.wrapping_mul(31)) as u8).collect();
    let frames: Vec<Message> = payload
        .chunks(700_000)
        .enumerate()
        .map(|(i, chunk)| {
            Message::VideoFrame(VideoFrame {
                frame_id: i as u32,
                config_id: 1,
                capture_time_ns: 0,
                encode_done_ns: 0,
                is_keyframe: false,
                data: chunk.to_vec(),
            })
        })
        .collect();
    for f in &frames {
        client.send(f).unwrap();
    }
    for f in &frames {
        assert_eq!(&server.recv_timeout(Duration::from_secs(10)).await.unwrap().message, f);
    }
}

#[tokio::test]
async fn a_remote_close_is_reported() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let client = at(tokio::net::TcpStream::connect(("127.0.0.1", port)).await.unwrap(), None);
    let (server, _) = listener.accept().await.unwrap();
    drop(at(server, None));
    assert_eq!(tokio::time::timeout(T, client.closed()).await.unwrap(), CloseReason::PeerClosed);
}

#[tokio::test]
async fn the_send_buffer_can_be_kept_small() {
    let (a, _b) = tokio::net::UnixStream::pair().unwrap();
    a.set_send_buffer_size(HostLink::VIDEO_SEND_BUFFER).unwrap();
    // Linux reports twice what was asked (its bookkeeping share).
    let reported = socket2::SockRef::from(&a).send_buffer_size().unwrap();
    assert_eq!(reported, 2 * HostLink::VIDEO_SEND_BUFFER);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let tcp = tokio::net::TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
    tcp.set_send_buffer_size(HostLink::VIDEO_SEND_BUFFER).unwrap();
    assert!(socket2::SockRef::from(&tcp).send_buffer_size().unwrap() >= HostLink::VIDEO_SEND_BUFFER);
    // Memory has no kernel buffer: a no-op.
    memory_pair().0.set_send_buffer_size(1).unwrap();
}

// MARK: Secrets

#[test]
fn hmac_covers_versions_kind_and_token() {
    let secret = secret();
    let token = token();
    let hello = ChannelAuth::hello(ConnectionKind::Video, token, Some(&secret), &offered());
    assert!(ChannelAuth::is_valid(&hello, &secret));
    assert!(!ChannelAuth::is_valid(&hello, &common::secret()));
    let mut other = hello.clone();
    other.connection_kind = ConnectionKind::Audio;
    assert!(!ChannelAuth::is_valid(&other, &secret));
    let mut other = hello.clone();
    other.session_token[0] ^= 1;
    assert!(!ChannelAuth::is_valid(&other, &secret));
    // The offered versions are covered too: a downgrade can't be slipped in.
    let mut other = hello.clone();
    other.versions = other.versions.capped(other.versions.oldest());
    assert!(other.versions != hello.versions && !ChannelAuth::is_valid(&other, &secret));
    assert_eq!(ChannelAuth::hello(ConnectionKind::Realtime, token, None, &offered()).hmac, ChannelAuth::PAIRING_MAC);
}

/// An independent HMAC-SHA256 vector, so the HMAC isn't only checked against itself: the authenticated
/// bytes of a hello with an empty version list, realtime and an all-zero token are 18 zero bytes, and
/// HMAC-SHA256(key "key", 18 zero bytes) was computed with Python's `hmac` module.
#[test]
fn the_mac_is_hmac_sha256_over_the_authenticated_bytes() {
    let mut hello = ChannelHello {
        versions: VersionList::default(),
        connection_kind: ConnectionKind::Realtime,
        session_token: [0; 16],
        hmac: [0; 32],
    };
    assert_eq!(hello.authenticated_bytes(), [0u8; 18]);
    let expected = hex::decode("10daacf5d82b96aa1c9290e01ff56b26bc984da07e3ee92ef0e9637f68340718").unwrap();
    assert_eq!(ChannelAuth::mac(b"key", &hello).to_vec(), expected);
    hello.hmac = expected.try_into().unwrap();
    assert!(ChannelAuth::is_valid(&hello, b"key"));
}
