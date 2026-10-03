/// Behavior that differs between protocol versions (PROTOCOL-VERSIONING §3.4). Code asks
/// `ProtocolFeature.x.isSupported(at: link.version)` (or `Link.supports`), never compares version
/// numbers. A feature whose `until` is at or below the oldest supported version is dead compatibility
/// code: a test fails until it's deleted.
public enum ProtocolFeature: CaseIterable, Sendable {
    /// v4: the host sends `HostSetup` after `HelloAck` and whenever its setup changes.
    case hostSetup

    /// The first version with the feature.
    public var since: UInt8 {
        switch self {
        case .hostSetup: 4
        }
    }

    /// The first version without it, when a newer behavior replaced it; nil while current.
    public var until: UInt8? {
        switch self {
        case .hostSetup: nil
        }
    }

    public func isSupported(at version: UInt8) -> Bool { version >= since && until.map { version < $0 } ?? true }

    /// What updating the older side adds, for the version-skew line (PROTOCOL-VERSIONING §8).
    public var summary: String {
        switch self {
        case .hostSetup: "setup status on the iPad"
        }
    }

    /// What a session at `version` misses that `newest` has (nil: the newest this process offers,
    /// `VersionList.offered`, which a `lainProtocolMax` cap lowers).
    public static func missing(at version: UInt8, upTo newest: UInt8? = nil) -> [ProtocolFeature] {
        let newest = newest ?? VersionList.offered.newest ?? LainProtocol.newestVersion
        return allCases.filter { !$0.isSupported(at: version) && $0.isSupported(at: newest) }
    }
}
