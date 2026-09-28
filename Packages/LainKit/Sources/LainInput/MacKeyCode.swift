/// macOS virtual keycodes for HID keyboard usages (page 0x07). Filled out in step 4 (§5.5, §6.4).
public enum MacKeyCode {
    /// The macOS virtual keycode for a HID keyboard usage, or nil if it has none.
    public static func from(hidUsage: UInt16) -> UInt16? {
        switch hidUsage {
        case 0x04: 0x00   // A → kVK_ANSI_A
        default: nil
        }
    }
}
