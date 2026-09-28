#if os(macOS)
/// Client for `/var/run/usbmuxd` (§7.2). Implemented in M1 (step 5).
public enum USBMux {
    public static let defaultSocketPath = "/var/run/usbmuxd"
}
#endif
