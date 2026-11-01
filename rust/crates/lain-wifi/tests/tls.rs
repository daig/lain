//! TLS-PSK connections over loopback. Port of Swift's `NetworkStreamTests.swift` (`NetworkStreams`), with
//! real OpenSSL handshakes. Loopback only: nothing listens on a wildcard address (but the one `#[ignore]`d
//! test), nothing is advertised.

mod common;

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use lain_link::{ByteStream, LinkTransport, MessageChannel};
use lain_proto::*;
use lain_wifi::*;
use openssl::ssl::SslVersion;
use socket2::SockRef;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

fn lo() -> LinkTransport {
    LinkTransport::Network { interface: Some("lo".into()), peer_to_peer: false }
}

/// Whether the far end of `stream` closed (EOF or an error) within `within`.
async fn closes<S: tokio::io::AsyncRead + Unpin>(stream: &mut S, within: Duration) -> bool {
    let mut buf = [0u8; 64];
    let read = async {
        loop {
            match stream.read(&mut buf).await {
                Ok(0) | Err(_) => return,
                Ok(_) => {}
            }
        }
    };
    tokio::time::timeout(within, read).await.is_ok()
}

#[tokio::test]
async fn echo_runs_tls12_ecdhe_psk_over_loopback() {
    let mut server = Server::new(&[secret_a()]);
    let t0 = Instant::now();
    let (mut client, mut accepted) = server.pair(&secret_a()).await;
    let dial_ns = t0.elapsed().as_nanos() as u64;
    let psk = WiFiPsk::new(&secret_a());
    for end in [&client, &accepted] {
        assert_eq!(end.tls, NegotiatedTls { version: 0x0303, cipher_suite: 0xCCAC });
        assert_eq!(end.transport(), lo());
        assert_eq!(end.psk_identity, psk.identity());
        assert!(end.handshake_ns > 0 && end.handshake_ns <= dial_ns);
        assert_eq!(end.stream.pairing_secret(), Some(&secret_a()[..]));
    }
    assert_eq!(client.peer_addr, server.addr());
    assert_eq!(client.local_addr, accepted.peer_addr);

    tokio::spawn(async move {
        let mut buf = [0u8; 1024];
        loop {
            match accepted.stream.read(&mut buf).await {
                Ok(0) | Err(_) => return,
                Ok(n) => accepted.stream.write_all(&buf[..n]).await.unwrap(),
            }
        }
    });
    client.stream.write_all(b"hello").await.unwrap();
    let mut echoed = [0u8; 5];
    client.stream.read_exact(&mut echoed).await.unwrap();
    assert_eq!(&echoed, b"hello");
    println!(
        "TLS-PSK loopback: dial {:.1} ms (client {:.1} ms), {} on {:?}",
        dial_ns as f64 / 1e6,
        client.handshake_ns as f64 / 1e6,
        client.tls,
        client.transport()
    );
    client.stream.shutdown().await.unwrap();
    // The echo task sees the close and ends: our read ends cleanly.
    let mut rest = Vec::new();
    client.stream.read_to_end(&mut rest).await.unwrap();
}

#[tokio::test]
async fn a_wrong_key_fails_the_dial_and_is_never_handed_over() {
    let mut server = Server::new(&[secret_a()]);
    let forged = WiFiPsk::from_parts(WiFiPsk::new(&secret_a()).identity(), *WiFiPsk::new(&secret_b()).key());
    let error = WiFiDialer::with_psk(server.addr(), forged).connect(None).await.unwrap_err();
    assert_eq!(error, WiFiError::WrongKey);
    assert_eq!(next(&mut server.rejected, T).await, Some(WiFiError::WrongKey));
    assert!(next(&mut server.accepted, Duration::from_millis(300)).await.is_none());
}

#[tokio::test]
async fn an_unknown_identity_fails_the_dial_and_is_never_handed_over() {
    let mut server = Server::new(&[secret_a()]);
    assert_eq!(connect(server.addr(), &secret_b()).await.unwrap_err(), WiFiError::UnknownIdentity);
    assert_eq!(next(&mut server.rejected, T).await, Some(WiFiError::UnknownIdentity));
    assert!(next(&mut server.accepted, Duration::from_millis(300)).await.is_none());
}

