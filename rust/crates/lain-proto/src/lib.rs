//! The lain wire format, byte for byte.
//!
//! Swift reference: `Packages/LainKit/Sources/LainProtocol/`; conformance fixture:
//! `Packages/LainKit/Tests/LainProtocolTests/GoldenBytes.swift`, which this crate's tests read at test time.
//! Brief: `docs/LINUX-HOST-PLAN.md`, `lain-proto`.
//!
//! Two layers (PROTOCOL-VERSIONING §3): the frozen handshake (`ChannelHello`, `ChannelAccept`, `Pair`, and
//! `Error` before a version is agreed), framed in header version [`HANDSHAKE_VERSION`]; and the session
//! messages, framed in the negotiated version. [`MessageCodec::lower`] writes a [`Message`] at one version
//! (exact, projected or unrepresentable); [`MessageCodec::decode`] and [`FrameParser`] lift frames back into
//! the newest version's model.
//!
//! Intended differences from Swift, all invisible on the wire:
//! - Fixed-size byte fields (session token, HMAC, pairing secret, digest) are arrays, so the sizes Swift
//!   checks with preconditions are checked by the type system.
//! - Version arguments that Swift takes as `nil` (meaning "the default") are explicit `u8`s or `Option`s;
//!   Rust has no default argument values to go stale (Swift's D30).

#[macro_use]
mod macros;

mod error;
mod feature;
mod header;
mod io;
mod message;
mod messages;
mod samples;
mod versions;

pub use error::{ProtocolError, Result};
pub use feature::ProtocolFeature;
pub use header::{FrameHeader, HeaderFlags, MessageType};
pub use io::{ByteReader, ByteWriter, Lowering, WireEnum};
pub use message::{Envelope, FrameParser, Lowered, Message, MessageCodec};
pub use messages::*;
pub use samples::ProtocolSamples;
pub use versions::{SchemaDigest, VersionEntry, VersionList};

use std::ops::RangeInclusive;

/// Header magic, written little-endian (§7.4). Swift: `LainProtocol.magic`.
pub const MAGIC: u16 = 0x4C41;

/// The header version of handshake frames: the frozen layer that negotiates the session's version
/// (PROTOCOL-VERSIONING §3.1). Higher than every legacy version, so a legacy peer's own mismatch message
/// says to update itself. Swift: `LainProtocol.handshakeVersion`.
pub const HANDSHAKE_VERSION: u8 = 0xFF;

/// Every protocol version this build implements, oldest first: the support window. v3 (below the floor since
/// v5): negotiation, the last breaking change; v4: `HostSetup`; v5: `StatsRequest` and `HostStats`; v6:
/// `TextInput`, `AudioConfig` and `AudioPacket`. (v4 stays, past the policy, for the hosts released at v4–v5.)
/// Swift: `LainProtocol.supportedVersions`.
pub const SUPPORTED_VERSIONS: &[u8] = &[4, 5, 6];

/// The lockstep major versions from before negotiation. A peer framing in one of them runs an older lain.
/// Swift: `LainProtocol.legacyVersions`.
pub const LEGACY_VERSIONS: RangeInclusive<u8> = 1..=2;

/// The newest version this build implements. Swift: `LainProtocol.newestVersion`.
pub const NEWEST_VERSION: u8 = SUPPORTED_VERSIONS[SUPPORTED_VERSIONS.len() - 1];

/// Every message starts with a fixed 24-byte header (§7.4). Swift: `LainProtocol.headerSize`.
pub const HEADER_SIZE: usize = 24;

/// The client's loopback listener port; the host dials it through usbmuxd (§7.2). Swift:
/// `LainProtocol.usbPort`.
pub const USB_PORT: u16 = 47800;

/// The Bonjour service the host advertises for Wi-Fi, with TXT `v` (the newest version), `vs` (every
/// supported version) and `id` (host id) (§7.7). Swift: `LainProtocol.bonjourServiceType`.
pub const BONJOUR_SERVICE_TYPE: &str = "_lain._tcp";

/// The environment variable that caps the versions this process offers (PROTOCOL-VERSIONING §3.2): an
/// integer in 1...254; anything else means no cap. It only narrows. Swift reads the `lainProtocolMax` user
/// default (`LainProtocol.versionCapKey`) instead; Linux has no user defaults (decision L5).
pub const VERSION_CAP_ENV: &str = "LAIN_PROTOCOL_MAX";
