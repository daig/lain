//! The HEVC utilities on real access units from the AMD iGPU's encoder (`tests/fixtures/hevc/`, see its
//! README), checked against each manifest's NAL list, which the generator found independently.

use std::path::{Path, PathBuf};

use lain_media::hevc::{self, AccessUnit, nal};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/hevc")
}

/// One manifest line: `au-05.h265 size=7346 keyframe=1 nal=32,4,23,4 …`.
#[derive(Debug)]
struct Entry {
    file: String,
    size: usize,
    keyframe: bool,
    /// (type, offset, length, start code length).
    nals: Vec<(u8, usize, usize, usize)>,
}

fn manifest(dir: &str) -> Vec<Entry> {
    let text = std::fs::read_to_string(fixtures().join(dir).join("manifest.txt")).unwrap();
    text.lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .map(|line| {
            let mut words = line.split_whitespace();
            let file = words.next().unwrap().to_owned();
            let mut e = Entry { file, size: 0, keyframe: false, nals: Vec::new() };
            for w in words {
                let (key, value) = w.split_once('=').unwrap();
                match key {
                    "size" => e.size = value.parse().unwrap(),
                    "keyframe" => e.keyframe = value == "1",
                    "nal" => {
                        let v: Vec<usize> = value.split(',').map(|x| x.parse().unwrap()).collect();
                        e.nals.push((v[0] as u8, v[1], v[2], v[3]));
                    }
                    other => panic!("unknown manifest key {other}"),
                }
            }
            e
        })
        .collect()
}

fn read(dir: &str, file: &str) -> Vec<u8> {
    std::fs::read(fixtures().join(dir).join(file)).unwrap()
}

/// Every AU of a directory, converted, with its bytes and manifest entry.
fn stream(dir: &str) -> Vec<(Entry, Vec<u8>, AccessUnit)> {
    manifest(dir)
        .into_iter()
        .map(|e| {
            let bytes = read(dir, &e.file);
            let au = AccessUnit::from_annexb(&bytes).unwrap_or_else(|err| panic!("{dir}/{}: {err}", e.file));
            (e, bytes, au)
        })
        .collect()
}

const DIRS: [&str; 3] = ["256x144", "256x144-stuffing", "192x128"];

#[test]
fn the_split_matches_every_manifest() {
    let mut checked = 0;
    for dir in DIRS {
        let entries = manifest(dir);
        assert!(!entries.is_empty(), "{dir}: empty manifest");
        for e in entries {
            let bytes = read(dir, &e.file);
            assert_eq!(bytes.len(), e.size, "{dir}/{}", e.file);
            let units = hevc::split_annexb(&bytes).unwrap();
            let found: Vec<_> = units.iter().map(|u| (u.nal_type, u.offset, u.bytes.len(), u.start_code_len)).collect();
            assert_eq!(found, e.nals, "{dir}/{}", e.file);
            for u in &units {
                assert_eq!(u.bytes, &bytes[u.offset..u.offset + u.bytes.len()]);
            }
            assert_eq!(hevc::is_keyframe(&bytes).unwrap(), e.keyframe, "{dir}/{}", e.file);
            checked += 1;
        }
    }
    assert_eq!(checked, 19);
}

#[test]
fn conversion_keeps_slices_and_moves_the_parameter_sets() {
    for dir in DIRS {
        for (e, bytes, au) in stream(dir) {
            let at = |t: u8| e.nals.iter().filter(move |n| n.0 == t).map(|n| bytes[n.1..n.1 + n.2].to_vec());
            let sets: Vec<Vec<u8>> = at(nal::VPS).chain(at(nal::SPS)).chain(at(nal::PPS)).collect();
            assert_eq!(au.parameter_sets, sets, "{dir}/{}", e.file);
            assert_eq!(au.keyframe, e.keyframe);
            assert_eq!(au.has_all_parameter_sets(), e.keyframe, "keyframes carry VPS, SPS and PPS; others none");

            // The data is exactly the slices, length-prefixed: no parameter set, AUD or filler.
            let slices: Vec<&[u8]> =
                e.nals.iter().filter(|n| nal::is_vcl(n.0)).map(|n| &bytes[n.1..n.1 + n.2]).collect();
            assert_eq!(hevc::split_length_prefixed(&au.data).unwrap(), slices, "{dir}/{}", e.file);
            assert_eq!(au.data.len(), slices.iter().map(|s| s.len() + 4).sum::<usize>());
            for unit in hevc::split_length_prefixed(&au.data).unwrap() {
                let t = hevc::nal_type(unit[0]);
                assert!(![nal::VPS, nal::SPS, nal::PPS, nal::AUD, nal::FD].contains(&t));
            }
        }
    }
}

#[test]
fn a_requested_idr_resends_the_same_parameter_sets() {
    let s = stream("256x144");
    let keyframes: Vec<_> =
        s.iter().filter(|x| x.2.keyframe).map(|x| (x.0.file.as_str(), &x.2.parameter_sets)).collect();
    assert_eq!(keyframes.iter().map(|k| k.0).collect::<Vec<_>>(), ["au-00.h265", "au-05.h265"]);
    assert_eq!(keyframes[0].1, keyframes[1].1, "byte-identical, so no new VideoConfig");
    assert_eq!(hevc::parameter_sets(&read("256x144", "au-05.h265")).unwrap(), *keyframes[0].1);
}

#[test]
fn another_size_has_another_sps() {
    let a = &stream("256x144")[0].2.parameter_sets;
    let b = &stream("192x128")[0].2.parameter_sets;
    assert_eq!(a.len(), 3);
    assert_eq!(b.len(), 3);
    assert_ne!(a[1], b[1], "the SPS differs");
}

#[test]
fn filler_data_is_dropped() {
    let plain = stream("256x144");
    let stuffed = stream("256x144-stuffing");
    let (e, bytes, au) = &stuffed[3];
    assert!(e.nals.iter().any(|n| n.0 == nal::FD), "au-03 holds filler");
    assert!(hevc::split_annexb(bytes).unwrap().iter().any(|u| u.nal_type == nal::FD));
    assert_eq!(hevc::split_length_prefixed(&au.data).unwrap().len(), 1);
    assert_eq!(au.data.len(), plain[3].2.data.len(), "the same slice length as without stuffing");
    assert!(au.data.len() < bytes.len() - 1723);
}

#[test]
fn parameter_sets_of_packed_headers_only() {
    // An encoder's packed VPS, SPS and PPS headers on their own, without a slice; out of order on purpose,
    // they come back VPS, SPS, PPS.
    let mut s = Vec::new();
    for t in [nal::PPS, nal::VPS, nal::SPS] {
        s.extend([0, 0, 0, 1, t << 1, 1, 0x80]);
    }
    let sets = hevc::parameter_sets(&s).unwrap();
    assert_eq!(sets, [vec![nal::VPS << 1, 1, 0x80], vec![nal::SPS << 1, 1, 0x80], vec![nal::PPS << 1, 1, 0x80]]);
    assert_eq!(hevc::parameter_sets(&read("256x144", "au-01.h265")), Ok(vec![]), "a P-frame carries none");
    for dir in DIRS {
        for (e, bytes, au) in stream(dir) {
            assert_eq!(hevc::parameter_sets(&bytes).unwrap(), au.parameter_sets, "{dir}/{}", e.file);
        }
    }
    assert_eq!(hevc::parameter_sets(&[1, 2, 3]), Err(hevc::HevcError::NoStartCode));
}
