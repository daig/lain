//! Explicit little-endian binary encoding for headers and payloads (§7.4). Writer and reader carry the
//! protocol version they write or read, so a payload's fields can depend on it (PROTOCOL-VERSIONING §3.3).
//! Swift: `ByteIO.swift`.

use crate::{ProtocolError, Result};

/// What happens to a newer field's non-default value when an older version is written. Swift:
/// `ByteWriter.Lowering`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lowering {
    /// Advisory: a receiver that ignores it still behaves correctly. It's left out.
    Drop,
    /// The message can't be sent at that version; senders check the feature first.
    Refuse,
}

/// Writes payload fields at one version. Swift: `ByteWriter`.
#[derive(Debug, Clone)]
pub struct ByteWriter {
    bytes: Vec<u8>,
    version: u8,
    dropped: Vec<&'static str>,
    refused: Option<String>,
}

impl ByteWriter {
    /// A writer for `version`: a session version, or [`HANDSHAKE_VERSION`](crate::HANDSHAKE_VERSION).
    pub fn new(version: u8) -> Self {
        Self::with_capacity(64, version)
    }

    pub fn with_capacity(capacity: usize, version: u8) -> Self {
        Self { bytes: Vec::with_capacity(capacity), version, dropped: Vec::new(), refused: None }
    }

    /// The version being written.
    pub fn version(&self) -> u8 {
        self.version
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    pub fn into_bytes(self) -> Vec<u8> {
        self.bytes
    }

    /// Advisory fields left out because the version predates them: the message was projected.
    pub fn dropped(&self) -> &[&'static str] {
        &self.dropped
    }

    /// Why the message can't be written at this version, if it can't.
    pub fn refused(&self) -> Option<&str> {
        self.refused.as_deref()
    }

    pub(crate) fn into_parts(self) -> (Vec<u8>, Vec<&'static str>, Option<String>) {
        (self.bytes, self.dropped, self.refused)
    }

    /// A field added in version `since`: written from that version on. Writing an older version leaves it
    /// out, and a non-default value is then dropped or refused as `lowering` says.
    pub fn since<T: PartialEq>(
        &mut self,
        since: u8,
        name: &'static str,
        value: &T,
        default: &T,
        lowering: Lowering,
        write: impl FnOnce(&mut Self, &T),
    ) {
        if self.version >= since {
            return write(self, value);
        }
        if value == default {
            return;
        }
        match lowering {
            Lowering::Drop => self.dropped.push(name),
            Lowering::Refuse => self.refuse(format!("{name} doesn't exist in v{}", self.version)),
        }
    }

    /// Marks the message unrepresentable at this version (the first reason wins).
    pub fn refuse(&mut self, why: impl Into<String>) {
        if self.refused.is_none() {
            self.refused = Some(why.into());
        }
    }

    pub fn u8(&mut self, v: u8) {
        self.bytes.push(v);
    }
    pub fn bool(&mut self, v: bool) {
        self.bytes.push(u8::from(v));
    }
    pub fn u16(&mut self, v: u16) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn u32(&mut self, v: u32) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn u64(&mut self, v: u64) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    pub fn i64(&mut self, v: i64) {
        self.bytes.extend_from_slice(&v.to_le_bytes());
    }
    /// Written via its bit pattern (NaN payloads and signed zeros survive).
    pub fn f32(&mut self, v: f32) {
        self.u32(v.to_bits());
    }
    /// Written via its bit pattern (NaN payloads and signed zeros survive).
    pub fn f64(&mut self, v: f64) {
        self.u64(v.to_bits());
    }
    /// Raw bytes with no length prefix (fixed-size fields).
    pub fn raw(&mut self, v: &[u8]) {
        self.bytes.extend_from_slice(v);
    }
    /// u32 length prefix + bytes.
    ///
    /// # Panics
    /// If `v` is 4 GiB or longer (Swift traps too).
    pub fn blob(&mut self, v: &[u8]) {
        self.u32(u32::try_from(v.len()).expect("blob of 4 GiB or more"));
        self.bytes.extend_from_slice(v);
    }
    /// u16 length prefix + UTF-8, cut at 65535 bytes exactly as Swift cuts it: at that byte, even inside a
    /// character (the receiver then rejects the invalid UTF-8).
    pub fn string(&mut self, v: &str) {
        let utf8 = &v.as_bytes()[..v.len().min(usize::from(u16::MAX))];
        self.u16(utf8.len() as u16);
        self.bytes.extend_from_slice(utf8);
    }
}

/// Reads payload fields at one version. Swift: `ByteReader`.
#[derive(Debug, Clone)]
pub struct ByteReader<'a> {
    bytes: &'a [u8],
    index: usize,
    version: u8,
}

