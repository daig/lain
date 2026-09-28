/// Wire constants shared by host and client (ARCHITECTURE.md §7).
public enum LainProtocol {
    /// Header magic, written little-endian (§7.4).
    public static let magic: UInt16 = 0x4C41
    /// Major protocol version; a mismatch ends the session with `Error` (§7.5).
    public static let majorVersion: UInt8 = 1
    /// Every message starts with a fixed 24-byte header (§7.4).
    public static let headerSize = 24
    /// The client's loopback listener port; the Mac dials it through usbmuxd (§7.2).
    public static let usbPort: UInt16 = 47800
}
