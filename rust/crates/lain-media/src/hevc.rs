//! HEVC bitstream utilities (Swift: `LainMedia/HEVC.swift`, plus what VideoToolbox does for the Mac host).
//!
//! On the Mac, VideoToolbox hands the host each frame as 4-byte big-endian length-prefixed NAL units with
//! the parameter sets held apart in a format description, and the host sends exactly that: the parameter
//! sets in `VideoConfig`, the NAL units in `VideoFrame.data`. A Linux encoder writes an Annex-B byte stream
//! (start codes, parameter sets inline on keyframes), so this module converts one into the other:
//! [`AccessUnit::from_annexb`].

use thiserror::Error;

/// NAL unit types used here (H.265 Table 7-1).
pub mod nal {
    pub const TRAIL_R: u8 = 1;
    /// `BLA_W_LP`, the first IRAP type.
    pub const BLA_W_LP: u8 = 16;
    pub const IDR_W_RADL: u8 = 19;
    pub const IDR_N_LP: u8 = 20;
    pub const CRA_NUT: u8 = 21;
    pub const VPS: u8 = 32;
    pub const SPS: u8 = 33;
    pub const PPS: u8 = 34;
    /// Access unit delimiter.
    pub const AUD: u8 = 35;
    pub const EOS: u8 = 36;
    pub const EOB: u8 = 37;
    /// Filler data: what Mesa's CBR pads pictures with unless bit stuffing is off.
    pub const FD: u8 = 38;
    pub const PREFIX_SEI: u8 = 39;
    pub const SUFFIX_SEI: u8 = 40;

    /// A slice of a picture (types 0–31).
    pub const fn is_vcl(t: u8) -> bool {
        t < 32
    }

    /// An intra random access point slice (types 16–23; 22 and 23 are reserved IRAP types). A picture made of
    /// these decodes on its own: a keyframe.
    pub const fn is_irap(t: u8) -> bool {
        t >= BLA_W_LP && t <= 23
    }

    pub const fn is_parameter_set(t: u8) -> bool {
        t == VPS || t == SPS || t == PPS
    }
}

/// Why a byte stream couldn't be converted.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum HevcError {
    /// No start code at all (an empty buffer included).
    #[error("no start code")]
    NoStartCode,
    /// Bytes other than zeros before the first start code (Annex-B allows only `leading_zero_8bits`).
    #[error("{0} bytes before the first start code")]
    LeadingGarbage(usize),
    /// A NAL unit shorter than its 2-byte header (two start codes in a row, or a start code at the end).
    #[error("NAL unit at offset {0} is shorter than its header")]
    Truncated(usize),
    /// `forbidden_zero_bit` is set.
    #[error("NAL unit at offset {0} has forbidden_zero_bit set")]
    ForbiddenBit(usize),
    /// The access unit holds no slice.
    #[error("access unit has no slice")]
    NoSlice,
    /// A 4-byte length prefix that runs past the end (length-prefixed input only).
    #[error("length prefix at offset {0} runs past the end")]
    BadLength(usize),
}

/// One NAL unit found in an Annex-B byte stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NalUnit<'a> {
    pub nal_type: u8,
    /// The offset of its 2-byte header in the stream.
    pub offset: usize,
    /// The start code before it: 3, or 4 with a leading zero byte.
    pub start_code_len: usize,
    /// The header and payload, emulation prevention bytes kept, without trailing zero bytes.
    pub bytes: &'a [u8],
}

/// The NAL unit type from the first header byte.
pub fn nal_type(header: u8) -> u8 {
    (header >> 1) & 0x3F
}

/// Splits an Annex-B byte stream into its NAL units, in order.
///
/// A start code is `00 00 01`; a zero byte before it makes it the 4-byte form. Zero bytes at the end of a
/// NAL unit are `trailing_zero_8bits` (or the 4-byte form's leading zero) and are not part of it: a NAL unit
/// never ends in a zero byte (its RBSP ends in a stop bit, and `cabac_zero_words` are written `00 00 03`).
/// Emulation prevention guarantees no start code inside a NAL unit, so a plain scan is exact.
pub fn split_annexb(stream: &[u8]) -> Result<Vec<NalUnit<'_>>, HevcError> {
    let starts = start_codes(stream);
    let Some(&first) = starts.first() else { return Err(HevcError::NoStartCode) };
    if let Some(garbage) = stream[..first].iter().rposition(|&b| b != 0) {
        return Err(HevcError::LeadingGarbage(garbage + 1));
    }
    let mut units = Vec::with_capacity(starts.len());
    for (k, &sc) in starts.iter().enumerate() {
        let offset = sc + 3;
        let end = starts.get(k + 1).copied().unwrap_or(stream.len());
        let mut bytes = &stream[offset..end];
        while let [rest @ .., 0] = bytes {
            bytes = rest;
        }
        if bytes.len() < 2 {
            return Err(HevcError::Truncated(offset));
        }
        if bytes[0] & 0x80 != 0 {
            return Err(HevcError::ForbiddenBit(offset));
        }
        let start_code_len = if sc > 0 && stream[sc - 1] == 0 { 4 } else { 3 };
        units.push(NalUnit { nal_type: nal_type(bytes[0]), offset, start_code_len, bytes });
    }
    Ok(units)
}