#[tokio::test]
async fn an_empty_table_refuses_every_identity() {
    let mut server = Server::new(&[]);
    assert_eq!(connect(server.addr(), &secret_a()).await.unwrap_err(), WiFiError::UnknownIdentity);
    assert_eq!(next(&mut server.rejected, T).await, Some(WiFiError::UnknownIdentity));
}

#[tokio::test]
async fn a_connection_that_never_finishes_tls_is_dropped_at_the_handshake_deadline() {
    let mut server = Server::with_handshake_timeout(&[secret_a()], Duration::from_millis(500));
    let mut raw = TcpStream::connect(server.addr()).await.unwrap(); // plain TCP: never sends a ClientHello
    let t0 = Instant::now();
    assert_eq!(next(&mut server.rejected, T).await, Some(WiFiError::Timeout));
    assert!(t0.elapsed() >= Duration::from_millis(400));
    assert!(closes(&mut raw, Duration::from_secs(2)).await);
    assert!(next(&mut server.accepted, Duration::from_millis(200)).await.is_none());
    assert_eq!(server.listener.pending_handshakes(), 0);
}

#[tokio::test]
async fn a_flood_of_idle_connections_stays_capped_and_a_real_client_still_gets_in() {
    // Every loopback connection comes from 127.0.0.1, so the per-address cap is the one that binds. The
    // handshake deadline is far off: only the cap lets go of anything here.
    let mut server = Server::with_handshake_timeout(&[secret_a()], Duration::from_secs(60));
    let cap = ListenerOptions::MAX_PENDING_PER_HOST;
    let dropped = Arc::new(Mutex::new(BTreeSet::new()));
    let mut peak = 0;
    let mut readers = Vec::new();
    let total = 200;
    for i in 1..=total {
        let mut raw = TcpStream::connect(server.addr()).await.unwrap(); // never sends a ClientHello
        let dropped = dropped.clone();
        readers.push(tokio::spawn(async move {
            let mut buf = [0u8; 16];
            let _ = raw.read(&mut buf).await;
            dropped.lock().unwrap().insert(i);
            raw
        }));
        peak = peak.max(server.listener.pending_handshakes());
        if i % 25 == 0 && i < total {
            // A real client in the middle of it, with the cap full of idle connections: it evicts the
            // oldest and is done long before the flood could evict it.
            let (client, accepted) = server.pair(&secret_a()).await;
            assert!(client.tls == NegotiatedTls::REQUIRED && accepted.tls == NegotiatedTls::REQUIRED);
        }
    }
    assert!(poll_until(T, || server.listener.pending_handshakes() == cap).await);
    assert!(peak <= cap);
    // The listener let go of every idle connection beyond the cap, oldest first, and their sockets closed:
    // the flood holds a few descriptors, not one per connection.
    assert!(poll_until(T, || dropped.lock().unwrap().len() == total - cap).await);
    assert_eq!(*dropped.lock().unwrap(), (1..=total - cap).collect::<BTreeSet<_>>()); // the newest are left
    assert!(next(&mut server.rejected, Duration::from_millis(300)).await.is_none()); // evictions are silent
    println!("handshake flood: {total} idle connections, {} evicted, at most {peak} pending", total - cap);
    readers.iter().for_each(|r| r.abort());
}

#[tokio::test]
async fn cancelling_the_listener_drops_pending_handshakes_at_once() {
    let mut server = Server::with_handshake_timeout(&[secret_a()], Duration::from_secs(30));
    let mut raw = TcpStream::connect(server.addr()).await.unwrap();
    assert!(poll_until(T, || server.listener.pending_handshakes() == 1).await);
    let t0 = Instant::now();
    server.listener.cancel();
    // At once, not at the handshake deadline.
    assert!(closes(&mut raw, Duration::from_secs(2)).await);
    assert!(t0.elapsed() < Duration::from_secs(2));
    assert_eq!(server.listener.pending_handshakes(), 0);
    assert!(next(&mut server.rejected, Duration::from_millis(200)).await.is_none()); // a cancel isn't a rejection
    assert!(next(&mut server.accepted, Duration::from_millis(100)).await.is_none());
    // And nothing listens any more.
    assert!(TcpStream::connect(server.addr()).await.is_err());
}

