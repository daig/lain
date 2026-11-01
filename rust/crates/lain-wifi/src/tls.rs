//! TLS for Wi-Fi links on OpenSSL. Swift: `WiFiTLS`, `OfferedPSKIdentities` (`WiFiSecurity.swift`) and
//! `NegotiatedTLS` (`NetworkStream.swift`).

use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, Mutex, OnceLock};

use openssl::error::ErrorStack;
use openssl::ssl::{
    Ssl, SslContext, SslContextBuilder, SslMethod, SslOptions, SslRef, SslSessionCacheMode, SslVerifyMode, SslVersion,
};

use crate::{WiFiError, WiFiPsk};

/// `TLS 1.2` (`tls_protocol_version_t.TLSv12`). Swift: `WiFiTLS.version`.
pub const TLS_VERSION: u16 = 0x0303;
/// `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`. Swift: `WiFiTLS.cipherSuite`.
pub const CIPHER_SUITE: u16 = 0xCCAC;
/// [`CIPHER_SUITE`] by OpenSSL's name: the whole cipher list, in both roles.
pub const CIPHER_LIST: &str = "ECDHE-PSK-CHACHA20-POLY1305";

/// What a TLS handshake negotiated (D29 expects TLS 1.2 with 0xCCAC). Swift: `NegotiatedTLS`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NegotiatedTls {
    pub version: u16,
    pub cipher_suite: u16,
}

impl NegotiatedTls {
    /// What every Wi-Fi connection must negotiate. Swift: `WiFiTLS.required`.
    pub const REQUIRED: Self = Self { version: TLS_VERSION, cipher_suite: CIPHER_SUITE };

    /// What `ssl` negotiated; `None` before the handshake.
    pub fn of(ssl: &SslRef) -> Option<Self> {
        let cipher = ssl.current_cipher()?;
        let [hi, lo] = cipher.protocol_id();
        let version = match ssl.version2()? {
            SslVersion::TLS1_3 => 0x0304,
            SslVersion::TLS1_2 => 0x0303,
            SslVersion::TLS1_1 => 0x0302,
            SslVersion::TLS1 => 0x0301,
            SslVersion::SSL3 => 0x0300,
            _ => 0,
        };
        Some(Self { version, cipher_suite: u16::from_be_bytes([hi, lo]) })
    }
}

impl fmt::Display for NegotiatedTls {
    /// `TLS 1.2 suite 0xCCAC`, as Swift's `description`.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.version == TLS_VERSION {
            f.write_str("TLS 1.2")?;
        } else {
            write!(f, "TLS 0x{:x}", self.version)?;
        }
        write!(f, " suite 0x{:X}", self.cipher_suite)
    }
}

/// Only [`NegotiatedTls::REQUIRED`] opens, in both roles. Swift: `NetworkStream.Core.becameReady`'s check.
/// With OpenSSL configured by this crate nothing else can complete (the cipher list is the one suite and
/// TLS is pinned to 1.2); the check stays, as in Swift, so a configuration slip fails closed.
pub(crate) fn check_negotiated(ssl: &SslRef) -> Result<NegotiatedTls, WiFiError> {
    match NegotiatedTls::of(ssl) {
        Some(tls) if tls == NegotiatedTls::REQUIRED => Ok(tls),
        other => Err(WiFiError::UnexpectedTls(other)),
    }
}

/// One pairing in a [`PskTable`].
#[derive(Clone)]
struct Entry {
    key: [u8; 32],
    secret: Vec<u8>,
}

/// The live identity → (key, secret) map the server's PSK callback reads. Cheap to clone (the clones share
/// the map). [`replace`](Self::replace) swaps the whole map at once, so a new pairing needs no restart and
/// a handshake sees either the old map or the new one. Swift has no counterpart: Network.framework fixes
/// the PSKs when a listener is created, so `HostWiFiListener` restarts its listener instead.
#[derive(Clone, Default)]
pub struct PskTable(Arc<Mutex<Arc<BTreeMap<String, Entry>>>>);

impl PskTable {
    pub fn new() -> Self {
        Self::default()
    }

    /// Holding the PSK of every secret in `secrets`.
    pub fn with_secrets<I, S>(secrets: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<[u8]>,
    {
        let table = Self::new();
        table.replace(secrets);
        table
    }

    /// Replaces every PSK with those of `secrets`; returns how many identities the table now holds.
    pub fn replace<I, S>(&self, secrets: I) -> usize
    where
        I: IntoIterator<Item = S>,
        S: AsRef<[u8]>,
    {
        let map: BTreeMap<String, Entry> = secrets
            .into_iter()
            .map(|s| {
                let psk = WiFiPsk::new(s.as_ref());
                (psk.identity().to_owned(), Entry { key: *psk.key(), secret: s.as_ref().to_vec() })
            })
            .collect();
        let count = map.len();
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = Arc::new(map);
        count
    }

    /// The identities, sorted (for logs: never the keys).
    pub fn identities(&self) -> Vec<String> {
        self.snapshot().keys().cloned().collect()
    }

    pub fn len(&self) -> usize {
        self.snapshot().len()
    }

    pub fn is_empty(&self) -> bool {
        self.snapshot().is_empty()
    }

    /// The current map. The lock is held only to clone an `Arc`, never across a read of the map.
    fn snapshot(&self) -> Arc<BTreeMap<String, Entry>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

impl fmt::Debug for PskTable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("PskTable").field(&self.identities()).finish()
    }
}

/// What the server's PSK callback chose for one connection, kept on its `Ssl` (ex data) and read back
/// after the handshake: the only record of which pairing TLS proved. Swift: `OfferedPSKIdentities`, which
/// keys the selection block's identity by the connection's TLS metadata.
#[derive(Clone)]
pub(crate) struct Chosen {
    pub identity: String,
    pub secret: Vec<u8>,
}

