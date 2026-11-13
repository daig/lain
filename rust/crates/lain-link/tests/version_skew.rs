//! Version skew at the link level (PROTOCOL-VERSIONING §2.3), in both roles, with this build's real version
//! lists and digests; and the handshake frames against the Swift tree's golden bytes (decision L5).
//! Swift's `VersionSkewLoopbackTests` run whole client and host sessions; their session-level parts
//! (`HostSetup` reaching the iPad, the status texts) belong to `lain-host`. Here: which version each pair
//! of lists agrees on, what each side then misses, and how a failure names the side to update.

mod common;

use std::collections::BTreeMap;

use common::*;
use lain_link::*;
use lain_platform::fake::MemorySecretStore;
use lain_proto::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

fn supported() -> VersionList {
    VersionList::supported().clone()
}

fn only(version: u8) -> VersionList {
    VersionList::new(supported().entries().iter().copied().filter(|e| e.version == version))
}

/// A future v8, as a newer build would offer it.
fn v8() -> VersionEntry {
    VersionEntry { version: 8, digest: [0x88; 8] }
}

/// v5 under another build's digest.
fn other_v5() -> VersionList {
    VersionList::new([VersionEntry { version: 5, digest: [0x55; 8] }])
}

struct Outcome {
    /// The dialer's result: the version, and what it then misses.
    dialer: Result<(u8, Vec<ProtocolFeature>, bool), TransportError>,
    /// The acceptor's: its link's version and misses, or its rejection.
    acceptor: Result<(u8, Vec<ProtocolFeature>), TransportError>,
}

/// One link: `dialing` dials `accepting` with a stored secret (both roles: the host over USB dials, the
/// iPad over Wi-Fi dials).
async fn negotiate(dialing: &VersionList, accepting: &VersionList) -> Outcome {
    let secret = secret();
    let options = AcceptorOptions { versions: accepting.clone(), ..AcceptorOptions::default() };
    let mut acceptor = Acceptor::new(store(&[("PEER", &secret)]), options);
    let dialer = LinkDialer::new(acceptor.dialer()).versions(dialing.clone());
    let dialed =
        dialer.open(&secret).await.map(|l| (l.version, l.older_peer_misses(), l.supports(ProtocolFeature::HostStats)));
    let accepted = match next(&mut acceptor.links, T).await {
        Some(a) => Ok((a.link.version, a.link.older_peer_misses())),
        None => Err(next(&mut acceptor.rejections, T).await.expect("a link or a rejection")),
    };
    Outcome { dialer: dialed, acceptor: accepted }
}

#[tokio::test(start_paused = true)]
async fn the_version_skew_matrix() {
    let both = supported();
    assert_eq!(both.versions(), [4, 5, 6, 7], "this build's window; update the matrix when it moves");
    let seven_eight = VersionList::new(only(7).entries().iter().copied().chain([v8()]));
    let eight = VersionList::new([v8()]);
    let v7_features = vec![ProtocolFeature::DisplayScale];
    let v6_features = [vec![ProtocolFeature::TextInput, ProtocolFeature::Audio], v7_features.clone()].concat();
    let none = |gap: VersionGap| Some(gap);

    // [4..7] against each peer, in both roles. (peer list, version, what the [4..7] side's link misses).
    let cases: [(&VersionList, Option<u8>, Vec<ProtocolFeature>); 6] = [
        (&only(7), Some(7), vec![]),
        (&only(6), Some(6), v7_features.clone()),
        (&only(5), Some(5), v6_features.clone()),
        (&only(4), Some(4), [vec![ProtocolFeature::HostStats], v6_features.clone()].concat()),
        (&seven_eight, Some(7), vec![]),
        (&eight, None, vec![]),
    ];
    for (peer, version, misses) in cases {
        for this_side_dials in [true, false] {
            let outcome = if this_side_dials { negotiate(&both, peer).await } else { negotiate(peer, &both).await };
            let (ours, theirs) = if this_side_dials {
                (outcome.dialer.map(|(v, m, _)| (v, m)), outcome.acceptor)
            } else {
                (outcome.acceptor, outcome.dialer.map(|(v, m, _)| (v, m)))
            };
            let context = format!("[4..7] {} {peer}", if this_side_dials { "dials" } else { "accepts" });
            match version {
                Some(v) => {
                    assert_eq!(ours, Ok((v, misses.clone())), "{context}");
                    // The peer's newest is v, or a v8 that adds nothing known here: it misses nothing.
                    assert_eq!(theirs, Ok((v, vec![])), "{context}");
                }
                None => {
                    let ours = ours.unwrap_err();
                    let theirs = theirs.unwrap_err();
                    assert_eq!(
                        VersionGap::from_error(&ours, &both),
                        none(VersionGap::PeerNewer { peer: "protocol v8".into() }),
                        "{context}"
                    );
                    assert_eq!(
                        VersionGap::from_error(&theirs, peer),
                        none(VersionGap::PeerOlder { peer: "protocol v4–v7".into() }),
                        "{context}"
                    );
                }
            }
        }
    }
}