#[tokio::test]
async fn streams_handed_over_outlive_the_listener_and_its_restart() {
    let mut first = Server::new(&[secret_a()]);
    let (mut client, mut accepted) = first.pair(&secret_a()).await;
    client.stream.write_all(&[1, 2, 3]).await.unwrap();
    accepted.stream.write_all(&[4, 5, 6]).await.unwrap();
    // A restart: the old listener cancelled and dropped, a new one with another key set.
    first.listener.cancel();
    drop(first);
    let mut second = Server::new(&[secret_a(), secret_b()]);
    let (_client2, _accepted2) = second.pair(&secret_b()).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    client.stream.write_all(&[7, 8, 9]).await.unwrap();
    accepted.stream.write_all(&[10, 11, 12]).await.unwrap();
    let (mut at_server, mut at_client) = ([0u8; 6], [0u8; 6]);
    accepted.stream.read_exact(&mut at_server).await.unwrap();
    client.stream.read_exact(&mut at_client).await.unwrap();
    assert_eq!((at_server, at_client), ([1, 2, 3, 7, 8, 9], [4, 5, 6, 10, 11, 12]));
}

/// Swift: `theListenerRefusesAClientThatSettlesOnAPlainPSKSuite`. Difference: Network.framework's listener
/// enables the plain-PSK suites too and refuses them after the handshake (`unexpectedTLS`); OpenSSL's offers
/// only 0xCCAC, so a plain-PSK client fails in the handshake (no shared cipher).
#[tokio::test]
async fn the_listener_refuses_a_client_offering_only_plain_psk_suites() {
    let mut server = Server::new(&[secret_a()]);
    let psk = WiFiPsk::new(&secret_a());
    let plain = hand_client(&psk, "PSK-CHACHA20-POLY1305:PSK-AES128-GCM-SHA256", (SslVersion::TLS1_2, SslVersion::TLS1_2));
    assert!(hand_connect(server.addr(), &plain).await.is_err());
    assert!(matches!(next(&mut server.rejected, T).await, Some(WiFiError::Tls(_))));
    assert!(next(&mut server.accepted, Duration::from_millis(300)).await.is_none());
}

/// Only `ECDHE-PSK-CHACHA20-POLY1305` negotiates (the brief's `openssl s_server`/`s_client` checks, in
/// code): a client that offers it among others gets it; one that offers TLS 1.3 only, or another ECDHE-PSK
/// suite only, is refused.
#[tokio::test]
async fn only_ecdhe_psk_chacha20_poly1305_negotiates() {
    let mut server = Server::new(&[secret_a()]);
    let psk = WiFiPsk::new(&secret_a());
    let tls12 = (SslVersion::TLS1_2, SslVersion::TLS1_2);
    let mixed = hand_client(&psk, "PSK-AES128-GCM-SHA256:ECDHE-PSK-AES128-CBC-SHA256:ECDHE-PSK-CHACHA20-POLY1305", tls12);
    let stream = hand_connect(server.addr(), &mixed).await.unwrap();
    assert_eq!(stream.ssl().current_cipher().unwrap().protocol_id(), [0xCC, 0xAC]);
    assert_eq!(stream.ssl().version2(), Some(SslVersion::TLS1_2));
    let accepted = next(&mut server.accepted, T).await.unwrap();
    assert_eq!(accepted.tls, NegotiatedTls::REQUIRED);

    let other = hand_client(&psk, "ECDHE-PSK-AES128-CBC-SHA256", tls12);
    assert!(hand_connect(server.addr(), &other).await.is_err());
    let tls13 = hand_client(&psk, "ECDHE-PSK-CHACHA20-POLY1305", (SslVersion::TLS1_3, SslVersion::TLS1_3));
    assert!(hand_connect(server.addr(), &tls13).await.is_err());
    for _ in 0..2 {
        assert!(matches!(next(&mut server.rejected, T).await, Some(WiFiError::Tls(_))));
    }
    assert!(next(&mut server.accepted, Duration::from_millis(300)).await.is_none());
}