/// The ex-data slot for [`Chosen`]; made once, before any callback can run ([`server_context`]), so the
/// callback only reads it.
fn chosen_index() -> Result<openssl::ex_data::Index<Ssl, Chosen>, ErrorStack> {
    static INDEX: OnceLock<openssl::ex_data::Index<Ssl, Chosen>> = OnceLock::new();
    if let Some(index) = INDEX.get() {
        return Ok(*index);
    }
    let index = Ssl::new_ex_index::<Chosen>()?;
    // A race makes a second index, unused; harmless.
    Ok(*INDEX.get_or_init(|| index))
}

/// What the PSK callback chose for `ssl`, after its handshake.
pub(crate) fn chosen(ssl: &SslRef) -> Option<Chosen> {
    ssl.ex_data(chosen_index().ok()?).cloned()
}

/// The settings both roles share. Swift: `WiFiTLS.options`.
fn common(builder: &mut SslContextBuilder) -> Result<(), ErrorStack> {
    builder.set_min_proto_version(Some(SslVersion::TLS1_2))?;
    builder.set_max_proto_version(Some(SslVersion::TLS1_2))?;
    builder.set_cipher_list(CIPHER_LIST)?;
    // No tickets or resumption: every connection proves a PSK the listener holds now.
    builder.set_options(SslOptions::NO_TICKET | SslOptions::NO_RENEGOTIATION | SslOptions::NO_COMPRESSION);
    builder.set_session_cache_mode(SslSessionCacheMode::OFF);
    builder.set_verify(SslVerifyMode::NONE);
    Ok(())
}

/// The listener's context: one PSK per entry of `table`, read live at each handshake. An unknown identity
/// fails the handshake (alert `unknown_psk_identity`); with an empty table every handshake fails. Swift:
/// `WiFiTLS.serverOptions(_:recordingInto:)`.
///
/// The callback never panics or blocks: it clones an `Arc` under a mutex no one holds for longer, copies
/// 32 bytes and records its choice on the connection.
pub(crate) fn server_context(table: PskTable) -> Result<SslContext, ErrorStack> {
    let index = chosen_index()?;
    let mut builder = SslContext::builder(SslMethod::tls_server())?;
    common(&mut builder)?;
    builder.set_psk_server_callback(move |ssl, identity, psk| {
        let Some(identity) = identity.and_then(|b| std::str::from_utf8(b).ok()) else { return Ok(0) };
        let map = table.snapshot();
        let Some(entry) = map.get(identity) else { return Ok(0) };
        let Some(out) = psk.get_mut(..entry.key.len()) else { return Ok(0) };
        out.copy_from_slice(&entry.key);
        ssl.set_ex_data(index, Chosen { identity: identity.to_owned(), secret: entry.secret.clone() });
        Ok(entry.key.len())
    });
    Ok(builder.build())
}

/// The dialer's context: it offers its one pairing's PSK. Swift: `WiFiTLS.clientOptions`.
///
/// Difference from Swift: Network.framework also offers the plain-PSK suites 0xA8, 0xA9, 0xAF and 0xAE
/// whenever a PSK is set (no public API removes them); OpenSSL offers exactly [`CIPHER_LIST`].
pub(crate) fn client_context(psk: &WiFiPsk) -> Result<SslContext, ErrorStack> {
    let mut builder = SslContext::builder(SslMethod::tls_client())?;
    common(&mut builder)?;
    let identity = psk.identity().as_bytes().to_vec();
    let key = *psk.key();
    builder.set_psk_client_callback(move |_ssl, _hint, identity_out, psk_out| {
        // The identity as a NUL-terminated C string.
        let (Some(id), Some(k)) = (identity_out.get_mut(..identity.len() + 1), psk_out.get_mut(..key.len())) else {
            return Ok(0);
        };
        id[..identity.len()].copy_from_slice(&identity);
        id[identity.len()] = 0;
        k.copy_from_slice(&key);
        Ok(key.len())
    });
    Ok(builder.build())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Swift: `NetworkStreamPolicy.negotiatedTLSDescribesItself`.
    #[test]
    fn negotiated_tls_describes_itself() {
        assert_eq!(NegotiatedTls { version: 0x0303, cipher_suite: 0xCCAC }.to_string(), "TLS 1.2 suite 0xCCAC");
        assert_eq!(NegotiatedTls::REQUIRED, NegotiatedTls { version: 0x0303, cipher_suite: 0xCCAC });
        assert_eq!(NegotiatedTls { version: 0x0304, cipher_suite: 0x1303 }.to_string(), "TLS 0x304 suite 0x1303");
    }

    #[test]
    fn the_table_swaps_in_place_and_shows_only_identities() {
        let table = PskTable::with_secrets([[1u8; 32], [2; 32]]);
        let clone = table.clone();
        assert_eq!(table.len(), 2);
        assert_eq!(clone.identities(), {
            let mut ids = vec![WiFiPsk::new(&[1; 32]).identity().to_owned(), WiFiPsk::new(&[2; 32]).identity().to_owned()];
            ids.sort();
            ids
        });
        assert_eq!(table.replace([[3u8; 32]]), 1);
        assert_eq!(clone.identities(), vec![WiFiPsk::new(&[3; 32]).identity().to_owned()]);
        let debug = format!("{clone:?}");
        assert!(debug.contains("lain1-") && !debug.contains(&hex::encode(WiFiPsk::new(&[3; 32]).key())));
        table.replace(Vec::<Vec<u8>>::new());
        assert!(clone.is_empty());
    }
}
