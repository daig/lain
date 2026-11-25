//! Out-of-band pairing token for clients that cannot pair over usbmuxd/USB (e.g. macOS, Apple TV).
//!
//! Swift reference: `Packages/LainKit/Sources/LainTransport/PairingCode.swift`.
//!
//! Format: `lain1:<base64url(payload)>` (no `=` padding).
//! Binary payload:
//! - byte 0: version (`1`)
//! - bytes 1..17: host UUID (16 bytes, RFC 4122)
//! - bytes 17..49: pairing secret (32 bytes, non-zero)
//! - byte 49: host name UTF-8 byte length (`0..=64`)
//! - bytes 50..(50 + name_len): host name UTF-8

use lain_proto::Pair;

use crate::PairingAccounts;

/// Errors creating or decoding a [`PairingCode`].
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum PairingCodeError {
    #[error("host id must be a canonical UUID")]
    InvalidHostId,
    #[error("pairing secret must be 32 non-zero bytes")]
    InvalidSecret,
    #[error("invalid pairing code")]
    InvalidFormat,
    #[error("unsupported pairing code version {0}")]
    UnsupportedVersion(u8),
}

/// Out-of-band pairing code (`lain1:...`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingCode {
    pub host_id: String,
    pub secret: [u8; Pair::SECRET_SIZE],
    pub host_name: String,
}

impl PairingCode {
    pub const PREFIX: &'static str = "lain1:";
    pub const VERSION: u8 = 1;
    pub const MAX_HOST_NAME_BYTES: usize = 64;
    const FIXED_HEADER_LEN: usize = 1 + 16 + Pair::SECRET_SIZE + 1;

    pub fn new(
        host_id: impl Into<String>,
        secret: [u8; Pair::SECRET_SIZE],
        host_name: impl AsRef<str>,
    ) -> Result<Self, PairingCodeError> {
        let host_id = host_id.into();
        if !PairingAccounts::is_canonical_host_id(&host_id) {
            return Err(PairingCodeError::InvalidHostId);
        }
        if !secret.iter().any(|&b| b != 0) {
            return Err(PairingCodeError::InvalidSecret);
        }
        let host_name = truncate_utf8(host_name.as_ref(), Self::MAX_HOST_NAME_BYTES).to_owned();
        Ok(Self { host_id, secret, host_name })
    }

    /// Encodes as `lain1:<base64url>` with no padding.
    pub fn encode(&self) -> Result<String, PairingCodeError> {
        let uuid = parse_canonical_uuid(&self.host_id).ok_or(PairingCodeError::InvalidHostId)?;
        let name = truncate_utf8(&self.host_name, Self::MAX_HOST_NAME_BYTES).as_bytes();
        let mut payload = Vec::with_capacity(Self::FIXED_HEADER_LEN + name.len());
        payload.push(Self::VERSION);
        payload.extend_from_slice(&uuid);
        payload.extend_from_slice(&self.secret);
        payload.push(u8::try_from(name.len()).unwrap_or(0));
        payload.extend_from_slice(name);
        Ok(format!("{}{}", Self::PREFIX, base64url_encode(&payload)))
    }

    /// Decodes a `lain1:...` pairing code (ignoring surrounding or embedded whitespace).
    pub fn decode(raw: &str) -> Result<Self, PairingCodeError> {
        let stripped: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
        let body = stripped.strip_prefix(Self::PREFIX).ok_or(PairingCodeError::InvalidFormat)?;
        if body.is_empty() {
            return Err(PairingCodeError::InvalidFormat);
        }
        let bytes = base64url_decode(body).ok_or(PairingCodeError::InvalidFormat)?;
        if bytes.len() < Self::FIXED_HEADER_LEN {
            return Err(PairingCodeError::InvalidFormat);
        }
        if bytes[0] != Self::VERSION {
            return Err(PairingCodeError::UnsupportedVersion(bytes[0]));
        }
        let uuid: [u8; 16] = bytes[1..17].try_into().map_err(|_| PairingCodeError::InvalidFormat)?;
        let host_id = format_canonical_uuid(&uuid);
        let secret: [u8; Pair::SECRET_SIZE] =
            bytes[17..(17 + Pair::SECRET_SIZE)].try_into().map_err(|_| PairingCodeError::InvalidFormat)?;
        if !secret.iter().any(|&b| b != 0) {
            return Err(PairingCodeError::InvalidSecret);
        }
        let name_len = usize::from(bytes[17 + Pair::SECRET_SIZE]);
        if name_len > Self::MAX_HOST_NAME_BYTES || bytes.len() != Self::FIXED_HEADER_LEN + name_len {
            return Err(PairingCodeError::InvalidFormat);
        }
        let host_name = std::str::from_utf8(&bytes[Self::FIXED_HEADER_LEN..])
            .map_err(|_| PairingCodeError::InvalidFormat)?
            .to_owned();
        Self::new(host_id, secret, host_name)
    }
}