/// Swift: `aDialerRefusesAListenerThatSettlesOnAPlainPSKSuite`. Difference: our dialer offers only 0xCCAC, so
/// a listener that allows only plain PSK fails the handshake rather than completing on 0xA8.
#[tokio::test]
async fn a_dialer_refuses_a_listener_that_offers_only_plain_psk() {
    let tcp = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = tcp.local_addr().unwrap();
    let context = hand_server(&WiFiPsk::new(&secret_a()), "PSK-CHACHA20-POLY1305");
    let server = tokio::spawn(async move {
        let (socket, _) = tcp.accept().await.unwrap();
        hand_accept(socket, &context).await.map(|_| ())
    });
    let error = WiFiDialer::new(addr, &secret_a()).connect(Some(ConnectionKind::Realtime)).await.unwrap_err();
    assert!(matches!(error, WiFiError::Tls(_)), "{error:?}");
    assert!(server.await.unwrap().is_err());
}

#[tokio::test]
async fn a_listener_holding_three_psks_accepts_each_identity() {
    let secrets: Vec<Vec<u8>> = (1..=3).map(|i| vec![i; 32]).collect();
    let mut server = Server::new(&secrets);
    for secret in &secrets {
        let (mut client, accepted) = server.pair(secret).await;
        assert_eq!(client.tls.cipher_suite, 0xCCAC);
        assert_eq!(accepted.tls.cipher_suite, 0xCCAC);
        // The listener learns which of its PSKs this client used (the PSK callback), and binds to its secret.
        let identity = WiFiPsk::new(secret).identity().to_owned();
        assert!(accepted.psk_identity == identity && client.psk_identity == identity);
        assert_eq!(accepted.stream.pairing_secret(), Some(&secret[..]));
        let channel = MessageChannel::new(accepted.stream, "bound");
        assert_eq!(secrets.iter().filter(|s| channel.is_bound_to_secret(s)).collect::<Vec<_>>(), vec![secret]);
        client.stream.write_all(&[7]).await.unwrap();
    }
}

#[tokio::test]
async fn five_megabytes_arrive_intact_both_ways() {
    let mut server = Server::new(&[secret_a()]);
    let (client, accepted) = server.pair(&secret_a()).await;
    let total = 5 * 1024 * 1024;
    let (up, down) = (pattern(total, 31), pattern(total, 17));
    let (mut client_read, mut client_write) = tokio::io::split(client.stream);
    let (mut server_read, mut server_write) = tokio::io::split(accepted.stream);
    let (up2, down2) = (up.clone(), down.clone());
    let writers = tokio::spawn(async move {
        tokio::try_join!(client_write.write_all(&up2), server_write.write_all(&down2)).unwrap();
    });
    let (mut at_server, mut at_client) = (vec![0u8; total], vec![0u8; total]);
    let reads = async { tokio::try_join!(server_read.read_exact(&mut at_server), client_read.read_exact(&mut at_client)) };
    tokio::time::timeout(Duration::from_secs(20), reads).await.unwrap().unwrap();
    writers.await.unwrap();
    assert!(at_server == up && at_client == down);
}

#[tokio::test]
async fn data_then_eof_delivers_every_byte_then_a_clean_close() {
    let mut server = Server::new(&[secret_a()]);
    let (mut client, mut accepted) = server.pair(&secret_a()).await;
    let payload = pattern(1_000_000, 7);
    let sent = payload.clone();
    tokio::spawn(async move {
        accepted.stream.write_all(&sent).await.unwrap();
        accepted.stream.shutdown().await.unwrap(); // close_notify, then FIN
        // Keep reading so the close can't turn into a reset.
        let mut sink = Vec::new();
        let _ = accepted.stream.read_to_end(&mut sink).await;
    });
    let mut received = Vec::new();
    client.stream.read_to_end(&mut received).await.unwrap(); // a clean EOF, not an error
    assert_eq!(received, payload);
    assert_eq!(client.stream.read(&mut [0u8; 8]).await.unwrap(), 0); // and EOF again
}

