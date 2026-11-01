//! Checks every access unit before it leaves the backend (the brief: "every access unit validated"; spike A's
//! wave-3 list). What `lain-media` would refuse as `EncodeFailed` is refused here first, so the backend can force
//! an IDR itself (its reference chain is broken) and count failed keyframes for the escalation. No Swift
//! counterpart: VideoToolbox hands over a sample buffer with its own sync attachment.

/// A NAL unit type's class (H.265 Table 7-1).
fn is_vcl(t: u8) -> bool {
    t < 32
}

fn is_irap(t: u8) -> bool {
    (16..=23).contains(&t)
}

/// What a valid access unit holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuSummary {
    /// It holds an IRAP slice (what `lain-media` calls a keyframe).
    pub keyframe: bool,
    pub nal_units: usize,
    pub slices: usize,
}

/// Validates one Annex-B access unit: it starts with a start code (after zero bytes at most), every NAL unit
/// has its 2-byte header with `forbidden_zero_bit` clear, it holds a slice, its parameter sets are all three of
/// VPS, SPS and PPS or none, and an IDR asked for (`want_keyframe`) is an IRAP picture carrying all three.
pub fn validate(annexb: &[u8], want_keyframe: bool) -> Result<AuSummary, String> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 2 < annexb.len() {
        if annexb[i] == 0 && annexb[i + 1] == 0 && annexb[i + 2] == 1 {
            starts.push(i + 3);
            i += 3;
        } else {
            i += 1;
        }
    }
    let Some(&first) = starts.first() else { return Err("no start code".into()) };
    if annexb[..first - 3].iter().any(|&b| b != 0) {
        return Err("bytes before the first start code".into());
    }
    let mut sets = [false; 3];
    let (mut slices, mut keyframe) = (0, false);
    for (k, &at) in starts.iter().enumerate() {
        let end = starts.get(k + 1).map_or(annexb.len(), |&n| n - 3);
        let unit = &annexb[at..end.max(at)];
        let header = unit.iter().rposition(|&b| b != 0).map_or(&unit[..0], |last| &unit[..=last]);
        if header.len() < 2 {
            return Err(format!("NAL unit at {at} is shorter than its header"));
        }
        if header[0] & 0x80 != 0 {
            return Err(format!("NAL unit at {at} has forbidden_zero_bit set"));
        }
        let t = (header[0] >> 1) & 0x3F;
        match t {
            32..=34 => sets[usize::from(t - 32)] = true,
            t if is_vcl(t) => {
                slices += 1;
                keyframe |= is_irap(t);
            }
            _ => {}
        }
    }
    if slices == 0 {
        return Err("no slice".into());
    }
    let any_sets = sets.iter().any(|&s| s);
    let all_sets = sets.iter().all(|&s| s);
    if any_sets && !all_sets {
        return Err(format!("only some parameter sets (VPS {}, SPS {}, PPS {})", sets[0], sets[1], sets[2]));
    }
    if want_keyframe && !keyframe {
        return Err("an IDR was asked for, and the picture isn't IRAP".into());
    }
    if keyframe && !all_sets {
        return Err("a keyframe without its parameter sets".into());
    }
    Ok(AuSummary { keyframe, nal_units: starts.len(), slices })
}

#[cfg(test)]
mod tests {
    use super::*;
    use lain_platform::fake::fake_access_unit;

    fn unit(t: u8, payload: &[u8]) -> Vec<u8> {
        let mut v = vec![0, 0, 0, 1, t << 1, 1];
        v.extend_from_slice(payload);
        v
    }

    #[test]
    fn accepts_keyframes_and_p_frames() {
        let key = validate(&fake_access_unit(1, true), true).unwrap();
        assert_eq!(key, AuSummary { keyframe: true, nal_units: 4, slices: 1 });
        let p = validate(&fake_access_unit(2, false), false).unwrap();
        assert!(!p.keyframe);
        // An unrequested IDR is fine (and reported as a keyframe).
        assert!(validate(&fake_access_unit(3, true), false).unwrap().keyframe);
        // Leading zeros and 3-byte start codes are Annex-B too.
        let mut au = vec![0, 0];
        au.extend(&unit(1, &[0xAA])[1..]);
        assert!(validate(&au, false).is_ok());
        // Trailing zeros (cabac_zero_words padding) and filler data are allowed.
        let mut au = fake_access_unit(4, false);
        au.extend([0, 0, 0]);
        au.extend(unit(38, &[0xFF, 0x80]));
        assert_eq!(validate(&au, false).unwrap().nal_units, 2);
    }

    #[test]
    fn refuses_what_lain_media_refuses() {
        assert_eq!(validate(&[], false), Err("no start code".into()));
        assert!(validate(&[0x47, 0, 0, 1, 2, 1], false).unwrap_err().contains("before"));
        assert!(validate(&unit(32, &[1]), false).unwrap_err().contains("no slice"));
        assert!(validate(&[0, 0, 1, 2], false).unwrap_err().contains("shorter"));
        assert!(validate(&[0, 0, 1, 0x82, 1], false).unwrap_err().contains("forbidden"));
        // A P-frame asked to be an IDR.
        assert!(validate(&fake_access_unit(5, false), true).unwrap_err().contains("isn't IRAP"));
        // Some, not all, of the parameter sets.
        let mut au = unit(32, &[1]);
        au.extend(unit(34, &[2]));
        au.extend(unit(19, &[3]));
        assert!(validate(&au, true).unwrap_err().contains("only some"));
        // An IDR with none.
        assert!(validate(&unit(19, &[3]), false).unwrap_err().contains("without its parameter sets"));
        // A wrapped coded buffer: no start code at all (spike A's corrupt vah265enc output).
        assert!(validate(&[0x26, 0x01, 0xAF, 0x55, 0x01], true).is_err());
    }
}
