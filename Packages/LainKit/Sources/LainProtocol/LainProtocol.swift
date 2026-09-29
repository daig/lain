/// Wire constants shared by host and client (ARCHITECTURE.md §7).
public enum LainProtocol {
    /// Header magic, written little-endian (§7.4).
    public static let magic: UInt16 = 0x4C41
    /// Major protocol version; a mismatch ends the session with `Error` (§7.5). Any payload change is
    /// a new major version: decoders reject trailing bytes and unknown types and codes. v2 (M6a):
    /// `HelloAck` carries the host id and name, `Pair` the host id; `Error` gains `busy`.
    public static let majorVersion: UInt8 = 2
    /// Every message starts with a fixed 24-byte header (§7.4).
    public static let headerSize = 24
    /// The client's loopback listener port; the Mac dials it through usbmuxd (§7.2).
    public static let usbPort: UInt16 = 47800
    /// The Bonjour service the host advertises for Wi-Fi, with TXT `v` (major version) and `id` (host
    /// id) (§7.7). The client's `NSBonjourServices` must list it.
    public static let bonjourServiceType = "_lain._tcp"
}
