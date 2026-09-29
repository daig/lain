#if os(macOS)
import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation

/// The only user of the private `CGVirtualDisplay` API (invariant 5, D17). Creates a display with the
/// iPad's native geometry (§5.1): pixel size, HiDPI, refresh modes and Display P3 primaries. The display
/// exists for as long as this object does.
public final class VirtualDisplay: @unchecked Sendable {
    public struct Spec: Sendable {
        public var name = "lain"
        public var pixelWidth = 2752
        public var pixelHeight = 2064
        /// Physical size: the 13" iPad Pro at 264 ppi.
        public var sizeMillimeters = CGSize(width: 264.8, height: 198.6)
        public var refreshRates: [Double] = [120, 60]
        public var hiDPI = true
        public init() {}
    }

    public enum Failure: Error { case create, applySettings, didNotAppear }

    public let spec: Spec
    public let displayID: CGDirectDisplayID
    private let display: CGVirtualDisplay

    public init(_ spec: Spec = Spec()) throws {
        self.spec = spec
        let d = CGVirtualDisplayDescriptor()
        d.name = spec.name
        d.maxPixelsWide = UInt32(spec.pixelWidth)
        d.maxPixelsHigh = UInt32(spec.pixelHeight)
        d.sizeInMillimeters = spec.sizeMillimeters
        d.vendorID = 0x4C41      // "LA"
        d.productID = 0x0001
        d.serialNum = 0x0001
        // Display P3: DCI-P3 primaries with a D65 white point.
        d.redPrimary = CGPoint(x: 0.680, y: 0.320)
        d.greenPrimary = CGPoint(x: 0.265, y: 0.690)
        d.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        d.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        d.queue = DispatchQueue(label: "lain.vdisplay")
        guard let display = CGVirtualDisplay(descriptor: d) else { throw Failure.create }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = spec.hiDPI ? 1 : 0
        // With hiDPI on, each mode is also offered at 2× (pixels = 2 × points).
        let w = spec.hiDPI ? spec.pixelWidth / 2 : spec.pixelWidth
        let h = spec.hiDPI ? spec.pixelHeight / 2 : spec.pixelHeight
        settings.modes = spec.refreshRates.map { CGVirtualDisplayMode(width: UInt32(w), height: UInt32(h), refreshRate: $0) }
        guard display.apply(settings) else { throw Failure.applySettings }
        self.display = display
        displayID = display.displayID
    }

    /// Waits until the window server lists the display as active.
    public func waitUntilActive(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.activeDisplays().contains(displayID) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure.didNotAppear
    }

    /// Waits until the window server no longer lists `displayID` (after the object was released).
    public static func waitUntilGone(_ displayID: CGDirectDisplayID, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, activeDisplays().contains(displayID) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    public static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids
    }

    /// Every mode the window server offers, including 2× duplicates.
    public func modes() -> [CGDisplayMode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode]) ?? []
    }

    /// Switches to the native mode: `pixelWidth` pixels wide at `refreshRate`.
    @discardableResult
    public func selectNativeMode(refreshRate: Double) -> CGDisplayMode? {
        guard let mode = modes().first(where: { $0.pixelWidth == spec.pixelWidth && $0.pixelHeight == spec.pixelHeight
            && abs($0.refreshRate - refreshRate) < 1 }) else { return nil }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        return CGCompleteDisplayConfiguration(config, .forSession) == .success ? mode : nil
    }
}
#endif
