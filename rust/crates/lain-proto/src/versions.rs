//! Version lists and schema digests (PROTOCOL-VERSIONING §3.2). Swift: `Versions.swift`.

use std::fmt;
use std::sync::OnceLock;

use sha2::{Digest, Sha256};

use crate::io::{ByteReader, ByteWriter};
use crate::{
    HANDSHAKE_VERSION, MessageCodec, ProtocolError, ProtocolSamples, Result, SUPPORTED_VERSIONS, VERSION_CAP_ENV,
};

/// One protocol version and the digest of its wire format. Swift: `VersionEntry`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct VersionEntry {
    pub version: u8,
    pub digest: [u8; VersionEntry::DIGEST_SIZE],
}

impl VersionEntry {
    pub const DIGEST_SIZE: usize = 8;
}

/// The versions one side supports, oldest first, as carried by `ChannelHello` and `ChannelAccept`. A
/// version is common to two lists only if its digests match too, so two builds of a version still under
/// development (or a stale build) don't count as speaking it. Swift: `VersionList`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub struct VersionList {
    entries: Vec<VersionEntry>,
}

impl VersionList {
    /// The most entries a list carries on the wire; a longer list is written cut to its first 16.
    pub const MAX_COUNT: usize = 16;

    /// Sorts by version; one entry per version (the first wins).
    pub fn new(entries: impl IntoIterator<Item = VersionEntry>) -> Self {
        let mut entries: Vec<VersionEntry> = entries.into_iter().collect();
        entries.sort_by_key(|e| e.version); // stable: the first of equal versions stays first
        entries.dedup_by_key(|e| e.version);
        Self { entries }
    }

    pub fn entries(&self) -> &[VersionEntry] {
        &self.entries
    }

    pub fn versions(&self) -> Vec<u8> {
        self.entries.iter().map(|e| e.version).collect()
    }

    pub fn contains(&self, version: u8) -> bool {
        self.entries.iter().any(|e| e.version == version)
    }

    pub fn newest(&self) -> Option<u8> {
        self.entries.last().map(|e| e.version)
    }

    pub fn oldest(&self) -> Option<u8> {
        self.entries.first().map(|e| e.version)
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    fn digest_of(&self, version: u8) -> Option<&[u8; VersionEntry::DIGEST_SIZE]> {
        self.entries.iter().find(|e| e.version == version).map(|e| &e.digest)
    }

    /// The highest version in both lists with equal digests: what a session runs at.
    pub fn highest_common(&self, other: &VersionList) -> Option<u8> {
        self.entries.iter().rev().find(|e| other.digest_of(e.version) == Some(&e.digest)).map(|e| e.version)
    }

    /// Versions both lists name but with different digests: different builds of the same version.
    pub fn conflicting(&self, other: &VersionList) -> Vec<u8> {
        self.entries
            .iter()
            .filter(|e| other.digest_of(e.version).is_some_and(|d| *d != e.digest))
            .map(|e| e.version)
            .collect()
    }

    /// Entries up to `max`; at least the oldest, so a cap below the window still offers something.
    pub fn capped(&self, max: Option<u8>) -> VersionList {
        let Some(max) = max else { return self.clone() };
        let kept: Vec<VersionEntry> = self.entries.iter().copied().filter(|e| e.version <= max).collect();
        if kept.is_empty() { VersionList::new(self.entries.first().copied()) } else { VersionList::new(kept) }
    }

    /// Every version this build implements, with the digests of its own encodings.
    pub fn supported() -> &'static VersionList {
        static SUPPORTED: OnceLock<VersionList> = OnceLock::new();
        SUPPORTED.get_or_init(|| {
            VersionList::new(
                SUPPORTED_VERSIONS.iter().map(|&v| VersionEntry { version: v, digest: SchemaDigest::compute(v) }),
            )
        })
    }

    /// What this process offers peers: [`supported`](Self::supported), capped by the environment variable
    /// [`VERSION_CAP_ENV`] (`LAIN_PROTOCOL_MAX`), read once. Swift reads the `lainProtocolMax` user default.
    pub fn offered() -> &'static VersionList {
        static OFFERED: OnceLock<VersionList> = OnceLock::new();
        OFFERED.get_or_init(|| {
            let cap = std::env::var(VERSION_CAP_ENV).ok();
            Self::supported().capped(Self::parse_cap(cap.as_deref()))
        })
    }

    /// A cap's value: an integer in 1...254, else no cap (as Swift treats `lainProtocolMax`, whose unset or
    /// unparsable value reads as 0).
    pub fn parse_cap(value: Option<&str>) -> Option<u8> {
        let n: i64 = value?.trim().parse().ok()?;
        (1..=254).contains(&n).then_some(n as u8)
    }
}

/// "v3–v4" (en dash), "v3", "none".
impl fmt::Display for VersionList {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match (self.oldest(), self.newest()) {
            (Some(o), Some(n)) if o == n => write!(f, "v{n}"),
            (Some(o), Some(n)) => write!(f, "v{o}–v{n}"),
            _ => f.write_str("none"),
        }
    }
}

impl ByteWriter {
    /// count u8, then (version u8, `digest[8]`) per entry, at most 16: frozen (PROTOCOL-VERSIONING §3.1).
    pub fn version_list(&mut self, list: &VersionList) {
        let n = list.entries.len().min(VersionList::MAX_COUNT);
        self.u8(n as u8);
        for e in &list.entries[..n] {
            self.u8(e.version);
            self.raw(&e.digest);
        }
    }
}

impl ByteReader<'_> {
    /// Strict: at most 16 entries, versions strictly ascending, never 0 or the handshake version.
    pub fn version_list(&mut self) -> Result<VersionList> {
        let n = usize::from(self.u8()?);
        if n > VersionList::MAX_COUNT {
            return Err(ProtocolError::Malformed(format!("{n} versions")));
        }
        let mut entries: Vec<VersionEntry> = Vec::with_capacity(n);
        for _ in 0..n {
            let version = self.u8()?;
            let last = entries.last().map_or(0, |e| e.version);
            if version == 0 || version == HANDSHAKE_VERSION || version <= last {
                return Err(ProtocolError::Malformed("version list".into()));
            }
            entries.push(VersionEntry { version, digest: self.raw_array()? });
        }
        Ok(VersionList { entries })
    }
}

/// The digest of one version's wire format: the first 8 bytes of SHA-256 over the full frames (sequence 0,
/// timestamp 0), at that version, of every session message in [`ProtocolSamples::all`] that exists in it,
/// in sample order. Computed from this crate's own codec, so a different (or stale) build of a version
/// shows up as a mismatch. Swift: `SchemaDigest`.
pub struct SchemaDigest;

impl SchemaDigest {
    pub fn compute(version: u8) -> [u8; VersionEntry::DIGEST_SIZE] {
        let mut hash = Sha256::new();
        for message in ProtocolSamples::all().iter().filter(|m| m.ty().is_session()) {
            if let Some(bytes) = MessageCodec::lower(message, version, 0, 0, None).bytes() {
                hash.update(bytes);
            }
        }
        let full = hash.finalize();
        full[..VersionEntry::DIGEST_SIZE].try_into().expect("SHA-256 is 32 bytes")
    }
}
