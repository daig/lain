//! Behaviour that differs between protocol versions (PROTOCOL-VERSIONING §3.4). Swift: `ProtocolFeature.swift`.

use crate::{NEWEST_VERSION, VersionList};

/// A behaviour some versions have. Code asks `feature.is_supported(link.version)` (or `Link::supports`),
/// never compares version numbers. A feature whose `until` is at or below the oldest supported version is
/// dead compatibility code: a test fails until it's deleted. Swift: `ProtocolFeature`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProtocolFeature {
    /// v4: the host sends `HostSetup` after `HelloAck` and whenever its setup changes.
    HostSetup,
}

impl ProtocolFeature {
    /// Every feature (Swift: `allCases`).
    pub const ALL: &'static [Self] = &[Self::HostSetup];

    /// The first version with the feature.
    pub const fn since(self) -> u8 {
        match self {
            Self::HostSetup => 4,
        }
    }

    /// The first version without it, when a newer behaviour replaced it; `None` while current.
    pub const fn until(self) -> Option<u8> {
        match self {
            Self::HostSetup => None,
        }
    }

    pub const fn is_supported(self, version: u8) -> bool {
        version >= self.since()
            && match self.until() {
                Some(until) => version < until,
                None => true,
            }
    }

    /// What updating the older side adds, for the version-skew line (PROTOCOL-VERSIONING §8).
    pub const fn summary(self) -> &'static str {
        match self {
            Self::HostSetup => "setup status on the iPad",
        }
    }

    /// What a session at `version` misses that `newest` has (`None`: the newest this process offers,
    /// [`VersionList::offered`], which a `LAIN_PROTOCOL_MAX` cap lowers).
    pub fn missing(version: u8, newest: Option<u8>) -> Vec<Self> {
        let newest = newest.or_else(|| VersionList::offered().newest()).unwrap_or(NEWEST_VERSION);
        Self::ALL.iter().copied().filter(|f| !f.is_supported(version) && f.is_supported(newest)).collect()
    }
}