#[tokio::test(start_paused = true)]
async fn feature_support_follows_the_negotiated_version() {
    let outcome = negotiate(&supported(), &only(4)).await;
    assert_eq!(outcome.dialer.map(|(v, _, stats)| (v, stats)), Ok((4, false)));
    let outcome = negotiate(&supported(), &only(5)).await;
    assert_eq!(outcome.dialer.map(|(v, _, stats)| (v, stats)), Ok((5, true)));
    let outcome = negotiate(&supported(), &only(6)).await;
    assert_eq!(outcome.dialer.map(|(v, _, stats)| (v, stats)), Ok((6, true)));
}

#[tokio::test(start_paused = true)]
async fn a_digest_mismatch_is_not_a_common_version() {
    // Other builds of v5 and v6 beside a shared v4: v4.
    let other_v6 = VersionEntry { version: 6, digest: [0x66; 8] };
    let mixed = VersionList::new(
        only(4).entries().iter().copied().chain(other_v5().entries().iter().copied()).chain([other_v6]),
    );
    let outcome = negotiate(&supported(), &mixed).await;
    let v4_misses = vec![
        ProtocolFeature::HostStats,
        ProtocolFeature::TextInput,
        ProtocolFeature::Audio,
        ProtocolFeature::DisplayScale,
    ];
    assert_eq!(outcome.dialer.map(|(v, m, _)| (v, m)), Ok((4, v4_misses)));
    // Only v5, under different digests: nothing in common, and the gap says "different builds".
    let outcome = negotiate(&only(5), &other_v5()).await;
    let error = outcome.dialer.unwrap_err();
    assert_eq!(error, TransportError::NoCommonVersion { local: only(5), peer: other_v5() });
    assert_eq!(VersionGap::from_error(&error, &only(5)), Some(VersionGap::DifferentBuilds { version: 5 }));
    assert_eq!(
        VersionGap::from_error(&outcome.acceptor.unwrap_err(), &other_v5()),
        Some(VersionGap::DifferentBuilds { version: 5 })
    );
}

#[tokio::test(start_paused = true)]
async fn a_legacy_v2_peer_is_answered_in_v2_in_either_role() {
    // The host's Wi-Fi acceptor and the client's USB acceptor answer alike.
    let acceptors: [Acceptor<MemorySecretStore>; 2] =
        [Acceptor::host(store(&[])), Acceptor::client(store(&[]), true, offered())];
    for mut acceptor in acceptors {
        let mut raw = acceptor.raw_bytes();
        raw.write_all(&legacy_channel_hello(2)).await.unwrap();
        let mut answer = Vec::new();
        raw.read_to_end(&mut answer).await.unwrap();
        assert_eq!(answer[2], 2);
        // Exactly one frame, in v2: Error(versionMismatch), sequence 0, with Swift's text. Only the timestamp
        // (bytes 12..20) is the clock's.
        answer[12..20].fill(0);
        let why = format!("lain here speaks protocol {}", VersionList::supported());
        assert_eq!(why, "lain here speaks protocol v4–v7");
        assert_eq!(hex::encode(answer), hex::encode(MessageCodec::legacy_version_mismatch(2, &why, 0, 0)));
        let error = next(&mut acceptor.rejections, T).await.unwrap();
        assert_eq!(error, TransportError::VersionMismatch { remote: 2 });
        assert_eq!(
            VersionGap::from_error(&error, &offered()),
            Some(VersionGap::PeerOlder { peer: "protocol v2".into() })
        );
    }
}

