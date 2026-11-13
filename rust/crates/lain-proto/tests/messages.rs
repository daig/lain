//! Ports of Swift's `MessageTests.swift` and `ConstantsTests.swift`, plus the brief's strictness checks
//! (string cutting, float bit patterns, arbitrary chunking).

use lain_proto::*;
use proptest::prelude::*;

fn encode(m: &Message, seq: u32, ts: u64) -> Vec<u8> {
    MessageCodec::encode(m, seq, ts, None, None)
}

fn ping() -> Message {
    Message::Ping(Ping { id: 1, sent_at_ns: 2 })
}

fn malformed(s: &str) -> ProtocolError {
    ProtocolError::Malformed(s.into())
}

// MARK: - Constants

#[test]
fn magic_is_la_in_little_endian() {
    assert_eq!(MAGIC.to_le_bytes(), [0x41, 0x4C]);
    assert_eq!(HEADER_SIZE, 24);
    assert_eq!(FrameHeader::SIZE, 24);
}

#[test]
fn versions_and_bonjour_service() {
    assert_eq!(SUPPORTED_VERSIONS, [4, 5, 6, 7]);
    assert_eq!(NEWEST_VERSION, 7);
    assert_eq!(HANDSHAKE_VERSION, 0xFF);
    assert!(*LEGACY_VERSIONS.end() < SUPPORTED_VERSIONS[0]);
    assert_eq!(BONJOUR_SERVICE_TYPE, "_lain._tcp");
    assert_eq!(USB_PORT, 47800);
    assert_eq!(VERSION_CAP_ENV, "LAIN_PROTOCOL_MAX");
}

#[test]
fn default_versions() {
    assert_eq!(MessageType::Ping.default_version(), NEWEST_VERSION);
    assert_eq!(MessageType::Error.default_version(), NEWEST_VERSION);
    assert_eq!(MessageType::ChannelHello.default_version(), HANDSHAKE_VERSION);
    assert_eq!(encode(&ping(), 0, 0)[2], NEWEST_VERSION);
    assert_eq!(MessageCodec::encode(&ping(), 0, 0, None, Some(3))[2], 3);
}

// MARK: - Round trips

#[test]
fn samples_cover_every_message_type() {
    let mut types: Vec<MessageType> = ProtocolSamples::all().iter().map(Message::ty).collect();
    types.sort();
    let mut all = MessageType::ALL.to_vec();
    all.sort();
    assert_eq!(types, all);
    for t in MessageType::ALL {
        assert_eq!(MessageType::from_raw(t.raw()), Some(*t));
    }
}

#[test]
fn round_trips() {
    for m in ProtocolSamples::all() {
        let bytes = encode(m, 42, 987_654_321);
        let env = MessageCodec::decode(&bytes).unwrap();
        assert_eq!(&env.message, m);
        assert_eq!(env.header.ty, m.ty());
        assert_eq!(env.header.sequence, 42);
        assert_eq!(env.header.timestamp_ns, 987_654_321);
        assert_eq!(env.header.payload_length as usize, bytes.len() - HEADER_SIZE);
    }
}

#[test]
fn every_truncation_is_rejected() {
    for m in ProtocolSamples::all() {
        let bytes = encode(m, 1, 1);
        for n in 0..bytes.len() {
            assert!(MessageCodec::decode(&bytes[..n]).is_err(), "{} cut at {n}", m.ty());
        }
    }
}

/// The header claims a shorter payload (as if the sender were buggy): the payload decoder must hit the end
/// of its slice rather than read into the next message.
#[test]
fn truncated_payload_with_consistent_length_is_rejected() {
    for m in ProtocolSamples::all() {
        let mut bytes = encode(m, 1, 1);
        let len = bytes.len() - HEADER_SIZE;
        if len == 0 {
            continue;
        }
        bytes.pop();
        bytes[20..24].copy_from_slice(&((len - 1) as u32).to_le_bytes());
        assert!(MessageCodec::decode(&bytes).is_err(), "{}", m.ty());
    }
}

#[test]
fn keyframe_flag_follows_payload() {
    let key = ProtocolSamples::all().iter().find(|m| m.ty() == MessageType::VideoFrame).unwrap();
    assert_eq!(MessageCodec::decode(&encode(key, 0, 0)).unwrap().header.flags, HeaderFlags::KEYFRAME);
    assert_eq!(MessageCodec::decode(&encode(&ping(), 0, 0)).unwrap().header.flags, HeaderFlags::EMPTY);
    // Explicit flags replace the implied ones.
    let flags = HeaderFlags::KEYFRAME | HeaderFlags::REFINEMENT;
    let b = MessageCodec::encode(key, 0, 0, Some(flags), None);
    assert_eq!(MessageCodec::decode(&b).unwrap().header.flags, flags);
}

