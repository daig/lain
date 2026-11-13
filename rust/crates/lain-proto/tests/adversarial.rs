//! Adversarial strictness tests: each decoding rule of the Swift codec, including the order in which
//! checks fail when two errors are present (Swift: `FrameHeader.decode`, `Messages.swift`, `Versions.swift`).
//! Written by wave 1's independent test-strength reviewer, and kept as the regression net for every
//! strictness rule the golden bytes can't reach.

use lain_proto::*;

fn mal(s: &str) -> ProtocolError {
    ProtocolError::Malformed(s.into())
}
fn dec(ty: MessageType, p: &[u8], v: u8) -> Result<Message> {
    Message::decode(ty, p, v)
}
fn ping_frame() -> Vec<u8> {
    MessageCodec::encode(&Message::Ping(Ping { id: 1, sent_at_ns: 2 }), 0, 0, None, Some(4))
}
fn hdr(f: impl Fn(&mut Vec<u8>)) -> Result<FrameHeader> {
    let mut b = ping_frame();
    f(&mut b);
    FrameHeader::decode(&b)
}

#[test]
fn header_check_order() {
    // short + bad magic -> truncated
    let mut b = ping_frame();
    b[0] = 0;
    assert_eq!(FrameHeader::decode(&b[..23]), Err(ProtocolError::Truncated));
    assert_eq!(FrameHeader::decode(&[]), Err(ProtocolError::Truncated));
    // magic before version
    assert_eq!(
        hdr(|b| {
            b[0] = 0;
            b[2] = 2;
        }),
        Err(ProtocolError::BadMagic(0x4C00))
    );
    // version before type
    assert_eq!(
        hdr(|b| {
            b[2] = 2;
            b[3] = 0x22;
        }),
        Err(ProtocolError::VersionMismatch { remote: 2 })
    );
    // type before reserved
    assert_eq!(
        hdr(|b| {
            b[3] = 0x22;
            b[6] = 1;
        }),
        Err(ProtocolError::UnknownType(0x22))
    );
    // reserved before size
    assert_eq!(
        hdr(|b| {
            b[6] = 1;
            b[23] = 0xFF;
        }),
        Err(ProtocolError::ReservedNonZero)
    );
    // flags are not validated
    let h = hdr(|b| {
        b[4] = 0xFF;
        b[5] = 0xFF;
    })
    .unwrap();
    assert_eq!(h.flags, HeaderFlags(0xFFFF));
    // max payload exactly accepted at header level; +1 rejected
    assert!(hdr(|b| b[20..24].copy_from_slice(&(32u32 << 20).to_le_bytes())).is_ok());
    assert_eq!(
        hdr(|b| b[20..24].copy_from_slice(&((32u32 << 20) + 1).to_le_bytes())),
        Err(ProtocolError::PayloadTooLarge((32 << 20) + 1))
    );
    // the supported versions and 255 accepted; 3 (below the floor), 8, 254 rejected
    for v in [4u8, 5, 6, 7, 255] {
        assert!(hdr(|b| b[2] = v).is_ok());
    }
    for v in [3u8, 8, 254, 0x7F] {
        assert_eq!(hdr(|b| b[2] = v), Err(ProtocolError::VersionMismatch { remote: v }));
    }
    // reading beyond header bytes doesn't matter (slice longer than 24)
    assert!(FrameHeader::decode(&[ping_frame(), vec![0xAA; 10]].concat()).is_ok());
}

#[test]
fn codec_length() {
    let b = ping_frame();
    assert_eq!(MessageCodec::decode(&b[..b.len() - 1]), Err(ProtocolError::Truncated));
    assert_eq!(MessageCodec::decode(&[b.clone(), vec![0]].concat()), Err(mal("length mismatch")));
    // header-level error beats length error
    let mut c = b.clone();
    c[6] = 1;
    c.pop();
    assert_eq!(MessageCodec::decode(&c), Err(ProtocolError::ReservedNonZero));
}

