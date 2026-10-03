#if os(macOS)
import CoreGraphics
import LainProtocol

/// What the host app checks itself for `HostSetup` (v4): its permissions and whether the Mac has a
/// display besides lain's. The session adds Local Network and why there's no video.
public enum HostSetupProbe {
    /// The setup with these grants, and whether a real display is attached now.
    public static func setup(screenRecording: Bool, accessibility: Bool, startAtLogin: HostSetup.State) -> HostSetup {
        HostSetup(items: [HostSetup.Item(.screenRecording, screenRecording ? .granted : .missing),
                          HostSetup.Item(.accessibility, accessibility ? .granted : .missing),
                          HostSetup.Item(.startAtLogin, startAtLogin)],
                  videoProblem: "", hasOtherDisplay: hasOtherDisplay())
    }

    /// An online display that isn't lain's virtual display: where the owner can grant permissions.
    public static func hasOtherDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayVendorNumber($0) != VirtualDisplay.vendorID }
    }
}
#endif