#[test]
fn channel_hello_size_follows_its_version_list() {
    let m = ProtocolSamples::all().iter().find(|m| m.ty() == MessageType::ChannelHello).unwrap();
    // count, two (version, digest[8]) entries, kind, token[16], hmac[32]
    assert_eq!(encode(m, 0, 0).len(), HEADER_SIZE + 1 + 2 * 9 + 1 + 16 + 32);
}

#[test]
fn authenticated_bytes_are_everything_before_the_hmac() {
    let Message::ChannelHello(hello) = &ProtocolSamples::all()[0] else { panic!() };
    let frame = encode(&ProtocolSamples::all()[0], 0, 0);
    let payload = &frame[HEADER_SIZE..];
    assert_eq!(hello.authenticated_bytes(), payload[..payload.len() - ChannelHello::MAC_SIZE]);
}

// MARK: - Header validation

fn header_ping() -> Vec<u8> {
    encode(&ping(), 0x0102_0304, 0x1122_3344_5566_7788)
}

fn mutated(offset: usize, value: u8) -> Vec<u8> {
    let mut b = header_ping();
    b[offset] = value;
    b
}

#[test]
fn layout_is_little_endian_per_spec() {
    #[rustfmt::skip]
    let want = [
        0x41, 0x4C,                                      // magic 0x4C41
        NEWEST_VERSION, 0x05,                            // version, type = Ping
        0x00, 0x00, 0x00, 0x00,                          // flags, reserved
        0x04, 0x03, 0x02, 0x01,                          // sequence
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,  // timestamp
        12, 0, 0, 0,                                     // payload length
    ];
    assert_eq!(header_ping()[..24], want);
}

#[test]
fn bad_magic() {
    assert_eq!(MessageCodec::decode(&mutated(0, 0x42)), Err(ProtocolError::BadMagic(0x4C42)));
}

#[test]
fn versions_this_build_doesnt_implement_are_reported() {
    for legacy in LEGACY_VERSIONS {
        assert_eq!(MessageCodec::decode(&mutated(2, legacy)), Err(ProtocolError::VersionMismatch { remote: legacy }));
    }
    let newer = NEWEST_VERSION + 1;
    assert_eq!(MessageCodec::decode(&mutated(2, newer)), Err(ProtocolError::VersionMismatch { remote: newer }));
    assert_eq!(MessageCodec::decode(&mutated(2, 0)), Err(ProtocolError::VersionMismatch { remote: 0 }));
}

#[test]
fn answers_a_legacy_peer_in_its_own_version() {
    let why = "lain here speaks protocol v3–v4";
    let v2 = MessageCodec::legacy_version_mismatch(2, why, 0, 0);
    assert_eq!(v2[2], 2);
    assert_eq!(v2[3], MessageType::Error.raw());
    // v1/v2's ErrorMessage layout: u16 code, then a u16-prefixed UTF-8 message.
    let mut want = vec![1, 0, why.len() as u8, 0];
    want.extend_from_slice(why.as_bytes());
    assert_eq!(v2[HEADER_SIZE..], want);
    assert_eq!(MessageCodec::decode(&v2), Err(ProtocolError::VersionMismatch { remote: 2 }));
    // A legacy peer answering our handshake frames in our framing is readable here.
    let mut ours = v2.clone();
    ours[2] = HANDSHAKE_VERSION;
    assert_eq!(
        MessageCodec::decode(&ours).unwrap().message,
        Message::Error(ErrorMessage { code: ErrorCode::VERSION_MISMATCH, message: why.into() })
    );
}

#[test]
fn unknown_and_reserved_types() {
    assert_eq!(MessageCodec::decode(&mutated(3, 0x22)), Err(ProtocolError::UnknownType(0x22)));
    assert_eq!(MessageCodec::decode(&mutated(3, 0xFE)), Err(ProtocolError::UnknownType(0xFE)));
    // (0x30 and 0x31, the audio messages, came back in v6.)
    for pruned in [0x03, 0x04, 0x08, 0x09, 0x0A, 0x23, 0x60, 0x61] {
        assert_eq!(MessageCodec::decode(&mutated(3, pruned)), Err(ProtocolError::UnknownType(pruned)));
    }
}

#[test]
fn reserved_field_must_be_zero() {
    assert_eq!(MessageCodec::decode(&mutated(6, 1)), Err(ProtocolError::ReservedNonZero));
    assert_eq!(MessageCodec::decode(&mutated(7, 1)), Err(ProtocolError::ReservedNonZero));
}

