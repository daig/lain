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
        /// Panel pixels per point (`HostPreferences.displayScale`): 2 is the iPad's own. Another scale makes a
        /// desktop of `pointWidth`×`pointHeight` points, rendered at 2× (`backingWidth`), and capture scales it
        /// to the panel (or to the backing size, when that is smaller).
        public var scale = 2.0
        /// Tells displays of different geometry apart for macOS, which remembers a display's arrangement and
        /// mode by its vendor, product and serial numbers: 1 is the 13-inch iPad Pro's, as always.
        public var serial: UInt32 = 1
        public init() {}

        /// The display a client asks for (its `Hello`: pixels, long side first). The 13-inch iPad Pro's own is
        /// the default spec, untouched; another client (an iPhone Duo, which asks for its inner display)
        /// gets a display of that shape, with a serial number of its own so that macOS
        /// arranges it separately. A size that makes no display (nothing, or absurd) falls back to the iPad's.
        public func sized(pixelWidth w: Int, pixelHeight h: Int) -> Spec {
            guard (w, h) != (pixelWidth, pixelHeight), (640...4096).contains(w), (480...4096).contains(h), w >= h else { return self }
            var s = self
            s.pixelWidth = w
            s.pixelHeight = h
            // No client says how large its panel is: the iPad's pixel density stands in.
            s.sizeMillimeters = CGSize(width: Double(w) / 264 * 25.4, height: Double(h) / 264 * 25.4)
            s.serial = UInt32(w) << 16 | UInt32(h)
            return s
        }

        /// The desktop's size in points (even, so every size derived from it is too).
        public var pointWidth: Int { Self.even(Double(pixelWidth) / scale) }
        public var pointHeight: Int { Self.even(Double(pixelHeight) / scale) }
        /// The display's own pixels: twice the points with HiDPI.
        public var backingWidth: Int { hiDPI ? 2 * pointWidth : pointWidth }
        public var backingHeight: Int { hiDPI ? 2 * pointHeight : pointHeight }
        /// What is captured and encoded: the backing size, but never more than the panel.
        public var streamWidth: Int { min(backingWidth, pixelWidth) }
        public var streamHeight: Int { min(backingHeight, pixelHeight) }
        /// Tells displays of different geometry apart (`DisplayKeeper`).
        public var keeperKey: String { "\(pixelWidth)x\(pixelHeight)@\(pointWidth)x\(pointHeight)" }

        /// The largest backing store (twice the points, in pixels) a display is made with, on either side.
        /// Scale 1.5 on the 13-inch iPad Pro's panel (3668 px) has been in use since the scale setting
        /// arrived; 3840 leaves the Duo's inner display (3804 px at 1.5) the same choices. Not measured beyond.
        public static let maxBackingPixels = 3840
        /// The scales offered: every quarter from 1 to 3 pixels per point.
        public static let scaleSteps: [Double] = Array(stride(from: 1.0, through: 3.0, by: 0.25))

        /// The scales a display of this many pixels can be made at (v7 `HelloAck.displayScales`), ascending:
        /// the steps whose backing store fits `maxBackingPixels`.
        public static func scales(pixelWidth: Int, pixelHeight: Int) -> [Double] {
            var s = Spec().sized(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            return scaleSteps.filter { step in
                s.scale = step
                return max(s.backingWidth, s.backingHeight) <= maxBackingPixels
            }
        }

        static func even(_ x: Double) -> Int { max(2, Int((x / 2).rounded()) * 2) }
    }

    public enum Failure: Error { case create, applySettings, didNotAppear }

    /// "LA": tells lain's display apart from real ones (`HostSetupProbe.hasOtherDisplay`).
    public static let vendorID: UInt32 = 0x4C41

    public let spec: Spec
    public let displayID: CGDirectDisplayID
    private let display: CGVirtualDisplay

    public init(_ spec: Spec = Spec()) throws {
        self.spec = spec
        let d = CGVirtualDisplayDescriptor()
        d.name = spec.name
        d.maxPixelsWide = UInt32(spec.backingWidth)
        d.maxPixelsHigh = UInt32(spec.backingHeight)
        d.sizeInMillimeters = spec.sizeMillimeters
        d.vendorID = Self.vendorID
        d.productID = 0x0001
        d.serialNum = spec.serial
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
        let w = spec.pointWidth, h = spec.pointHeight
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

    /// Waits until the window server no longer lists `displayID` (after the object was released), for at
    /// most `timeout`, checking every 20 ms (`isListed`: tests stand in for the window server). It runs its
    /// course even on a cancelled task (a detach during a session's video start): the next lain display
    /// may only be created once this one is gone (one at a time, §5.7), so the wait must neither end early
    /// nor, as a cancelled `Task.sleep` would make it, spin on the window server.
    public static func waitUntilGone(_ displayID: CGDirectDisplayID, timeout: TimeInterval = 2,
                                     isListed: (CGDirectDisplayID) -> Bool = { activeDisplays().contains($0) }) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, isListed(displayID) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { c.resume() }
            }
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

    /// Whether the window server reports the spec's mode as current.
    public var isInStreamingMode: Bool {
        guard let m = CGDisplayCopyDisplayMode(displayID) else { return false }
        return m.pixelWidth == spec.backingWidth && m.pixelHeight == spec.backingHeight
    }

    /// Switches to the spec's mode: `pointWidth` points, `backingWidth` pixels wide, at `refreshRate`
    /// (at scale 2, the panel's native mode).
    @discardableResult
    public func selectNativeMode(refreshRate: Double) -> CGDisplayMode? {
        guard let mode = modes().first(where: { $0.pixelWidth == spec.backingWidth && $0.pixelHeight == spec.backingHeight
            && abs($0.refreshRate - refreshRate) < 1 }) else { return nil }
        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)
        CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        return CGCompleteDisplayConfiguration(config, .forSession) == .success ? mode : nil
    }
}
#endif