#[test]
fn existence_per_layer() {
    let setup = ProtocolSamples::all().iter().find(|m| m.ty() == MessageType::HostSetup).unwrap();
    let mut w = ByteWriter::new(4);
    setup.encode_payload(&mut w);
    let p = w.into_bytes();
    assert_eq!(dec(MessageType::HostSetup, &p, 3), Err(ProtocolError::UnknownType(0x0F)));
    let stats = ProtocolSamples::all().iter().find(|m| m.ty() == MessageType::HostStats).unwrap();
    let mut w = ByteWriter::new(5);
    stats.encode_payload(&mut w);
    let s = w.into_bytes();
    assert_eq!(dec(MessageType::HostStats, &s, 4), Err(ProtocolError::UnknownType(0x11)));
    assert!(dec(MessageType::HostStats, &s, 5).is_ok());
    assert_eq!(dec(MessageType::HostStats, &s[..s.len() - 1], 5), Err(ProtocolError::Truncated));
    assert_eq!(dec(MessageType::StatsRequest, &[0xFA, 0, 0], 5), Err(ProtocolError::Truncated));
    assert_eq!(dec(MessageType::HostSetup, &p, 255), Err(ProtocolError::UnknownType(0x0F)));
    assert!(dec(MessageType::HostSetup, &p, 4).is_ok());
    for ty in [MessageType::ChannelHello, MessageType::ChannelAccept, MessageType::Pair] {
        for v in [4, 5, 6, 7] {
            assert_eq!(dec(ty, &[], v), Err(ProtocolError::UnknownType(ty.raw())));
        }
    }
    for ty in MessageType::ALL.iter().copied().filter(|t| !t.is_handshake()) {
        assert_eq!(dec(ty, &[], 255), Err(ProtocolError::UnknownType(ty.raw())), "{ty}");
    }
    // existence check precedes payload parsing (empty payload is truncated otherwise)
    // via FrameParser too
    let mut f = MessageCodec::encode(stats, 0, 0, None, Some(5));
    f[2] = 4;
    let mut parser = FrameParser::new();
    parser.append(&f);
    assert_eq!(parser.next(), Err(ProtocolError::UnknownType(0x11)));
}