fn truncate_utf8(s: &str, max_bytes: usize) -> &str {
    if s.len() <= max_bytes {
        return s;
    }
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    &s[..end]
}

fn parse_canonical_uuid(s: &str) -> Option<[u8; 16]> {
    if !PairingAccounts::is_canonical_host_id(s) {
        return None;
    }
    let mut out = [0u8; 16];
    let mut hex = s.bytes().filter(|&b| b != b'-');
    for slot in &mut out {
        let hi = hex_nibble(hex.next()?)?;
        let lo = hex_nibble(hex.next()?)?;
        *slot = (hi << 4) | lo;
    }
    Some(out)
}

fn format_canonical_uuid(bytes: &[u8; 16]) -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut out = String::with_capacity(36);
    for (i, &b) in bytes.iter().enumerate() {
        if matches!(i, 4 | 6 | 8 | 10) {
            out.push('-');
        }
        out.push(char::from(HEX[usize::from(b >> 4)]));
        out.push(char::from(HEX[usize::from(b & 0x0F)]));
    }
    out
}

fn hex_nibble(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

const B64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn base64url_encode(input: &[u8]) -> String {
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = u32::from(chunk[0]);
        let b1 = u32::from(*chunk.get(1).unwrap_or(&0));
        let b2 = u32::from(*chunk.get(2).unwrap_or(&0));
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(char::from(B64URL[((n >> 18) & 0x3F) as usize]));
        out.push(char::from(B64URL[((n >> 12) & 0x3F) as usize]));
        if chunk.len() > 1 {
            out.push(char::from(B64URL[((n >> 6) & 0x3F) as usize]));
        }
        if chunk.len() > 2 {
            out.push(char::from(B64URL[(n & 0x3F) as usize]));
        }
    }
    out
}

fn base64url_decode(input: &str) -> Option<Vec<u8>> {
    let bytes = input.trim_end_matches('=').as_bytes();
    if bytes.len() % 4 == 1 {
        return None;
    }
    let val = |b: u8| -> Option<u32> {
        match b {
            b'A'..=b'Z' => Some(u32::from(b - b'A')),
            b'a'..=b'z' => Some(u32::from(b - b'a' + 26)),
            b'0'..=b'9' => Some(u32::from(b - b'0' + 52)),
            b'-' => Some(62),
            b'_' => Some(63),
            _ => None,
        }
    };
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    for chunk in bytes.chunks(4) {
        let v0 = val(chunk[0])?;
        let v1 = val(chunk[1])?;
        out.push(((v0 << 2) | (v1 >> 4)) as u8);
        if let Some(&c2) = chunk.get(2) {
            let v2 = val(c2)?;
            out.push((((v1 & 0x0F) << 4) | (v2 >> 2)) as u8);
            if let Some(&c3) = chunk.get(3) {
                let v3 = val(c3)?;
                out.push((((v2 & 0x03) << 6) | v3) as u8);
            }
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Must match `PairingCodeTests.goldenVectorMatchesExactWireEncoding` in Swift.
    #[test]
    fn golden_vector_matches_swift() {
        let mut secret = [0u8; 32];
        for (i, slot) in secret.iter_mut().enumerate() {
            *slot = (i + 1) as u8;
        }
        let code = PairingCode::new("01234567-89AB-CDEF-0123-456789ABCDEF", secret, "Studio").unwrap();
        let encoded = code.encode().unwrap();
        assert_eq!(
            encoded,
            "lain1:AQEjRWeJq83vASNFZ4mrze8BAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIAZTdHVkaW8"
        );
        assert_eq!(PairingCode::decode(&encoded).unwrap(), code);
    }

    #[test]
    fn rejects_invalid_inputs() {
        assert_eq!(PairingCode::decode("nope"), Err(PairingCodeError::InvalidFormat));
        assert_eq!(
            PairingCode::new("01234567-89AB-CDEF-0123-456789ABCDEF", [0u8; 32], "x"),
            Err(PairingCodeError::InvalidSecret)
        );
    }
}
