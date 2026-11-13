//! Ports of Swift's `VersioningTests.swift` (all but `GoldenBytesTests`, which is `golden.rs`): layers,
//! version lists, fields added later (the since machinery), features.

use lain_proto::*;

fn malformed(s: &str) -> ProtocolError {
    ProtocolError::Malformed(s.into())
}

fn sample(ty: MessageType) -> &'static Message {
    ProtocolSamples::all().iter().find(|m| m.ty() == ty).unwrap()
}

// MARK: - Layers

#[test]
fn handshake_messages_exist_only_in_handshake_frames() {
    for &ty in MessageType::ALL {
        assert_eq!(ty.exists_in(HANDSHAKE_VERSION), ty.is_handshake(), "{ty}");
        for &v in SUPPORTED_VERSIONS {
            assert_eq!(ty.exists_in(v), ty.is_session() && ty.since() <= v, "{ty} v{v}");
        }
    }
    assert!(MessageType::Error.is_handshake() && MessageType::Error.is_session());
}

#[test]
fn stats_are_version_five_messages() {
    for ty in [MessageType::StatsRequest, MessageType::HostStats] {
        let m = sample(ty);
        assert_eq!(
            MessageCodec::lower(m, 4, 0, 0, None),
            Lowered::Unrepresentable(format!("{ty} doesn't exist in v4"))
        );
        assert!(MessageCodec::lower(m, 5, 0, 0, None).bytes().is_some());
        let mut v4 = MessageCodec::encode(m, 0, 0, None, Some(5));
        v4[2] = 4; // a v4 peer never sends it, and a v4 frame can't carry it
        assert_eq!(MessageCodec::decode(&v4), Err(ProtocolError::UnknownType(ty.raw())));
    }
}

#[test]
fn session_messages_cant_be_handshake_framed_and_vice_versa() {
    let mut ping = MessageCodec::encode(&Message::Ping(Ping { id: 1, sent_at_ns: 2 }), 0, 0, None, None);
    ping[2] = HANDSHAKE_VERSION;
    assert_eq!(MessageCodec::decode(&ping), Err(ProtocolError::UnknownType(MessageType::Ping.raw())));
    let mut framed = MessageCodec::encode(sample(MessageType::ChannelHello), 0, 0, None, None);
    framed[2] = 4;
    assert_eq!(MessageCodec::decode(&framed), Err(ProtocolError::UnknownType(MessageType::ChannelHello.raw())));
    assert_eq!(
        MessageCodec::lower(sample(MessageType::Pair), 4, 0, 0, None),
        Lowered::Unrepresentable("pair doesn't exist in v4".into())
    );
}

#[test]
#[should_panic(expected = "hostStats doesn't exist in v4")]
fn encoding_an_unrepresentable_message_panics() {
    MessageCodec::encode(sample(MessageType::HostStats), 0, 0, None, Some(4));
}

// MARK: - Version lists

fn list(entries: &[(u8, u8)]) -> VersionList {
    VersionList::new(entries.iter().map(|&(version, d)| VersionEntry { version, digest: [d; 8] }))
}

#[test]
fn the_highest_version_with_equal_digests_is_common() {
    assert_eq!(list(&[(3, 1), (4, 1)]).highest_common(&list(&[(4, 1), (5, 1)])), Some(4));
    assert_eq!(list(&[(3, 1), (4, 1)]).highest_common(&list(&[(3, 1), (4, 2)])), Some(3)); // two builds of v4
    assert_eq!(list(&[(3, 1)]).highest_common(&list(&[(4, 1)])), None);
    assert_eq!(list(&[(3, 1), (4, 1)]).conflicting(&list(&[(3, 1), (4, 2)])), [4]);
}

#[test]
fn construction_sorts_and_keeps_the_first_of_each_version() {
    let l = list(&[(4, 1), (3, 2), (4, 3)]);
    assert_eq!(l.versions(), [3, 4]);
    assert_eq!(l.entries()[1].digest, [1; 8]);
    assert_eq!(l.oldest(), Some(3));
    assert_eq!(l.newest(), Some(4));
    assert!(VersionList::default().is_empty());
}

#[test]
fn a_cap_keeps_at_least_the_oldest() {
    assert_eq!(list(&[(3, 1), (4, 1)]).capped(Some(3)).versions(), [3]);
    assert_eq!(list(&[(3, 1), (4, 1)]).capped(Some(2)).versions(), [3]);
    assert_eq!(list(&[(3, 1), (4, 1)]).capped(None).versions(), [3, 4]);
    assert_eq!(list(&[(3, 1), (4, 1)]).to_string(), "v3–v4");
    assert_eq!(list(&[(4, 1)]).to_string(), "v4");
    assert_eq!(VersionList::default().to_string(), "none");
}

