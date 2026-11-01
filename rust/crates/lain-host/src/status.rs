//! What the host's status shows (Swift: `LainHostCore/HostStatus.swift`).

use lain_link::{LinkTransport, VersionGap};
use lain_proto::VersionList;

/// The session's state, for the daemon's status (Swift: `HostStatus`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum HostStatus {
    /// No iPad on USB.
    WaitingForIPad,
    /// An iPad is attached; dialing lain on it (it must be open in the foreground, §7.2).
    Connecting,
    /// A session is up, over USB or the network (§7.7).
    Connected { device_model: String, via: LinkTransport },
    /// usbmuxd failed, lain on the iPad speaks another protocol, or similar; the session retries on its own.
    Error(String),
}

impl HostStatus {
    /// The text of [`capture_backing_off`](Self::capture_backing_off).
    pub const CAPTURE_BACKING_OFF: &'static str = "backing off after capture failures";

    /// A session over USB (Swift's default `via`).
    pub fn connected_usb(device_model: impl Into<String>) -> Self {
        Self::Connected { device_model: device_model.into(), via: LinkTransport::Usb }
    }

    /// lain on the iPad shares no protocol version with this one (PROTOCOL-VERSIONING §8): which side to
    /// update. `local` is what this host offers (Swift reads the global `VersionList.offered`; here the
    /// session's own list, which the config may have capped).
    ///
    /// Intended difference: Swift says "this Mac"; the Linux host says "this computer".
    pub fn version_gap(gap: &VersionGap, local: &VersionList) -> Self {
        Self::Error(match gap {
            VersionGap::PeerOlder { peer } => {
                format!("lain on the iPad is too old (it speaks {peer}, this computer protocol {local}): update it")
            }
            VersionGap::PeerNewer { peer } => format!(
                "lain on the iPad is newer (it speaks {peer}, this computer protocol {local}): update lain on this computer"
            ),
            VersionGap::DifferentBuilds { version } => format!(
                "the iPad runs a different development build of protocol v{version}: update both from the same tree"
            ),
        })
    }

    /// The gap a very old app (v1) shows: it keeps closing the link right after `ChannelHello` without a word.
    /// Swift: `HostStatus.olderAppGap`.
    pub fn older_app_gap() -> VersionGap {
        VersionGap::PeerOlder { peer: "an older protocol".into() }
    }

    /// Swift: `HostStatus.iPadNeedsUpdate`.
    pub fn ipad_needs_update(local: &VersionList) -> Self {
        Self::version_gap(&Self::older_app_gap(), local)
    }

    /// Video capture stopped on its own in several sessions in a row: the attached iPad is dialed again once
    /// the backoff is over, or at once if it is replugged. Swift: `HostStatus.captureBackingOff`.
    pub fn capture_backing_off() -> Self {
        Self::Error(Self::CAPTURE_BACKING_OFF.into())
    }

    /// The status line (Swift: `title`).
    pub fn title(&self) -> String {
        match self {
            Self::WaitingForIPad => "Waiting for iPad".into(),
            Self::Connecting => "iPad attached: open lain on the iPad".into(),
            Self::Connected { device_model, via } => format!("Connected to {device_model} over {}", menu_name(via)),
            Self::Error(why) => format!("Error: {why}"),
        }
    }

    pub fn is_connected(&self) -> bool {
        matches!(self, Self::Connected { .. })
    }
}

/// How a transport is named in the status (Swift: `LinkTransport.menuName`): `USB`, or `LAN (<interface>)` /
/// `LAN` for a network link.
///
/// Intended difference: Swift says "Wi-Fi (LAN, en1)", which is wrong on Ethernet, the Linux host's primary
/// link (L4). Linux has no AWDL, so a peer-to-peer path never occurs here; it keeps Swift's "Wi-Fi (AWDL)".
pub fn menu_name(transport: &LinkTransport) -> String {
    match transport {
        LinkTransport::Usb => "USB".into(),
        LinkTransport::Network { peer_to_peer: true, .. } => "Wi-Fi (AWDL)".into(),
        LinkTransport::Network { interface: Some(interface), peer_to_peer: false } => format!("LAN ({interface})"),
        LinkTransport::Network { interface: None, peer_to_peer: false } => "LAN".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles() {
        assert_eq!(HostStatus::WaitingForIPad.title(), "Waiting for iPad");
        assert_eq!(HostStatus::Connecting.title(), "iPad attached: open lain on the iPad");
        assert_eq!(HostStatus::connected_usb("iPad16,6").title(), "Connected to iPad16,6 over USB");
        let lan = LinkTransport::Network { interface: Some("enp5s0".into()), peer_to_peer: false };
        assert_eq!(
            HostStatus::Connected { device_model: "iPad16,6".into(), via: lan }.title(),
            "Connected to iPad16,6 over LAN (enp5s0)"
        );
        let unknown = LinkTransport::Network { interface: None, peer_to_peer: false };
        assert_eq!(menu_name(&unknown), "LAN");
        assert_eq!(HostStatus::capture_backing_off().title(), "Error: backing off after capture failures");
    }

    #[test]
    fn version_gaps_name_the_side_to_update() {
        let local = VersionList::supported().clone();
        let older = HostStatus::version_gap(&VersionGap::PeerOlder { peer: "protocol v2".into() }, &local);
        assert_eq!(
            older.title(),
            format!("Error: lain on the iPad is too old (it speaks protocol v2, this computer protocol {local}): update it")
        );
        let newer = HostStatus::version_gap(&VersionGap::PeerNewer { peer: "protocol v9".into() }, &local);
        assert!(newer.title().ends_with("update lain on this computer"));
        let builds = HostStatus::version_gap(&VersionGap::DifferentBuilds { version: 4 }, &local);
        assert!(builds.title().contains("different development build of protocol v4"));
        assert!(HostStatus::ipad_needs_update(&local).title().contains("it speaks an older protocol"));
    }
}