// MARK: Golden handshake bytes

const GOLDEN_PATH: &str = "../../../Packages/LainKit/Tests/LainProtocolTests/GoldenBytes.swift";

/// The handshake table (key 255) of `GoldenBytes.swift`: message name → frame bytes. The full, strict
/// parse is `lain-proto`'s conformance test; this reads only the entries it needs and fails if they're
/// missing.
fn golden_handshake() -> BTreeMap<String, Vec<u8>> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(GOLDEN_PATH);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    let start = text.find("        255: [").expect("the handshake table");
    let mut table = BTreeMap::new();
    for line in text[start..].lines().skip(1) {
        let t = line.trim();
        if t.starts_with(']') {
            break;
        }
        let (key, value) = t.split_once(':').expect("an entry");
        let unquote = |s: &str| s.trim().trim_end_matches(',').trim_matches('"').to_owned();
        table.insert(unquote(key), hex::decode(unquote(value)).expect("hex"));
    }
    for name in ["channelHello", "channelAccept", "pair"] {
        assert!(table.contains_key(name), "no golden {name}");
    }
    table
}

fn sample(ty: MessageType) -> Message {
    ProtocolSamples::all().iter().find(|m| m.ty() == ty).unwrap().clone()
}

/// `frame` with its timestamp (bytes 12..20) and sequence (8..12) cleared: a channel stamps both, the
/// golden frames have zeros.
fn unstamped(mut frame: Vec<u8>) -> Vec<u8> {
    frame[8..20].fill(0);
    frame
}

#[tokio::test]
async fn a_channel_frames_the_handshake_samples_as_the_golden_bytes() {
    let golden = golden_handshake();
    for (ty, name) in [
        (MessageType::ChannelHello, "channelHello"),
        (MessageType::ChannelAccept, "channelAccept"),
        (MessageType::Pair, "pair"),
    ] {
        let (a, mut b) = memory_pair();
        let channel = MessageChannel::new(a, "golden");
        channel.send(&sample(ty)).unwrap();
        let frame = read_frame(&mut b).await.unwrap();
        assert_eq!(frame[8..12], [0; 4], "{name}: the first frame is sequence 0");
        assert_ne!(frame[12..20], [0; 8], "{name}: stamped with the clock");
        assert_eq!(hex::encode(unstamped(frame)), hex::encode(&golden[name]), "{name}");
    }
}