#[test]
fn the_cap_variable_is_an_integer_in_1_to_254() {
    assert_eq!(VersionList::parse_cap(None), None);
    assert_eq!(VersionList::parse_cap(Some("3")), Some(3));
    assert_eq!(VersionList::parse_cap(Some(" 4 ")), Some(4));
    assert_eq!(VersionList::parse_cap(Some("254")), Some(254));
    for bad in ["", "0", "255", "-1", "x", "3.5", "1000"] {
        assert_eq!(VersionList::parse_cap(Some(bad)), None, "{bad:?}");
    }
}

#[test]
fn the_offered_list_is_the_supported_one_capped_by_the_environment() {
    let cap = VersionList::parse_cap(std::env::var(VERSION_CAP_ENV).ok().as_deref());
    assert_eq!(VersionList::offered(), &VersionList::supported().capped(cap));
}

#[test]
fn the_supported_list_carries_this_builds_digests() {
    assert_eq!(VersionList::supported().versions(), SUPPORTED_VERSIONS);
    for e in VersionList::supported().entries() {
        assert_eq!(e.digest, SchemaDigest::compute(e.version));
    }
    assert_ne!(SchemaDigest::compute(3), SchemaDigest::compute(4));
}

fn decode_list(bytes: &[u8]) -> Result<VersionList> {
    ByteReader::new(bytes, HANDSHAKE_VERSION).version_list()
}

#[test]
fn decoding_is_strict() {
    let d = [1u8; 8];
    let cat = |parts: &[&[u8]]| parts.concat();
    assert_eq!(decode_list(&[17]), Err(malformed("17 versions")));
    assert_eq!(decode_list(&cat(&[&[2, 4], &d, &[3], &d])), Err(malformed("version list"))); // descending
    assert_eq!(decode_list(&cat(&[&[2, 3], &d, &[3], &d])), Err(malformed("version list"))); // repeated
    assert_eq!(decode_list(&cat(&[&[1, 0], &d])), Err(malformed("version list")));
    assert_eq!(decode_list(&cat(&[&[1, 0xFF], &d])), Err(malformed("version list")));
    assert_eq!(decode_list(&[1, 3, 1, 2]), Err(ProtocolError::Truncated));
    // 16 entries is the most.
    let mut sixteen = vec![16u8];
    for v in 1..=16u8 {
        sixteen.push(v);
        sixteen.extend_from_slice(&d);
    }
    assert_eq!(decode_list(&sixteen).unwrap().versions(), (1..=16).collect::<Vec<u8>>());
}

#[test]
fn a_longer_list_is_written_cut_to_sixteen() {
    let long = VersionList::new((1..=20u8).map(|version| VersionEntry { version, digest: [0; 8] }));
    let mut w = ByteWriter::new(HANDSHAKE_VERSION);
    w.version_list(&long);
    assert_eq!(w.bytes()[0], 16);
    assert_eq!(w.bytes().len(), 1 + 16 * 9);
}

#[test]
fn an_accept_must_choose_from_its_own_list() {
    let mut w = ByteWriter::new(HANDSHAKE_VERSION);
    ChannelAccept { chosen: 4, versions: list(&[(3, 1)]) }.encode(&mut w);
    let mut r = ByteReader::new(w.bytes(), HANDSHAKE_VERSION);
    assert_eq!(ChannelAccept::decode(&mut r), Err(malformed("chose v4 outside its list")));
    // 0 means no common version, and is always allowed.
    let mut w = ByteWriter::new(HANDSHAKE_VERSION);
    ChannelAccept { chosen: 0, versions: list(&[(3, 1)]) }.encode(&mut w);
    assert!(ChannelAccept::decode(&mut ByteReader::new(w.bytes(), HANDSHAKE_VERSION)).is_ok());
}

// MARK: - Fields added later

/// A field added in v4 to a message that exists from v3: the per-field lift and lower rules.
#[derive(Debug, PartialEq, Default)]
struct Widget {
    id: u32,
    /// v4, advisory: dropped for v3
    hint: String,
    /// v4, required: refused for v3
    limit: u16,
}

