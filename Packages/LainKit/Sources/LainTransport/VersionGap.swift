/// Why two lains can't hold a session over their protocol versions, and so which side to update
/// (PROTOCOL-VERSIONING §8). Role-agnostic: "peer" is the other device; `peer` says what it speaks, as a
/// phrase ("protocol v2", "protocol v5–v6", "a protocol from before v3").
public enum VersionGap: Sendable, Equatable {
    /// Every version the peer speaks is older than this side's oldest: update the peer.
    case peerOlder(peer: String)
    /// Every version the peer speaks is newer than this side's newest: update this side.
    case peerNewer(peer: String)
    /// Both name `version` but with different digests: different development builds of it.
    case differentBuilds(version: UInt8)

    /// From a refused or failed link; nil for errors that aren't about versions. `local` nil:
    /// `VersionList.offered`.
    public init?(_ error: any Error, local: VersionList? = nil) {
        switch error as? TransportError {
        case .versionMismatch(let remote)?: self = .legacy(remote, local: local)
        case .noCommonVersion(let local, let peer)?: self.init(local: local, peer: peer)
        default: return nil
        }
    }

    /// Both sides negotiated, and no version was common.
    public init(local: VersionList, peer: VersionList) {
        if let version = local.conflicting(with: peer).max() {
            self = .differentBuilds(version: version)
        } else if let peerNewest = peer.newest, let localOldest = local.oldest, peerNewest < localOldest {
            self = .peerOlder(peer: "protocol \(peer)")
        } else {
            self = .peerNewer(peer: "protocol \(peer)")
        }
    }

    /// From a Bonjour TXT record, before any handshake; nil when a version is shared (the handshake
    /// decides then). `local` nil: `VersionList.offered`.
    public init?(local: VersionList? = nil, advertised: [UInt8]) {
        let local = local ?? .offered
        guard Set(advertised).isDisjoint(with: local.versions) else { return nil }
        if let newest = advertised.max(), let localNewest = local.newest, newest > localNewest {
            self = .peerNewer(peer: "protocol " + Self.describe(advertised))
        } else {
            self = .peerOlder(peer: advertised.isEmpty ? "an unknown protocol" : "protocol " + Self.describe(advertised))
        }
    }

    /// A peer from before negotiation: `remote` is its version (0: unknown, it answered in our framing).
    public static func legacy(_ remote: UInt8, local: VersionList? = nil) -> VersionGap {
        if remote > ((local ?? .offered).newest ?? 0), remote != LainProtocol.handshakeVersion {
            return .peerNewer(peer: "protocol v\(remote)")
        }
        return .peerOlder(peer: remote == 0 ? "a protocol from before v\(LainProtocol.legacyVersions.upperBound + 1)"
                                            : "protocol v\(remote)")
    }

    private static func describe(_ versions: [UInt8]) -> String {
        let sorted = versions.sorted()
        guard let first = sorted.first, let last = sorted.last else { return "none" }
        return first == last ? "v\(last)" : "v\(first)–v\(last)"
    }
}
