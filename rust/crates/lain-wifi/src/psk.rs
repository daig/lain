//! The Wi-Fi pre-shared key of one pairing. Swift: `WiFiPSK` (`WiFiSecurity.swift`).

use std::fmt;

use hkdf::Hkdf;
use sha2::Sha256;

/// The HKDF salt.
const SALT: &[u8] = b"lain";
/// The HKDF info of the identity.
const IDENTITY_INFO: &[u8] = b"lain wifi psk identity v1";
/// The HKDF info of the key.
const KEY_INFO: &[u8] = b"lain wifi tls-psk v1";
/// The identity's prefix; 16 lowercase hex digits (8 derived bytes) follow.
pub const IDENTITY_PREFIX: &str = "lain1-";

/// The Wi-Fi TLS pre-shared key of one pairing (§7.6, §7.7, D29), derived from the 32-byte pairing secret
/// with HKDF-SHA256 (salt `lain`; distinct info strings, so the key and the identity are independent). TLS
/// 1.2 sends the identity in the clear; being derived, it reveals nothing about the secret, and it lets the
/// host hold one PSK per paired iPad. Swift: `WiFiPSK`.
///
/// `Debug` and `Display` show the identity only, never the key (Swift: `description` and the mirror).
#[derive(Clone, PartialEq, Eq)]
pub struct WiFiPsk {
    identity: String,
    key: [u8; 32],
}

impl WiFiPsk {
    /// The PSK of `secret` (any length; pairing secrets are 32 bytes). Swift: `WiFiPSK(secret:)`.
    pub fn new(secret: &[u8]) -> Self {
        let hk = Hkdf::<Sha256>::new(Some(SALT), secret);
        let mut id = [0u8; 8];
        let mut key = [0u8; 32];
        // HKDF-SHA256 expands up to 255 × 32 bytes; 8 and 32 always fit, so neither call can fail.
        if hk.expand(IDENTITY_INFO, &mut id).is_err() || hk.expand(KEY_INFO, &mut key).is_err() {
            unreachable!("HKDF-SHA256 output of at most 32 bytes");
        }
        Self { identity: format!("{IDENTITY_PREFIX}{}", hex::encode(id)), key }
    }

    /// Any identity with any key: tests (a known identity with the wrong key). Swift: the internal
    /// `init(identity:key:)`.
    pub fn from_parts(identity: impl Into<String>, key: [u8; 32]) -> Self {
        Self { identity: identity.into(), key }
    }

    /// `lain1-` + 16 lowercase hex digits.
    pub fn identity(&self) -> &str {
        &self.identity
    }

    /// 32 bytes. Never log it.
    pub fn key(&self) -> &[u8; 32] {
        &self.key
    }
}

impl fmt::Debug for WiFiPsk {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WiFiPsk").field("identity", &self.identity).finish_non_exhaustive()
    }
}

impl fmt::Display for WiFiPsk {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.identity)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Vectors computed independently in Python (RFC 5869) and confirmed with `hkdf` 0.13 (the brief).
    #[test]
    fn the_briefs_vectors() {
        let psk = WiFiPsk::new(&[0x01; 32]);
        assert_eq!(psk.identity(), "lain1-80cc83b0acfeede3");
        assert_eq!(hex::encode(psk.key()), "2382ec84b9fe8cc9cb35efade101a13ef66f5388f29afe07fae5951d3a44ee58");
        // `ProtocolSamples`' `Pair` secret, bytes 200..<232.
        let pair: Vec<u8> = (200..232).collect();
        assert_eq!(WiFiPsk::new(&pair).identity(), "lain1-4f9c3084fa887082");
    }

    /// Swift: `NetworkStreamPolicy.pskDerivationMatchesRFC5869KnownAnswers`.
    #[test]
    fn psk_derivation_matches_swifts_known_answers() {
        let a = WiFiPsk::new(&(0..32).collect::<Vec<u8>>());
        assert_eq!(a.identity(), "lain1-f5e4a0d2d0bc6c77");
        assert_eq!(hex::encode(a.key()), "af59ff3f0c6806315b77b17b6ef3405fce9765edc8dd0aaea59b347053c3041c");
        let b = WiFiPsk::new(&[0xA5; 32]);
        assert_eq!(b.identity(), "lain1-21c490049bb2a2e9");
        assert_eq!(hex::encode(b.key()), "c47625da67301dce17d1482ce6a0f834dbfcadadcd879dd871b4ba793b1fdc6f");
    }

    /// Swift: `NetworkStreamPolicy.thePSKPrintsOnlyItsIdentity`.
    #[test]
    fn the_psk_prints_only_its_identity() {
        let secret: [u8; 32] = std::array::from_fn(|i| (i as u8).wrapping_mul(37).wrapping_add(11));
        let psk = WiFiPsk::new(&secret);
        assert!(psk.identity().starts_with(IDENTITY_PREFIX) && psk.identity().len() == 22);
        assert_eq!(psk.to_string(), psk.identity());
        let debug = format!("{psk:?}");
        assert!(debug.contains(psk.identity()));
        assert!(!debug.contains("key"));
        assert!(!debug.contains(&hex::encode(psk.key())));
        assert!(!format!("{psk:#?}").contains("key"));
    }
}