/// The positions of every `00 00 01` in `b`.
fn start_codes(b: &[u8]) -> Vec<usize> {
    let mut out = Vec::new();
    let mut i = 2;
    while i < b.len() {
        if b[i] > 1 {
            // No start code can end at i, i + 1 or i + 2: each would need b[i] == 0.
            i += 3;
        } else if b[i] == 1 && b[i - 1] == 0 && b[i - 2] == 0 {
            out.push(i - 2);
            i += 3;
        } else {
            i += 1;
        }
    }
    out
}

/// One encoded frame as the wire carries it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccessUnit {
    /// The VPS, SPS and PPS it carried, without start codes, in that order (VideoToolbox's order); empty
    /// for a frame that carries none.
    pub parameter_sets: Vec<Vec<u8>>,
    /// Every other NAL unit as 4-byte big-endian length-prefixed units (`VideoFrame.data`).
    pub data: Vec<u8>,
    /// It holds an IRAP slice.
    pub keyframe: bool,
}

impl AccessUnit {
    /// Converts one encoder result. The parameter sets go to [`parameter_sets`](Self::parameter_sets);
    /// access unit delimiters and filler data are dropped, as VideoToolbox's output has neither; everything
    /// else (slices, SEI) goes to [`data`](Self::data) in stream order. Fails unless the access unit holds
    /// at least one slice.
    ///
    /// The NAL types dropped are exactly the brief's (VPS, SPS, PPS, AUD, FD). End of sequence and end of
    /// bitstream (36, 37) pass through: no encoder lain uses writes them.
    pub fn from_annexb(annexb: &[u8]) -> Result<Self, HevcError> {
        let units = split_annexb(annexb)?;
        let mut sets: [Vec<Vec<u8>>; 3] = Default::default();
        let mut data = Vec::with_capacity(annexb.len());
        let mut keyframe = false;
        let mut slices = 0;
        for u in &units {
            match u.nal_type {
                nal::VPS | nal::SPS | nal::PPS => sets[usize::from(u.nal_type - nal::VPS)].push(u.bytes.to_vec()),
                nal::AUD | nal::FD => {}
                t => {
                    if nal::is_vcl(t) {
                        slices += 1;
                        keyframe |= nal::is_irap(t);
                    }
                    data.extend_from_slice(&(u.bytes.len() as u32).to_be_bytes());
                    data.extend_from_slice(u.bytes);
                }
            }
        }
        if slices == 0 {
            return Err(HevcError::NoSlice);
        }
        Ok(Self { parameter_sets: sets.into_iter().flatten().collect(), data, keyframe })
    }

    /// Whether the parameter sets are complete: at least one VPS, SPS and PPS, which a decoder needs.
    pub fn has_all_parameter_sets(&self) -> bool {
        [nal::VPS, nal::SPS, nal::PPS]
            .iter()
            .all(|&t| self.parameter_sets.iter().any(|ps| ps.first().map(|&h| nal_type(h)) == Some(t)))
    }
}

/// The VPS, SPS and PPS in an Annex-B access unit, without start codes (Swift:
/// `HEVC.parameterSets(_:)`, which reads them from a format description).
pub fn parameter_sets(annexb: &[u8]) -> Result<Vec<Vec<u8>>, HevcError> {
    Ok(AccessUnit::from_annexb(annexb)?.parameter_sets)
}

/// Whether an Annex-B access unit holds an IRAP slice (Swift: `HEVC.isKeyframe(_:)`, which reads the
/// sample's sync attachment).
pub fn is_keyframe(annexb: &[u8]) -> Result<bool, HevcError> {
    Ok(split_annexb(annexb)?.iter().any(|u| nal::is_irap(u.nal_type)))
}