/// The roles' own frames, from the sample inputs: the dialer's pairing `Pair` and `ChannelHello`
/// (realtime, all-zero HMAC), and the acceptor's `ChannelAccept`.
#[tokio::test]
async fn the_roles_write_the_golden_handshake_frames() {
    let golden = golden_handshake();
    let Message::Pair(pair) = sample(MessageType::Pair) else { unreachable!() };
    let Message::ChannelHello(sample_hello) = sample(MessageType::ChannelHello) else { unreachable!() };

    // The dialer pairing with the sample secret and host id, offering the sample versions.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let dialer = LinkDialer::new(CapturingDialer(tx)).versions(sample_hello.versions.clone());
    let opening = tokio::spawn(async move { dialer.open_pairing(&pair).await.err() });
    let mut realtime = rx.recv().await.unwrap();
    let hello_frame = read_frame(&mut realtime).await.unwrap();
    let pair_frame = read_frame(&mut realtime).await.unwrap();
    let Message::ChannelHello(hello) = MessageCodec::decode(&hello_frame).unwrap().message else { panic!() };
    assert_eq!(hello.versions, sample_hello.versions);
    assert_eq!(hello.connection_kind, ConnectionKind::Realtime);
    assert_eq!(hello.hmac, ChannelAuth::PAIRING_MAC);
    assert_eq!(pair_frame[8..12], 1u32.to_le_bytes(), "Pair follows ChannelHello on realtime");
    assert_eq!(hex::encode(unstamped(pair_frame)), hex::encode(&golden["pair"]));
    // Its video hello is the sample's but for the token and HMAC (random and secret-keyed here).
    let mut video = rx.recv().await.unwrap();
    let video_frame = read_frame(&mut video).await.unwrap();
    let Message::ChannelHello(mut video_hello) = MessageCodec::decode(&video_frame).unwrap().message else { panic!() };
    assert!(ChannelAuth::is_valid(&video_hello, &sample_pair_secret()));
    video_hello.session_token = sample_hello.session_token;
    video_hello.hmac = sample_hello.hmac;
    assert_eq!(
        hex::encode(MessageCodec::encode(&Message::ChannelHello(video_hello), 0, 0, None, None)),
        hex::encode(&golden["channelHello"])
    );
    drop((realtime, video, rx));
    let _ = opening.await;

    // The acceptor answering a hello that offers the sample versions, with the sample versions of its own.
    let secret = secret();
    let options = AcceptorOptions { versions: sample_hello.versions.clone(), ..AcceptorOptions::default() };
    let acceptor = Acceptor::new(store(&[("PEER", &secret)]), options);
    let mut raw = acceptor.raw_bytes();
    let hello = ChannelAuth::hello(ConnectionKind::Realtime, token(), Some(&secret), &sample_hello.versions);
    raw.write_all(&MessageCodec::encode(&Message::ChannelHello(hello), 0, 0, None, None)).await.unwrap();
    let accept_frame = read_frame(&mut raw).await.unwrap();
    assert_eq!(hex::encode(unstamped(accept_frame)), hex::encode(&golden["channelAccept"]));
}

/// The `ChannelHello` HMAC against a vector computed outside this code: Python's `hmac`/`hashlib` over the
/// golden `channelHello` payload up to its HMAC, keyed by `Pair`'s sample secret (bytes 200..<232). Every
/// other test computes and checks the HMAC with the same Rust code; this ties it to Swift's input
/// (`ChannelHello.authenticatedBytes`: version list, kind, token).
#[test]
fn the_channel_hello_hmac_matches_an_independent_vector() {
    let Message::ChannelHello(hello) = sample(MessageType::ChannelHello) else { unreachable!() };
    let golden = &golden_handshake()["channelHello"];
    let payload = &golden[HEADER_SIZE..];
    let authenticated = hello.authenticated_bytes();
    assert_eq!(authenticated, payload[..payload.len() - ChannelHello::MAC_SIZE], "the golden payload minus its HMAC");
    assert_eq!(hex::encode(&authenticated), "02030102030405060708040b0c0d0e0f10111201000102030405060708090a0b0c0d0e0f");
    let secret = sample_pair_secret();
    assert_eq!(secret.to_vec(), (200u8..232).collect::<Vec<_>>());
    let mac = ChannelAuth::mac(&secret, &hello);
    assert_eq!(hex::encode(mac), "e1645531f3cb91af42a546d4055554a2c73157d927bf81425db1cd5c87f2f214");
    let mut signed = hello.clone();
    signed.hmac = mac;
    assert!(ChannelAuth::is_valid(&signed, &secret));
}

fn sample_pair_secret() -> [u8; 32] {
    let Message::Pair(pair) = sample(MessageType::Pair) else { unreachable!() };
    pair.secret
}

/// Hands the far end of each dial to the test, which reads the raw bytes.
struct CapturingDialer(tokio::sync::mpsc::UnboundedSender<tokio::io::DuplexStream>);

impl StreamDialer for CapturingDialer {
    type Stream = tokio::io::DuplexStream;
    async fn dial(&self, _kind: ConnectionKind) -> Result<Self::Stream, TransportError> {
        let (near, far) = memory_pair();
        self.0.send(far).map_err(|_| TransportError::Closed)?;
        Ok(near)
    }
}
