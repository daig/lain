#if os(macOS)
import ColorSync
import CoreGraphics
import Foundation

/// `LainHost --bench vdisplay-identity`: does macOS remember the virtual display's arrangement across
/// sessions (so the owner can arrange it in System Settings instead of lain doing it)? Creates the
/// display, reads its persistent UUID, saves an origin below the main display permanently (what
/// dragging it in Settings does), destroys and recreates it, and checks the UUID and origin.
public enum DisplayIdentityBench {
    static func uuid(_ id: CGDirectDisplayID) -> String {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "?" }
        return CFUUIDCreateString(nil, u) as String
    }

    static func layout() -> String {
        VirtualDisplay.activeDisplays().map { id in
            let b = CGDisplayBounds(id)
            return "\(id)\(CGDisplayIsMain(id) != 0 ? "*" : "")\(CGDisplayVendorNumber(id) == 0x4C41 ? "(lain)" : "")@(\(Int(b.origin.x)),\(Int(b.origin.y))) \(Int(b.width))×\(Int(b.height))"
        }.joined(separator: ", ")
    }

    public static func run() async -> Int32 {
        print("before: \(layout())")
        let main = CGDisplayBounds(CGMainDisplayID())
        let target = CGPoint(x: main.origin.x, y: main.maxY)       // directly below the main display

        guard let first = try? VirtualDisplay() else { print("create failed"); return 1 }
        try? await first.waitUntilActive()
        first.selectNativeMode(refreshRate: 120)
        try? await Task.sleep(for: .seconds(1))
        let uuid1 = uuid(first.displayID)
        print("created #1: id \(first.displayID), uuid \(uuid1), at \(CGDisplayBounds(first.displayID).origin); layout: \(layout())")

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayOrigin(config, first.displayID, Int32(target.x), Int32(target.y))
        let err = CGCompleteDisplayConfiguration(config, .permanently)
        try? await Task.sleep(for: .seconds(2))
        print("saved origin \(target) permanently (result \(err.rawValue)); layout: \(layout())")
        let saved = CGDisplayBounds(first.displayID).origin

        withExtendedLifetime(first) {}
        _ = consume first
        try? await Task.sleep(for: .seconds(3))
        print("removed #1; layout: \(layout())")

        guard let second = try? VirtualDisplay() else { print("re-create failed"); return 1 }
        try? await second.waitUntilActive()
        second.selectNativeMode(refreshRate: 120)
        try? await Task.sleep(for: .seconds(2))
        let uuid2 = uuid(second.displayID)
        let origin2 = CGDisplayBounds(second.displayID).origin
        print("created #2: id \(second.displayID), uuid \(uuid2), at \(origin2); layout: \(layout())")
        let sameUUID = uuid1 == uuid2
        let restored = abs(origin2.x - saved.x) < 1 && abs(origin2.y - saved.y) < 1
        print("RESULT: same UUID \(sameUUID); arrangement restored \(restored) (saved \(saved), got \(origin2))")
        withExtendedLifetime(second) {}
        _ = consume second
        try? await Task.sleep(for: .seconds(2))
        print("after: \(layout())")
        return sameUUID && restored ? 0 : 1
    }
}
#endif
