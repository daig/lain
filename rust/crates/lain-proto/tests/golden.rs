//! Conformance against the Swift tree (decision L5): `GoldenBytes.swift`, read at test time, holds the bytes
//! of every message at every version and the pinned digests. Port of Swift's `GoldenBytesTests`.
//!
//! A version or message the file has that this crate lacks fails, and so does one this crate has that the
//! file lacks, so a protocol change on either side can't pass silently.

use std::collections::{BTreeMap, BTreeSet};

use lain_proto::*;

const GOLDEN_PATH: &str = "../../../Packages/LainKit/Tests/LainProtocolTests/GoldenBytes.swift";

struct Golden {
    /// version → message name → frame bytes
    bytes: BTreeMap<u8, BTreeMap<String, Vec<u8>>>,
    /// version → digest
    digests: BTreeMap<u8, Vec<u8>>,
}

/// Parses the Swift literal strictly: any line it doesn't understand inside the two tables fails, so a
/// format change is noticed rather than skipped.
fn load() -> Golden {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(GOLDEN_PATH);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    let mut golden = Golden { bytes: BTreeMap::new(), digests: BTreeMap::new() };
    enum Section {
        None,
        Bytes(Option<u8>),
        Digests,
    }
    let mut section = Section::None;
    let quoted = |s: &str| -> String {
        let s = s.trim().trim_end_matches(',');
        assert!(s.len() >= 2 && s.starts_with('"') && s.ends_with('"'), "not a string literal: {s:?}");
        s[1..s.len() - 1].to_owned()
    };
    for line in text.lines() {
        let t = line.trim();
        if t.starts_with("static let bytes") {
            section = Section::Bytes(None);
            continue;
        }
        if t.starts_with("static let digests") {
            section = Section::Digests;
            continue;
        }
        match &mut section {
            Section::None => {}
            Section::Bytes(current) => match t {
                "]" => section = Section::None,
                "]," => *current = None,
                _ if t.ends_with(": [") => {
                    let v: u8 = t.trim_end_matches(": [").parse().unwrap_or_else(|_| panic!("bad version line {t:?}"));
                    assert!(!golden.bytes.contains_key(&v), "version {v} listed twice");
                    golden.bytes.insert(v, BTreeMap::new());
                    *current = Some(v);
                }
                _ => {
                    let v = current.unwrap_or_else(|| panic!("entry outside a version: {t:?}"));
                    let (key, value) = t.split_once(':').unwrap_or_else(|| panic!("bad entry {t:?}"));
                    let bytes = hex::decode(quoted(value)).unwrap_or_else(|e| panic!("bad hex in {t:?}: {e}"));
                    let previous = golden.bytes.get_mut(&v).unwrap().insert(quoted(key), bytes);
                    assert!(previous.is_none(), "duplicate entry {t:?}");
                }
            },
            Section::Digests => match t {
                "]" => section = Section::None,
                _ => {
                    let (key, value) = t.split_once(':').unwrap_or_else(|| panic!("bad digest line {t:?}"));
                    let v: u8 = key.trim().parse().unwrap_or_else(|_| panic!("bad digest version {t:?}"));
                    golden.digests.insert(v, hex::decode(quoted(value)).expect("digest hex"));
                }
            },
        }
    }
    assert!(!golden.bytes.is_empty() && !golden.digests.is_empty(), "no tables found in {}", path.display());
    golden
}

/// The layers every frame version admits: header 0xFF (the frozen handshake), then each session version.
fn frame_versions() -> Vec<u8> {
    std::iter::once(HANDSHAKE_VERSION).chain(SUPPORTED_VERSIONS.iter().copied()).collect()
}

fn sample(name: &str) -> Option<&'static Message> {
    ProtocolSamples::all().iter().find(|m| m.ty().name() == name)
}

#[test]
fn the_file_and_the_crate_cover_the_same_versions_and_messages() {
    let golden = load();
    let ours: BTreeSet<u8> = frame_versions().into_iter().collect();
    let theirs: BTreeSet<u8> = golden.bytes.keys().copied().collect();
    assert_eq!(theirs, ours, "the golden file's versions differ from the ones this crate frames");
    for (&v, entries) in &golden.bytes {
        let expected: BTreeSet<String> =
            ProtocolSamples::all().iter().filter(|m| m.ty().exists_in(v)).map(|m| m.ty().name().to_owned()).collect();
        let have: BTreeSet<String> = entries.keys().cloned().collect();
        assert_eq!(have, expected, "v{v}: the golden file's messages differ from this crate's");
    }
    let pinned: BTreeSet<u8> = golden.digests.keys().copied().collect();
    assert_eq!(pinned, SUPPORTED_VERSIONS.iter().copied().collect(), "pinned digests vs supported versions");
}

#[test]
fn every_sample_encodes_to_its_golden_bytes_at_every_version() {
    let golden = load();
    for v in frame_versions() {
        for message in ProtocolSamples::all().iter().filter(|m| m.ty().exists_in(v)) {
            let key = message.ty().name();
            let want = golden.bytes.get(&v).and_then(|m| m.get(key)).unwrap_or_else(|| panic!("no golden v{v} {key}"));
            let got = MessageCodec::encode(message, 0, 0, None, Some(v));
            assert_eq!(hex::encode(&got), hex::encode(want), "v{v} {key} doesn't encode as recorded");
            assert!(matches!(MessageCodec::lower(message, v, 0, 0, None), Lowered::Exact(_)), "v{v} {key} exact");
        }
    }
}

/// Swift's `liftIsInjectiveAndLandsInTheModel`, plus equality with the sample each entry was made from.
#[test]
fn every_golden_frame_decodes_to_its_sample_and_encodes_back() {
    let golden = load();
    for (&v, entries) in &golden.bytes {
        for (key, bytes) in entries {
            let env = MessageCodec::decode(bytes).unwrap_or_else(|e| panic!("v{v} {key}: {e}"));
            assert_eq!(env.header.version, v, "v{v} {key}");
            assert_eq!(env.header.ty.name(), key, "v{v} {key}");
            assert_eq!(env.header.sequence, 0);
            assert_eq!(env.header.timestamp_ns, 0);
            assert_eq!(&env.message, sample(key).unwrap_or_else(|| panic!("no sample {key}")), "v{v} {key}");
            assert_eq!(&MessageCodec::encode(&env.message, 0, 0, None, Some(v)), bytes, "v{v} {key} re-encoded");
            let newest = env.message.ty().default_version();
            let again = MessageCodec::decode(&MessageCodec::encode(&env.message, 0, 0, None, Some(newest))).unwrap();
            assert_eq!(again.message, env.message, "v{v} {key} at the newest version");
        }
    }
}

#[test]
fn digests_are_computed_from_this_codec_and_equal_the_pinned_ones() {
    let golden = load();
    for &v in SUPPORTED_VERSIONS {
        let digest = SchemaDigest::compute(v);
        assert_eq!(hex::encode(digest), hex::encode(&golden.digests[&v]), "v{v}'s digest changed");
    }
    // The values the spec records (LINUX-HOST.md), in case the file and the codec ever drift together.
    assert_eq!(hex::encode(SchemaDigest::compute(3)), "1dfd9829fe53df7a");
    assert_eq!(hex::encode(SchemaDigest::compute(4)), "50b787cf3ef02169");
    for e in VersionList::supported().entries() {
        assert_eq!(e.digest, SchemaDigest::compute(e.version));
    }
    assert_eq!(VersionList::supported().versions(), SUPPORTED_VERSIONS);
}
