/// Wire constants shared by host and client (ARCHITECTURE.md §7, PROTOCOL-VERSIONING.md).
public enum LainProtocol {
    /// Header magic, written little-endian (§7.4).
    public static let magic: UInt16 = 0x4C41
    /// The header version of handshake frames: the frozen layer that negotiates the session's version
    /// (PROTOCOL-VERSIONING §3.1). Higher than every legacy version, so a legacy peer's own mismatch
    /// message says to update itself.
    public static let handshakeVersion: UInt8 = 0xFF
    /// Every protocol version this build implements, oldest first: the support window (PROTOCOL-VERSIONING
    /// §2). Policy until a public release: the newest and the previous version. v3: negotiation (the last
    /// breaking change); v4: `HostSetup`.
    /// Never a default argument value in a public API (take `nil` and read it in the body): a default is
    /// compiled into the caller's module, and an incremental build after a change can keep the old value
    /// there (D30). The same goes for `usbPort`.
    public static let supportedVersions: [UInt8] = [3, 4]
    /// The lockstep major versions from before negotiation. A peer framing in one of them runs an older lain.
    public static let legacyVersions: ClosedRange<UInt8> = 1...2
    /// The newest version this build implements.
    public static var newestVersion: UInt8 { supportedVersions[supportedVersions.count - 1] }
    /// Every message starts with a fixed 24-byte header (§7.4).
    public static let headerSize = 24
    /// The client's loopback listener port; the Mac dials it through usbmuxd (§7.2). Never a default
    /// argument value (see `supportedVersions`).
    public static let usbPort: UInt16 = 47800
    /// The Bonjour service the host advertises for Wi-Fi, with TXT `v` (the newest version), `vs` (every
    /// supported version) and `id` (host id) (§7.7). The client's `NSBonjourServices` must list it.
    public static let bonjourServiceType = "_lain._tcp"
    /// The user default that caps the versions a build offers (PROTOCOL-VERSIONING §3.2): a launch
    /// argument (`-lainProtocolMax 3`) or `defaults write <bundle id> lainProtocolMax 3`. Only narrows.
    public static let versionCapKey = "lainProtocolMax"
}
