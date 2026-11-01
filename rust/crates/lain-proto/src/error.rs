/// Why bytes don't parse. Mirrors Swift's `ProtocolError`, case for case; the `Malformed` texts are
/// Swift's.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ProtocolError {
    /// Not enough bytes for the header or the declared field.
    #[error("truncated")]
    Truncated,
    #[error("bad magic 0x{0:04x}")]
    BadMagic(u16),
    /// A header version that is neither the handshake's nor one this build implements: a legacy peer
    /// (before negotiation) or garbage.
    #[error("protocol version mismatch: the peer framed in v{remote}")]
    VersionMismatch { remote: u8 },
    /// A type this build doesn't know, or one that doesn't exist in the frame's version.
    #[error("unknown message type 0x{0:02x}")]
    UnknownType(u8),
    #[error("reserved header field is not zero")]
    ReservedNonZero,
    #[error("payload of {0} bytes is too large")]
    PayloadTooLarge(u32),
    #[error("malformed: {0}")]
    Malformed(String),
}

pub type Result<T, E = ProtocolError> = std::result::Result<T, E>;
