//! Which side to update. Swift: `VersionGap.swift`.

use lain_proto::{HANDSHAKE_VERSION, LEGACY_VERSIONS, VersionList};

use crate::TransportError;

/// Why two lains can't hold a session over their protocol versions, and so which side to update
/// (PROTOCOL-VERSIONING §8). Role-agnostic: "peer" is the other device; `peer` says what it speaks, as a
/// phrase ("protocol v2", "protocol v5–v6", "a protocol from before v3"). Swift: `VersionGap`.
///
/// Swift's optional `local` arguments (default `VersionList.offered`) are explicit here.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum VersionGap {
    /// Every version the peer speaks is older than this side's oldest: update the peer.
    PeerOlder { peer: String },
    /// Every version the peer speaks is newer than this side's newest: update this side.
    PeerNewer { peer: String },
    /// Both name `version` but with different digests: different development builds of it.
    DifferentBuilds { version: u8 },
}

impl VersionGap {
    /// From a refused or failed link; `None` for errors that aren't about versions. Swift: `init?(_:local:)`.
    pub fn from_error(error: &TransportError, local: &VersionList) -> Option<Self> {
        match error {
            TransportError::VersionMismatch { remote } => Some(Self::legacy(*remote, local)),
            TransportError::NoCommonVersion { local, peer } => Some(Self::from_lists(local, peer)),
            _ => None,
        }
    }

    /// Both sides negotiated, and no version was common. Swift: `init(local:peer:)`.
    pub fn from_lists(local: &VersionList, peer: &VersionList) -> Self {
        if let Some(version) = local.conflicting(peer).into_iter().max() {
            return Self::DifferentBuilds { version };
        }
        match (peer.newest(), local.oldest()) {
            (Some(peer_newest), Some(local_oldest)) if peer_newest < local_oldest => {
                Self::PeerOlder { peer: format!("protocol {peer}") }
            }
            _ => Self::PeerNewer { peer: format!("protocol {peer}") },
        }
    }

    /// From a Bonjour TXT record, before any handshake; `None` when a version is shared (the handshake
    /// decides then). Swift: `init?(local:advertised:)`.
    pub fn from_advertised(local: &VersionList, advertised: &[u8]) -> Option<Self> {
        if advertised.iter().any(|v| local.contains(*v)) {
            return None;
        }
        let newest = advertised.iter().max();
        if let (Some(&newest), Some(local_newest)) = (newest, local.newest())
            && newest > local_newest
        {
            return Some(Self::PeerNewer { peer: format!("protocol {}", describe(advertised)) });
        }
        let peer =
            if advertised.is_empty() { "an unknown protocol".into() } else { format!("protocol {}", describe(advertised)) };
        Some(Self::PeerOlder { peer })
    }

    /// A peer from before negotiation: `remote` is its version (0: unknown, it answered in our framing).
    /// Swift: `legacy(_:local:)`.
    pub fn legacy(remote: u8, local: &VersionList) -> Self {
        if remote > local.newest().unwrap_or(0) && remote != HANDSHAKE_VERSION {
            return Self::PeerNewer { peer: format!("protocol v{remote}") };
        }
        let peer = if remote == 0 {
            format!("a protocol from before v{}", LEGACY_VERSIONS.end() + 1)
        } else {
            format!("protocol v{remote}")
        };
        Self::PeerOlder { peer }
    }
}

/// "v5", "v5–v6", "none".
fn describe(versions: &[u8]) -> String {
    match (versions.iter().min(), versions.iter().max()) {
        (Some(first), Some(last)) if first == last => format!("v{last}"),
        (Some(first), Some(last)) => format!("v{first}–v{last}"),
        _ => "none".into(),
    }
}