impl WireMessage for Widget {
    const TYPE: MessageType = MessageType::Ping; // unused: these tests call encode/decode directly
    fn encode(&self, w: &mut ByteWriter) {
        w.u32(self.id);
        w.since(4, "hint", &self.hint, &String::new(), Lowering::Drop, |w, v| w.string(v));
        w.since(4, "limit", &self.limit, &0, Lowering::Refuse, |w, v| w.u16(*v));
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { id: r.u32()?, hint: r.since(4, String::new(), |r| r.string())?, limit: r.since(4, 0, |r| r.u16())? })
    }
}

fn write(w: &Widget, version: u8) -> ByteWriter {
    let mut writer = ByteWriter::new(version);
    w.encode(&mut writer);
    writer
}

#[test]
fn an_older_version_gets_the_old_layout_and_defaults_come_back() {
    let old = write(&Widget { id: 7, ..Default::default() }, 3);
    assert_eq!(old.bytes(), [7, 0, 0, 0]);
    assert!(old.dropped().is_empty() && old.refused().is_none());
    // lift: the new fields at their defaults
    assert_eq!(Widget::decode(&mut ByteReader::new(old.bytes(), 3)).unwrap(), Widget { id: 7, ..Default::default() });
    let full = Widget { id: 7, hint: "x".into(), limit: 2 };
    let new = write(&full, 4);
    assert_eq!(Widget::decode(&mut ByteReader::new(new.bytes(), 4)).unwrap(), full);
}

#[test]
fn advisory_values_are_dropped_and_required_ones_refused() {
    let dropped = write(&Widget { id: 7, hint: "x".into(), limit: 0 }, 3);
    assert_eq!(dropped.bytes(), [7, 0, 0, 0]);
    assert_eq!(dropped.dropped(), ["hint"]);
    assert!(dropped.refused().is_none());
    let refused = write(&Widget { id: 7, hint: String::new(), limit: 2 }, 3);
    assert_eq!(refused.refused(), Some("limit doesn't exist in v3"));
    let mut first = write(&Widget { id: 7, hint: String::new(), limit: 2 }, 3);
    first.refuse("later");
    assert_eq!(first.refused(), Some("limit doesn't exist in v3")); // the first reason wins
}

// MARK: - Features

#[test]
fn features_follow_their_versions() {
    assert!(ProtocolFeature::HostSetup.is_supported(4));
    assert!(!ProtocolFeature::HostStats.is_supported(4));
    assert!(ProtocolFeature::HostStats.is_supported(5));
    assert_eq!(ProtocolFeature::missing(4, Some(5)), [ProtocolFeature::HostStats]);
    assert_eq!(
        ProtocolFeature::missing(4, Some(6)),
        [ProtocolFeature::HostStats, ProtocolFeature::TextInput, ProtocolFeature::Audio]
    );
    assert_eq!(ProtocolFeature::missing(5, Some(6)), [ProtocolFeature::TextInput, ProtocolFeature::Audio]);
    assert!(ProtocolFeature::missing(NEWEST_VERSION, Some(NEWEST_VERSION)).is_empty());
    assert!(ProtocolFeature::missing(4, Some(4)).is_empty());
    // Without a newest, the offered list's newest (a LAIN_PROTOCOL_MAX cap lowers it).
    let offered = VersionList::offered().newest().unwrap();
    assert_eq!(ProtocolFeature::missing(4, None), ProtocolFeature::missing(4, Some(offered)));
}

/// A feature replaced before the oldest supported version is dead compatibility code: delete it.
#[test]
fn no_feature_outlives_the_floor() {
    for f in ProtocolFeature::ALL {
        if let Some(until) = f.until() {
            assert!(until > SUPPORTED_VERSIONS[0], "{f:?} is dead: delete it");
        }
    }
}

#[test]
fn text_input_and_audio_are_version_six_messages() {
    for ty in [MessageType::TextInput, MessageType::AudioConfig, MessageType::AudioPacket] {
        let sample = ProtocolSamples::all().iter().find(|m| m.ty() == ty).unwrap();
        assert_eq!(
            MessageCodec::lower(sample, 5, 0, 0, None),
            Lowered::Unrepresentable(format!("{ty} doesn't exist in v5"))
        );
        assert!(MessageCodec::lower(sample, 6, 0, 0, None).bytes().is_some());
    }
    assert!(!ProtocolFeature::TextInput.is_supported(5) && ProtocolFeature::TextInput.is_supported(6));
    assert!(!ProtocolFeature::Audio.is_supported(5) && ProtocolFeature::Audio.is_supported(6));
}