/// A `u8`-valued wire enum (implemented by every enum this crate declares).
pub trait WireEnum: Sized + Copy {
    /// The Swift type's name, as Swift's `Malformed` text names it.
    const SWIFT_NAME: &'static str;
    fn raw(self) -> u8;
    fn from_raw(raw: u8) -> Option<Self>;
}

impl<'a> ByteReader<'a> {
    /// A reader for `version`: a session version, or [`HANDSHAKE_VERSION`](crate::HANDSHAKE_VERSION).
    pub fn new(bytes: &'a [u8], version: u8) -> Self {
        Self { bytes, index: 0, version }
    }

    /// The version being read.
    pub fn version(&self) -> u8 {
        self.version
    }

    pub fn remaining(&self) -> usize {
        self.bytes.len() - self.index
    }

    /// A field added in version `since`: read from that version on, `default` before it (lift,
    /// PROTOCOL-VERSIONING §3.3).
    pub fn since<T>(&mut self, since: u8, default: T, read: impl FnOnce(&mut Self) -> Result<T>) -> Result<T> {
        if self.version >= since { read(self) } else { Ok(default) }
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        if self.remaining() < n {
            return Err(ProtocolError::Truncated);
        }
        let s = &self.bytes[self.index..self.index + n];
        self.index += n;
        Ok(s)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N]> {
        Ok(self.take(N)?.try_into().expect("take returns N bytes"))
    }

    pub fn u8(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    /// Only 0 and 1 are valid.
    pub fn bool(&mut self) -> Result<bool> {
        match self.u8()? {
            0 => Ok(false),
            1 => Ok(true),
            _ => Err(ProtocolError::Malformed("bool".into())),
        }
    }
    pub fn u16(&mut self) -> Result<u16> {
        self.array().map(u16::from_le_bytes)
    }
    pub fn u32(&mut self) -> Result<u32> {
        self.array().map(u32::from_le_bytes)
    }
    pub fn u64(&mut self) -> Result<u64> {
        self.array().map(u64::from_le_bytes)
    }
    pub fn i64(&mut self) -> Result<i64> {
        self.array().map(i64::from_le_bytes)
    }
    pub fn f32(&mut self) -> Result<f32> {
        self.u32().map(f32::from_bits)
    }
    pub fn f64(&mut self) -> Result<f64> {
        self.u64().map(f64::from_bits)
    }
    /// `n` raw bytes.
    pub fn raw(&mut self, n: usize) -> Result<Vec<u8>> {
        self.take(n).map(<[u8]>::to_vec)
    }
    /// A fixed-size raw field.
    pub fn raw_array<const N: usize>(&mut self) -> Result<[u8; N]> {
        self.array()
    }
    /// u32 length prefix + bytes.
    pub fn blob(&mut self) -> Result<Vec<u8>> {
        let n = self.u32()?;
        self.raw(n as usize)
    }
    /// u16 length prefix + UTF-8, which must be valid.
    pub fn string(&mut self) -> Result<String> {
        let n = self.u16()?;
        let b = self.take(usize::from(n))?;
        match std::str::from_utf8(b) {
            Ok(s) => Ok(s.to_owned()),
            Err(_) => Err(ProtocolError::Malformed("utf8".into())),
        }
    }
    /// A raw enum value that must be known.
    pub fn enum_value<E: WireEnum>(&mut self) -> Result<E> {
        let raw = self.u8()?;
        E::from_raw(raw).ok_or_else(|| ProtocolError::Malformed(format!("{} {raw}", E::SWIFT_NAME)))
    }
    /// Payloads must be consumed exactly; trailing bytes mean a malformed or mismatched message.
    pub fn finish(&self) -> Result<()> {
        match self.remaining() {
            0 => Ok(()),
            n => Err(ProtocolError::Malformed(format!("{n} trailing bytes"))),
        }
    }
}