/// Swift: `aRemoteCloseIsReportedExactlyOnce` ("exactly once" is a callback property tokio streams don't
/// have): a reset is an error. A FIN without `close_notify` reads as a clean EOF (the `openssl` crate maps
/// OpenSSL's unexpected EOF to 0 bytes): a truncation is caught by `lain-link`'s framing, not by TLS.
#[tokio::test]
async fn a_reset_is_an_error_and_a_bare_fin_an_eof() {
    let mut server = Server::new(&[secret_a()]);
    let (mut client, accepted) = server.pair(&secret_a()).await;
    SockRef::from(accepted.tcp()).set_linger(Some(Duration::ZERO)).unwrap();
    drop(accepted); // RST
    assert!(client.stream.read(&mut [0u8; 8]).await.is_err());

    let (mut client, mut accepted) = server.pair(&secret_a()).await;
    accepted.stream.get_mut().get_mut().shutdown().await.unwrap(); // FIN, no close_notify
    assert_eq!(client.stream.read(&mut [0u8; 8]).await.unwrap(), 0);
}

#[tokio::test]
async fn close_sends_queued_writes_first() {
    let mut server = Server::new(&[secret_a()]);
    let (mut client, mut accepted) = server.pair(&secret_a()).await;
    let payload = pattern(5 * 1024 * 1024, 3);
    let sent = payload.clone();
    let writer = tokio::spawn(async move {
        client.stream.write_all(&sent).await.unwrap();
        client.stream.shutdown().await.unwrap();
        let mut rest = Vec::new();
        client.stream.read_to_end(&mut rest).await
    });
    let mut received = Vec::new();
    tokio::time::timeout(Duration::from_secs(10), accepted.stream.read_to_end(&mut received)).await.unwrap().unwrap();
    assert_eq!(received.len(), payload.len());
    assert!(received == payload);
    accepted.stream.shutdown().await.unwrap();
    assert!(writer.await.unwrap().is_ok()); // the client's read ends cleanly too
}

#[tokio::test]
async fn a_dial_cancelled_mid_handshake_leaves_no_connection() {
    // A plain TCP server: the dial's TCP connect succeeds, then TLS waits for a ServerHello forever.
    let tcp = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = tcp.local_addr().unwrap();
    let dial = tokio::spawn(async move {
        WiFiDialer::new(addr, &secret_a()).timeout(Duration::from_secs(20)).connect(Some(ConnectionKind::Realtime)).await
    });
    let (mut peer, _) = tcp.accept().await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    let t0 = Instant::now();
    dial.abort();
    assert!(dial.await.unwrap_err().is_cancelled());
    assert!(t0.elapsed() < Duration::from_secs(1));
    assert!(closes(&mut peer, Duration::from_secs(2)).await); // the dialed connection is gone
}

#[tokio::test]
async fn a_dial_to_a_closed_port_is_refused() {
    let port = {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    };
    let t0 = Instant::now();
    assert_eq!(connect(([127, 0, 0, 1], port).into(), &secret_a()).await.unwrap_err(), WiFiError::Refused);
    assert!(t0.elapsed() < WiFiDialer::DEFAULT_TIMEOUT);
}

#[tokio::test]
async fn a_dial_that_is_never_answered_times_out() {
    let tcp = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let dialer = WiFiDialer::new(tcp.local_addr().unwrap(), &secret_a()).timeout(Duration::from_millis(500));
    let t0 = Instant::now();
    assert_eq!(dialer.connect(None).await.unwrap_err(), WiFiError::Timeout);
    assert!(t0.elapsed() < Duration::from_secs(2));
}