/// Splits `VideoFrame.data` (4-byte big-endian length-prefixed NAL units) back into NAL units.
pub fn split_length_prefixed(data: &[u8]) -> Result<Vec<&[u8]>, HevcError> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < data.len() {
        let Some(len) = data.get(i..i + 4) else { return Err(HevcError::BadLength(i)) };
        let len = u32::from_be_bytes([len[0], len[1], len[2], len[3]]) as usize;
        let Some(unit) = data.get(i + 4..i + 4 + len) else { return Err(HevcError::BadLength(i)) };
        out.push(unit);
        i += 4 + len;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit(t: u8, payload: &[u8]) -> Vec<u8> {
        let mut v = vec![t << 1, 0x01];
        v.extend_from_slice(payload);
        v
    }

    #[test]
    fn three_and_four_byte_start_codes_and_trailing_zeros() {
        let mut s = vec![0, 0, 0, 1];
        s.extend(unit(nal::TRAIL_R, &[0xAA, 0x03]));
        s.extend([0, 0, 0]); // trailing_zero_8bits
        s.extend([0, 0, 1]);
        s.extend(unit(nal::PREFIX_SEI, &[0x05]));
        let units = split_annexb(&s).unwrap();
        assert_eq!(units.len(), 2);
        assert_eq!((units[0].nal_type, units[0].offset, units[0].start_code_len), (1, 4, 4));
        assert_eq!(units[0].bytes, &unit(1, &[0xAA, 0x03])[..]);
        assert_eq!((units[1].nal_type, units[1].start_code_len), (nal::PREFIX_SEI, 4), "a zero before 00 00 01");
        let mut s3 = vec![0, 0, 1];
        s3.extend(unit(nal::TRAIL_R, &[7]));
        assert_eq!(split_annexb(&s3).unwrap()[0].start_code_len, 3);
    }

    #[test]
    fn emulation_prevention_is_not_a_start_code() {
        let mut s = vec![0, 0, 0, 1];
        s.extend(unit(nal::TRAIL_R, &[0, 0, 3, 1, 0, 0, 3, 0, 0x80]));
        let units = split_annexb(&s).unwrap();
        assert_eq!(units.len(), 1);
        assert_eq!(units[0].bytes.len(), 11);
    }

    #[test]
    fn malformed_streams_are_refused() {
        assert_eq!(split_annexb(&[]), Err(HevcError::NoStartCode));
        assert_eq!(split_annexb(&[0, 0, 0]), Err(HevcError::NoStartCode));
        assert_eq!(split_annexb(&[1, 2, 3, 4]), Err(HevcError::NoStartCode));
        assert_eq!(split_annexb(&[0, 0x42, 0, 0, 0, 1, 2, 1]), Err(HevcError::LeadingGarbage(2)));
        assert_eq!(split_annexb(&[0, 0, 0, 0, 1, 2, 1]).unwrap().len(), 1, "leading zeros are allowed");
        assert_eq!(split_annexb(&[0, 0, 1, 0, 0, 1, 2, 1]), Err(HevcError::Truncated(3)));
        assert_eq!(split_annexb(&[0, 0, 1, 2]), Err(HevcError::Truncated(3)));
        assert_eq!(split_annexb(&[0, 0, 1, 0x82, 1]), Err(HevcError::ForbiddenBit(3)));
        let mut sets_only = vec![0, 0, 0, 1];
        sets_only.extend(unit(nal::VPS, &[1]));
        assert_eq!(AccessUnit::from_annexb(&sets_only), Err(HevcError::NoSlice));
    }

    #[test]
    fn drops_aud_and_filler_keeps_sei_and_orders_parameter_sets() {
        let mut s = Vec::new();
        for (t, p) in [
            (nal::AUD, &[0x50][..]),
            (nal::SPS, &[2][..]),
            (nal::VPS, &[1][..]),
            (nal::PPS, &[3][..]),
            (nal::PREFIX_SEI, &[9][..]),
            (nal::IDR_W_RADL, &[0xAF][..]),
            (nal::FD, &[0xFF, 0xFF, 0x80][..]),
        ] {
            s.extend([0, 0, 0, 1]);
            s.extend(unit(t, p));
        }
        let au = AccessUnit::from_annexb(&s).unwrap();
        assert!(au.keyframe);
        assert!(au.has_all_parameter_sets());
        assert_eq!(au.parameter_sets, vec![unit(nal::VPS, &[1]), unit(nal::SPS, &[2]), unit(nal::PPS, &[3])]);
        let units = split_length_prefixed(&au.data).unwrap();
        assert_eq!(units, vec![&unit(nal::PREFIX_SEI, &[9])[..], &unit(nal::IDR_W_RADL, &[0xAF])[..]]);
        assert_eq!(&au.data[..4], &[0, 0, 0, 3]);
    }

    #[test]
    fn the_platform_fake_access_unit_converts() {
        let key = lain_platform::fake::fake_access_unit(5, true);
        let au = AccessUnit::from_annexb(&key).unwrap();
        assert!(au.keyframe && au.has_all_parameter_sets());
        assert_eq!(au.parameter_sets.len(), 3);
        assert_eq!(split_length_prefixed(&au.data).unwrap().len(), 1);
        let p = AccessUnit::from_annexb(&lain_platform::fake::fake_access_unit(6, false)).unwrap();
        assert!(!p.keyframe && p.parameter_sets.is_empty() && !p.has_all_parameter_sets());
        assert!(is_keyframe(&key).unwrap());
        assert_eq!(parameter_sets(&key).unwrap().len(), 3);
    }

    #[test]
    fn bad_length_prefixes_are_refused() {
        assert_eq!(split_length_prefixed(&[]).unwrap().len(), 0);
        assert_eq!(split_length_prefixed(&[0, 0, 0]), Err(HevcError::BadLength(0)));
        assert_eq!(split_length_prefixed(&[0, 0, 0, 2, 1]), Err(HevcError::BadLength(0)));
    }
}
