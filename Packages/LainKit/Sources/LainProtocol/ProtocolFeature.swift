/// Behavior that differs between protocol versions (PROTOCOL-VERSIONING §3.4). Code asks
/// `ProtocolFeature.x.isSupported(at: link.version)` (or `Link.supports`), never compares version
/// numbers. A feature whose `until` is at or below the oldest supported version is dead compatibility
/// code: a test fails until it's deleted.
public enum ProtocolFeature: CaseIterable, Sendable {
    /// v4: the host sends `HostSetup` after `HelloAck` and whenever its setup changes.
    case hostSetup
    /// v5: the iPad asks for `HostStats` (`StatsRequest`) and the host sends them.
    case hostStats
    /// v6: the iPad sends text for the host to type (`TextInput`): dictation and the on-screen keyboard.
    case textInput
    /// v6: the host sends its sound (`AudioConfig`, `AudioPacket`) and the iPad plays it.
    case audio
    /// v7: the client asks for its display's scale (`Hello.desiredScale`) and the host says which it applied
    /// and which it can (`HelloAck.displayScale`, `displayScales`).
    case displayScale

    /// The first version with the feature.
    public var since: UInt8 {
        switch self {
        case .hostSetup: 4
        case .hostStats: 5
        case .textInput, .audio: 6
        case .displayScale: 7
        }
    }

    /// The first version without it, when a newer behavior replaced it; nil while current.
    public var until: UInt8? {
        switch self {
        case .hostSetup, .hostStats, .textInput, .audio, .displayScale: nil
        }
    }

    public func isSupported(at version: UInt8) -> Bool { version >= since && until.map { version < $0 } ?? true }

    /// What updating the older side adds, for the version-skew line (PROTOCOL-VERSIONING §8).
    public var summary: String {
        switch self {
        case .hostSetup: "setup status on the iPad"
        case .hostStats: "the Mac's video stats on the iPad"
        case .textInput: "dictation and the on-screen keyboard"
        case .audio: "the computer's sound on the iPad"
        case .displayScale: "choosing the display's scale on the iPad"
        }
    }

    /// What a session at `version` misses that `newest` has (nil: the newest this process offers,
    /// `VersionList.offered`, which a `lainProtocolMax` cap lowers).
    public static func missing(at version: UInt8, upTo newest: UInt8? = nil) -> [ProtocolFeature] {
        let newest = newest ?? VersionList.offered.newest ?? LainProtocol.newestVersion
        return allCases.filter { !$0.isSupported(at: version) && $0.isSupported(at: newest) }
    }
}