#[tokio::test]
async fn message_channel_round_trip_over_tls() {
    let mut server = Server::new(&[secret_a()]);
    let (client, accepted) = server.pair(&secret_a()).await;
    let newest = VersionList::supported().newest().unwrap();
    let mut client = MessageChannel::new(client.stream, "client");
    let mut host = MessageChannel::new(accepted.stream, "host");
    client.set_version(newest);
    host.set_version(newest);
    let hello = Message::Ping(Ping { id: 1, sent_at_ns: 2 });
    client.send(&hello).unwrap();
    assert_eq!(host.recv_timeout(T).await.unwrap().message, hello);
    let pong = Message::Ping(Ping { id: 2, sent_at_ns: 3 });
    host.send(&pong).unwrap();
    assert_eq!(client.recv_timeout(T).await.unwrap().message, pong);
    let keyframe = Message::VideoFrame(VideoFrame {
        frame_id: 9,
        config_id: 1,
        capture_time_ns: 1,
        encode_done_ns: 2,
        is_keyframe: true,
        data: pattern(1_300_000, 11),
    });
    client.send(&keyframe).unwrap();
    assert_eq!(host.recv_timeout(Duration::from_secs(5)).await.unwrap().message, keyframe);
    host.send(&Message::FrameAck(FrameAck { frame_id: 9, received_at_ns: 1, bytes: 1_300_000 })).unwrap();
    assert_eq!(
        client.recv_timeout(T).await.unwrap().message,
        Message::FrameAck(FrameAck { frame_id: 9, received_at_ns: 1, bytes: 1_300_000 })
    );
}

/// Swift: `theWiFiLinkDialerPinsVideoAndAudioToRealtimesPath`, the service-class half (there is no path to
/// pin when dialing an address): realtime alone is marked.
#[tokio::test]
async fn the_dialer_marks_realtime_alone() {
    let mut server = Server::new(&[secret_a()]);
    let dialer = WiFiDialer::new(server.addr(), &secret_a());
    for (kind, tos) in [(Some(ConnectionKind::Realtime), 0xB8), (Some(ConnectionKind::Video), 0), (None, 0)] {
        let connection = dialer.connect(kind).await.unwrap();
        assert_eq!(SockRef::from(connection.tcp()).tos_v4().unwrap(), tos, "{kind:?}");
        assert_eq!(connection.transport(), lo());
        let accepted = next(&mut server.accepted, T).await.unwrap();
        assert_eq!(SockRef::from(accepted.tcp()).tos_v4().unwrap(), 0); // the host never marks
    }
}

#[tokio::test]
async fn loopback_throughput() {
    let mut server = Server::new(&[secret_a()]);
    let (mut client, mut accepted) = server.pair(&secret_a()).await;
    let total = 32 << 20;
    let chunk = vec![0x5A; 1 << 20];
    let t0 = Instant::now();
    let writer = tokio::spawn(async move {
        for _ in 0..total / chunk.len() {
            client.stream.write_all(&chunk).await.unwrap();
        }
        client
    });
    let mut buf = vec![0u8; 1 << 20];
    let mut got = 0;
    while got < total {
        got += accepted.stream.read(&mut buf).await.unwrap();
    }
    let took = t0.elapsed().as_secs_f64();
    writer.await.unwrap();
    println!(
        "TLS 1.2 ECDHE-PSK CHACHA20-POLY1305 loopback throughput: {:.0} MB/s ({} MB in {took:.2} s)",
        total as f64 / took / 1e6,
        total >> 20
    );
}

/// The production bind: the dual-stack wildcard `[::]:0`. Listens on every interface of this machine (for
/// the moment it runs), so it is the lead's to run: `cargo test -p lain-wifi -- --ignored`. It dials only
/// loopback.
#[tokio::test]
#[ignore = "binds the wildcard address on every interface"]
async fn the_default_listener_binds_the_dual_stack_wildcard() {
    let mut server = Server::with_options(&[secret_a()], ListenerOptions::default());
    assert!(server.addr().ip().is_unspecified());
    let port = server.addr().port();
    for addr in [format!("127.0.0.1:{port}"), format!("[::1]:{port}")] {
        let client = connect(addr.parse().unwrap(), &secret_a()).await.unwrap();
        let accepted = next(&mut server.accepted, T).await.unwrap();
        assert_eq!(client.transport(), lo());
        assert_eq!(accepted.transport(), lo(), "{addr}");
    }
}