#[test]
fn oversized_payload_is_rejected_before_buffering() {
    assert_eq!(MessageCodec::decode(&mutated(23, 0xFF)), Err(ProtocolError::PayloadTooLarge(0xFF00_000C)));
    // At the limit it's only the length that's wrong.
    let mut b = header_ping();
    b[20..24].copy_from_slice(&FrameHeader::MAX_PAYLOAD_LENGTH.to_le_bytes());
    assert_eq!(MessageCodec::decode(&b), Err(ProtocolError::Truncated));
    let mut parser = FrameParser::new();
    parser.append(&mutated(23, 0xFF)[..24]);
    assert_eq!(parser.next(), Err(ProtocolError::PayloadTooLarge(0xFF00_000C)));
}

#[test]
fn trailing_bytes_are_rejected() {
    let mut b = header_ping();
    b.push(0);
    b[20] += 1;
    assert_eq!(MessageCodec::decode(&b), Err(malformed("1 trailing bytes")));
    // Bytes beyond the declared length.
    let mut b = header_ping();
    b.push(0);
    assert_eq!(MessageCodec::decode(&b), Err(malformed("length mismatch")));
}

// MARK: - Payload validation

#[test]
fn unknown_enum_value() {
    let mut b = encode(&Message::ReleaseAll(ReleaseAll { reason: ReleaseReason::FocusLost }), 0, 0);
    b[24] = 9;
    assert_eq!(MessageCodec::decode(&b), Err(malformed("Reason 9")));
    // Every enum field of every sample.
    let hello = encode(&ProtocolSamples::all()[0], 0, 0);
    let mut bad = hello.clone();
    bad[HEADER_SIZE + 1 + 18] = 3; // connection kind
    assert_eq!(MessageCodec::decode(&bad), Err(malformed("ConnectionKind 3")));
}

#[test]
fn bool_must_be_zero_or_one() {
    let mut b = encode(&Message::CursorSelect(CursorSelect { shape_id: 1, visible: true }), 0, 0);
    b[28] = 2;
    assert_eq!(MessageCodec::decode(&b), Err(malformed("bool")));
    b[28] = 0xFF;
    assert_eq!(MessageCodec::decode(&b), Err(malformed("bool")));
}

#[test]
fn cursor_pixel_count_must_match_size() {
    let bad = CursorShape {
        shape_id: 1,
        pixel_width: 4,
        pixel_height: 4,
        scale: 2,
        hotspot_x: 0.0,
        hotspot_y: 0.0,
        pixels: vec![0],
    };
    assert_eq!(MessageCodec::decode(&encode(&bad.into(), 0, 0)), Err(malformed("cursor pixel count")));
}

#[test]
fn invalid_utf8() {
    let mut b = encode(&Message::Error(ErrorMessage { code: ErrorCode::INTERNAL, message: "ab".into() }), 0, 0);
    *b.last_mut().unwrap() = 0xFF;
    assert_eq!(MessageCodec::decode(&b), Err(malformed("utf8")));
}

#[test]
fn huge_declared_count_is_truncated_not_allocated() {
    let mut b = encode(&Message::DisplayLayout(DisplayLayout { displays: vec![] }), 0, 0);
    b[24] = 0xFF; // 255 displays declared, none present
    assert_eq!(MessageCodec::decode(&b), Err(ProtocolError::Truncated));
}

/// Swift cuts at 65535 UTF-8 bytes, even inside a character: `Array(v.utf8.prefix(65535))`.
#[test]
fn strings_are_cut_at_65535_bytes_like_swift() {
    let long = "a".repeat(65534) + "é" + "tail";
    let mut w = ByteWriter::new(NEWEST_VERSION);
    w.string(&long);
    let bytes = w.into_bytes();
    assert_eq!(bytes.len(), 2 + 65535);
    assert_eq!(bytes[..2], [0xFF, 0xFF]);
    assert_eq!(bytes[2 + 65534], 0xC3); // the first byte of é, without its second
    assert_eq!(ByteReader::new(&bytes, NEWEST_VERSION).string(), Err(malformed("utf8")));
    // At exactly the limit nothing is cut.
    let exact = "é".repeat(32767) + "a";
    let mut w = ByteWriter::new(NEWEST_VERSION);
    w.string(&exact);
    assert_eq!(ByteReader::new(w.bytes(), NEWEST_VERSION).string().unwrap(), exact);
}

#[test]
fn floats_travel_as_bit_patterns() {
    let nan32 = f32::from_bits(0x7FC0_1234);
    let nan64 = f64::from_bits(0x7FF8_0000_DEAD_BEEF);
    let m = Message::PointerMove(PointerMove { x: nan64, y: -0.0, dx: nan32, dy: f32::INFINITY, buttons: 0 });
    let b = encode(&m, 0, 0);
    let Message::PointerMove(p) = MessageCodec::decode(&b).unwrap().message else { panic!() };
    assert_eq!(p.x.to_bits(), nan64.to_bits());
    assert_eq!(p.y.to_bits(), (-0.0f64).to_bits());
    assert_eq!(p.dx.to_bits(), nan32.to_bits());
    assert_eq!(p.dy, f32::INFINITY);
    assert_eq!(b[HEADER_SIZE..HEADER_SIZE + 8], 0x7FF8_0000_DEAD_BEEFu64.to_le_bytes());
}