#[test]
fn every_enum_field_is_checked() {
    use MessageType as T;
    // ReleaseAll
    assert_eq!(dec(T::ReleaseAll, &[4], 4), Err(mal("Reason 4")));
    // KeyframeRequest
    assert_eq!(dec(T::KeyframeRequest, &[4, 0, 0, 0, 0], 4), Err(mal("Reason 4")));
    // Gesture kind / phase
    assert_eq!(dec(T::Gesture, &[2, 0, 0, 0, 0, 0], 4), Err(mal("Kind 2")));
    assert_eq!(dec(T::Gesture, &[0, 6, 0, 0, 0, 0], 4), Err(mal("GesturePhase 6")));
    // Scroll phase / momentum
    assert_eq!(dec(T::Scroll, &[0, 0, 0, 0, 0, 0, 0, 0, 6, 0], 4), Err(mal("GesturePhase 6")));
    assert_eq!(dec(T::Scroll, &[0, 0, 0, 0, 0, 0, 0, 0, 0, 4], 4), Err(mal("MomentumPhase 4")));
    // PointerButton
    let mut pb = vec![3, 0, 1];
    pb.extend([0u8; 20]);
    assert_eq!(dec(T::PointerButton, &pb, 4), Err(mal("MouseButton 3")));
    pb[0] = 0;
    pb[1] = 2;
    assert_eq!(dec(T::PointerButton, &pb, 4), Err(mal("bool")));
    // HostSetup
    let hs = |req: u8, st: u8| {
        let mut v = vec![1, req, st, 0, 0, 0];
        v.truncate(6);
        v
    };
    assert_eq!(dec(T::HostSetup, &hs(4, 0), 4), Err(mal("Requirement 4")));
    assert_eq!(dec(T::HostSetup, &hs(0, 3), 4), Err(mal("State 3")));
    assert!(dec(T::HostSetup, &hs(3, 2), 4).is_ok());
    assert_eq!(dec(T::HostSetup, &[0, 0, 0, 2], 4), Err(mal("bool")));
    assert_eq!(dec(T::HostSetup, &[255], 4), Err(ProtocolError::Truncated));
    // VideoConfig codec / chroma
    let vc = |codec: u8, chroma: u8, fr: u8| {
        let mut v = vec![0, 0, 0, 0, codec, chroma, 8];
        v.extend([0; 8]);
        v.extend([fr, 0, 0, 0, 0]);
        v
    };
    assert!(dec(T::VideoConfig, &vc(1, 1, 0), 4).is_ok());
    assert_eq!(dec(T::VideoConfig, &vc(0, 1, 0), 4), Err(mal("VideoCodec 0")));
    assert_eq!(dec(T::VideoConfig, &vc(1, 2, 0), 4), Err(mal("ChromaFormat 2")));
    assert_eq!(dec(T::VideoConfig, &vc(1, 3, 2), 4), Err(mal("bool")));
    let mut many = vc(1, 1, 0);
    *many.last_mut().unwrap() = 255;
    assert_eq!(dec(T::VideoConfig, &many, 4), Err(ProtocolError::Truncated));
    // Hello keyboard type
    let mut h = vec![0, 0];
    h.extend([0u8; 4 + 4 + 1 + 2 + 4]);
    h.push(4);
    assert_eq!(dec(T::Hello, &h, 3), Err(mal("KeyboardType 4")));
    // HelloAck enums from the sample bytes
    let ack = ProtocolSamples::all().iter().find(|m| m.ty() == T::HelloAck).unwrap();
    let mut w = ByteWriter::new(4);
    ack.encode_payload(&mut w);
    let p = w.into_bytes();
    let mut q = p.clone();
    q[0] = 2;
    assert_eq!(dec(T::HelloAck, &q, 4), Err(mal("VideoCodec 2")));
    let mut q = p.clone();
    q[1] = 0;
    assert_eq!(dec(T::HelloAck, &q, 4), Err(mal("ChromaFormat 0")));
    let mut q = p.clone();
    q[3] = 3;
    assert_eq!(dec(T::HelloAck, &q, 4), Err(mal("DisplayMode 3")));
    // KeyEvent bools
    assert_eq!(dec(T::KeyEvent, &[7, 0, 4, 0, 2, 0, 0, 0, 0, 0], 4), Err(mal("bool")));
    assert_eq!(dec(T::KeyEvent, &[7, 0, 4, 0, 0, 2, 0, 0, 0, 0], 4), Err(mal("bool")));
    // VideoFrame keyframe bool
    let mut vf = vec![0u8; 24];
    vf.push(2);
    vf.extend([0; 4]);
    assert_eq!(dec(T::VideoFrame, &vf, 4), Err(mal("bool")));
    // VideoFrame huge blob length -> truncated, no alloc
    let mut vf = vec![0u8; 24];
    vf.push(1);
    vf.extend([0xFF; 4]);
    assert_eq!(dec(T::VideoFrame, &vf, 4), Err(ProtocolError::Truncated));
    // ChannelHello connection kind
    let mut ch = vec![0u8, 3];
    ch.extend([0; 48]);
    assert_eq!(dec(T::ChannelHello, &ch, 255), Err(mal("ConnectionKind 3")));
}

#[test]
fn display_layout_count_check_precedes_fields() {
    use MessageType as T;
    let mut d = vec![1u8];
    d.extend([0; 36]);
    assert_eq!(dec(T::DisplayLayout, &d, 4), Err(ProtocolError::Truncated));
    d.push(2);
    assert_eq!(dec(T::DisplayLayout, &d, 4), Err(mal("bool")));
    d[37] = 1;
    assert!(dec(T::DisplayLayout, &d, 4).is_ok());
    // 2 declared, 1 present + 36 bytes beyond: truncated before parsing first
    let mut d2 = vec![2u8];
    d2.extend([0; 37]);
    d2[37] = 9;
    d2.extend([0; 36]);
    assert_eq!(dec(T::DisplayLayout, &d2, 4), Err(ProtocolError::Truncated));
}

#[test]
fn cursor_and_strings() {
    use MessageType as T;
    // max dims, short blob
    let mut c = vec![0u8; 4];
    c.extend([0xFF, 0xFF, 0xFF, 0xFF, 1]);
    c.extend([0; 8]);
    c.extend([0, 0, 0, 0]);
    assert_eq!(dec(T::CursorShape, &c, 4), Err(mal("cursor pixel count")));
    // utf8: overlong, surrogate, beyond U+10FFFF rejected; NUL accepted
    for bad in [&[0xC0u8, 0x80][..], &[0xED, 0xA0, 0x80], &[0xF4, 0x90, 0x80, 0x80], &[0x80], &[0xE2, 0x82]] {
        let mut p = vec![5u8, 0, bad.len() as u8, 0];
        p.extend(bad);
        assert_eq!(dec(T::Error, &p, 4), Err(mal("utf8")), "{bad:?}");
    }
    assert!(dec(T::Error, &[5, 0, 1, 0, 0], 4).is_ok());
    // error code check precedes the string
    assert_eq!(dec(T::Error, &[7, 0, 1, 0, 0xFF], 4), Err(mal("error code 7")));
    assert_eq!(dec(T::Error, &[7, 0, 1, 0, 0xFF], 255), Err(mal("utf8")));
    for code in [0u8, 3, 4, 7] {
        assert_eq!(dec(T::Error, &[code, 0, 0, 0], 3), Err(mal(&format!("error code {code}"))));
        assert!(dec(T::Error, &[code, 0, 0, 0], 255).is_ok());
    }
    // trailing after valid
    assert_eq!(dec(T::Error, &[5, 0, 0, 0, 1, 2], 4), Err(mal("2 trailing bytes")));
    // Pair: truncated secret
    assert_eq!(dec(T::Pair, &[0; 31], 255), Err(ProtocolError::Truncated));
}

#[test]
fn version_lists() {
    let d = [0u8; 8];
    let rd = |b: &[u8]| ByteReader::new(b, 255).version_list();
    assert_eq!(rd(&[1, 0]), Err(mal("version list"))); // check before digest read
    assert_eq!(rd(&[1, 255]), Err(mal("version list")));
    assert_eq!(rd(&[255]), Err(mal("255 versions")));
    assert_eq!(rd(&[]), Err(ProtocolError::Truncated));
    assert!(rd(&[0]).unwrap().is_empty());
    let mut sixteen = vec![16u8];
    for v in 1..=16u8 {
        sixteen.push(v);
        sixteen.extend(d);
    }
    assert_eq!(rd(&sixteen).unwrap().entries().len(), 16);
    let mut top = vec![2u8, 1];
    top.extend(d);
    top.push(254);
    top.extend(d);
    assert!(rd(&top).is_ok());
    // ChannelAccept chosen 0 with empty list; chosen in list; chosen 255 out
    assert!(dec(MessageType::ChannelAccept, &[0, 0], 255).is_ok());
    assert_eq!(dec(MessageType::ChannelAccept, &[3, 0], 255), Err(mal("chose v3 outside its list")));
    let mut a = vec![3u8, 1, 3];
    a.extend(d);
    assert!(dec(MessageType::ChannelAccept, &a, 255).is_ok());
    // list error precedes chosen check
    assert_eq!(dec(MessageType::ChannelAccept, &[9, 1, 0], 255), Err(mal("version list")));
    // ChannelHello with bad list rejected before kind
    let mut ch = vec![1u8, 0];
    ch.extend([9u8; 57]);
    assert_eq!(dec(MessageType::ChannelHello, &ch, 255), Err(mal("version list")));
}

#[test]
fn parser_behaviour() {
    let b = ping_frame();
    let mut p = FrameParser::new();
    p.append(&b[..23]);
    assert_eq!(p.next(), Ok(None));
    let mut legacy = b.clone();
    legacy[2] = 2;
    let mut p = FrameParser::new();
    p.append(&legacy[..24]);
    assert_eq!(p.next(), Err(ProtocolError::VersionMismatch { remote: 2 }));
    // payload error surfaces only when complete
    let mut bad = b.clone();
    bad[2] = 4;
    bad[3] = 0x55; // releaseAll declared 12 bytes
    let mut p = FrameParser::new();
    p.append(&bad[..30]);
    assert_eq!(p.next(), Ok(None));
    p.append(&bad[30..]);
    assert!(matches!(p.next(), Err(ProtocolError::Malformed(_))));
    // trailing garbage after a good frame: first OK, then error
    let mut p = FrameParser::new();
    p.append(&b);
    p.append(&[0u8; 24]);
    assert!(p.next().unwrap().is_some());
    assert_eq!(p.next(), Err(ProtocolError::BadMagic(0)));
    // zero-length payload message with a 1-byte declared payload of ping
    let mut p = FrameParser::new();
    p.append(&b);
    p.append(&b);
    assert!(p.next().unwrap().is_some());
    assert!(p.next().unwrap().is_some());
    assert_eq!(p.next(), Ok(None));
    assert_eq!(p.buffered_byte_count(), 0);
}