#[test]
fn counts_above_255_are_cut() {
    let d = LayoutDisplay { display_id: 1, x: 0.0, y: 0.0, width: 1.0, height: 1.0, is_streamed: false };
    let m = Message::DisplayLayout(DisplayLayout { displays: vec![d; 300] });
    let Message::DisplayLayout(back) = MessageCodec::decode(&encode(&m, 0, 0)).unwrap().message else { panic!() };
    assert_eq!(back.displays.len(), 255);
}

// MARK: - Error codes

/// `Error` in both layers: any code in a handshake frame, only known codes in a session frame.
#[test]
fn busy_round_trips_and_unknown_codes_only_pass_in_handshake_frames() {
    let busy = Message::Error(ErrorMessage { code: ErrorCode::BUSY, message: "a USB session is live".into() });
    let bytes = encode(&busy, 0, 0);
    assert_eq!(bytes[24..26], [6, 0]);
    assert_eq!(MessageCodec::decode(&bytes).unwrap().message, busy);
    let mut unknown = bytes.clone();
    unknown[24] = 7;
    assert_eq!(MessageCodec::decode(&unknown), Err(malformed("error code 7")));
    unknown[2] = HANDSHAKE_VERSION; // a newer peer's refusal still arrives
    assert_eq!(
        MessageCodec::decode(&unknown).unwrap().message,
        Message::Error(ErrorMessage { code: ErrorCode(7), message: "a USB session is live".into() })
    );
    assert_eq!(ErrorCode(7).to_string(), "code 7");
    assert_eq!(ErrorCode::BUSY.to_string(), "busy");
    assert!(!ErrorCode(3).is_known() && !ErrorCode(4).is_known());
}

// MARK: - Stream parsing

fn stream() -> Vec<u8> {
    ProtocolSamples::all().iter().enumerate().flat_map(|(i, m)| encode(m, i as u32, i as u64 * 10)).collect()
}

fn parse_chunks(stream: &[u8], cuts: impl Iterator<Item = usize>) -> Vec<Envelope> {
    let mut parser = FrameParser::new();
    let mut out = vec![];
    let mut i: usize = 0;
    for len in cuts.chain(std::iter::once(usize::MAX)) {
        let end = i.saturating_add(len).min(stream.len());
        parser.append(&stream[i..end]);
        i = end;
        while let Some(env) = parser.next().unwrap() {
            out.push(env);
        }
        if i == stream.len() {
            break;
        }
    }
    assert_eq!(parser.buffered_byte_count(), 0);
    out
}

fn check(got: &[Envelope]) {
    let messages: Vec<&Message> = got.iter().map(|e| &e.message).collect();
    assert_eq!(messages, ProtocolSamples::all().iter().collect::<Vec<_>>());
    let sequences: Vec<u32> = got.iter().map(|e| e.header.sequence).collect();
    assert_eq!(sequences, (0..ProtocolSamples::all().len() as u32).collect::<Vec<_>>());
}

#[test]
fn reassembles_any_chunking() {
    let s = stream();
    for size in [1, 7, 24, 25, 1000, 1 << 20] {
        check(&parse_chunks(&s, std::iter::repeat(size)));
    }
}

#[test]
fn compaction_keeps_the_stream_intact() {
    // Over 1 MiB of frames, so the parser compacts its buffer mid-stream.
    let frame = VideoFrame {
        frame_id: 1,
        config_id: 1,
        capture_time_ns: 0,
        encode_done_ns: 0,
        is_keyframe: false,
        data: vec![7; 300_000],
    };
    let one = encode(&frame.into(), 0, 0);
    let s: Vec<u8> = std::iter::repeat_n(one.as_slice(), 8).flatten().copied().collect();
    let mut parser = FrameParser::new();
    let mut n = 0;
    for chunk in s.chunks(100_003) {
        parser.append(chunk);
        while let Some(env) = parser.next().unwrap() {
            assert_eq!(env.message.ty(), MessageType::VideoFrame);
            n += 1;
        }
    }
    assert_eq!(n, 8);
    assert_eq!(parser.buffered_byte_count(), 0);
}

#[test]
fn garbage_is_fatal() {
    let mut parser = FrameParser::new();
    parser.append(&[0xAB; 30]);
    assert_eq!(parser.next(), Err(ProtocolError::BadMagic(0xABAB)));
}

proptest! {
    #[test]
    fn reassembles_random_chunking(cuts in proptest::collection::vec(1usize..200, 1..400)) {
        let s = stream();
        check(&parse_chunks(&s, cuts.into_iter().cycle()));
    }
}
