import CoreGraphics
import Foundation
import LainTelemetry
import Synchronization

/// The display the host streams (§5.1): in M3, the iPad-geometry virtual display in Extend mode.
public struct StreamedDisplay: Sendable, Equatable {
    public var displayID: UInt32
    /// The capture and encode size: the display's current mode in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Global point coordinates (top-left origin, main display at 0,0), as `CGDisplayBounds` reports them.
    public var bounds: CGRect
    public var refreshRate: Int

    public init(displayID: UInt32, pixelWidth: Int, pixelHeight: Int, bounds: CGRect, refreshRate: Int) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bounds = bounds
        self.refreshRate = refreshRate
    }
}

/// Creates and removes the streamed display. Injected so tests never create a real one.
public protocol StreamedDisplayProvider: Sendable {
    /// Creates the display and waits until it is active in its streaming mode.
    func create() async throws -> StreamedDisplay
    /// The display's current global point bounds (the owner may rearrange it in System Settings at any
    /// time), or nil when it no longer exists.
    func currentBounds() -> CGRect?
    /// Removes the display. Idempotent.
    func destroy()
    /// Waits (bounded) until the display `destroy()` removed has left the active display list: the
    /// window server removes it asynchronously, and the next session's display shares its identity.
    func waitUntilRemoved() async
}

extension StreamedDisplayProvider {
    public func waitUntilRemoved() async {}
}

#if os(macOS)
/// The real provider: a `VirtualDisplay` (the only user of the private API, invariant 5) in the 13" iPad
/// Pro's native mode, 2752×2064 px at 2× and 120 Hz. **Never sets an origin** in Extend mode: macOS
/// remembers the display's arrangement by its persistent UUID, and the owner arranges it once in System
/// Settings › Displays (§5.1, decided 2026-09-28).
public final class VirtualStreamedDisplayProvider: StreamedDisplayProvider {
    public let spec: VirtualDisplay.Spec
    public let refreshRate: Int
    private let display = Mutex<VirtualDisplay?>(nil)
    /// The display `destroy()` last released, until it has left the active list.
    private let removed = Mutex<CGDirectDisplayID?>(nil)

    public init(spec: VirtualDisplay.Spec = VirtualDisplay.Spec(), refreshRate: Int = 120) {
        self.spec = spec
        self.refreshRate = refreshRate
    }

    public func create() async throws -> StreamedDisplay {
        let spec = self.spec
        // Created on the main thread, as the benches (and DeskPad) do.
        let vd = try await MainActor.run { try VirtualDisplay(spec) }
        display.withLock { $0 = vd }
        do {
            try await vd.waitUntilActive()
            if vd.selectNativeMode(refreshRate: Double(refreshRate)) == nil {
                Telemetry.logger("vdisplay").error("native \(spec.pixelWidth)×\(spec.pixelHeight) @\(self.refreshRate) Hz mode not offered; streaming the current mode")
            }
            // The mode switch lands asynchronously; wait (bounded) until the window server reports it.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                if let m = CGDisplayCopyDisplayMode(vd.displayID), m.pixelWidth == spec.pixelWidth, m.pixelHeight == spec.pixelHeight {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            destroy()
            throw error
        }
        let mode = CGDisplayCopyDisplayMode(vd.displayID)
        let result = StreamedDisplay(displayID: vd.displayID, pixelWidth: mode?.pixelWidth ?? spec.pixelWidth,
                                     pixelHeight: mode?.pixelHeight ?? spec.pixelHeight, bounds: CGDisplayBounds(vd.displayID),
                                     refreshRate: mode.map { Int($0.refreshRate.rounded()) }.flatMap { $0 > 0 ? $0 : nil } ?? refreshRate)
        Telemetry.logger("vdisplay").notice("streamed display \(result.displayID): \(result.pixelWidth)×\(result.pixelHeight) px at \(result.refreshRate) Hz, bounds \(String(describing: result.bounds))")
        return result
    }

    public func currentBounds() -> CGRect? {
        guard let id = display.withLock({ $0?.displayID }), VirtualDisplay.activeDisplays().contains(id) else { return nil }
        return CGDisplayBounds(id)
    }

    public func destroy() {
        // Releasing the object removes the display (S2).
        let vd = display.withLock { d -> VirtualDisplay? in
            defer { d = nil }
            return d
        }
        if let vd { removed.withLock { $0 = vd.displayID } }
        withExtendedLifetime(vd) {}
    }

    public func waitUntilRemoved() async {
        guard let id = removed.withLock({ $0 }) else { return }
        await VirtualDisplay.waitUntilGone(id)
        removed.withLock { if $0 == id { $0 = nil } }
    }
}
#endif
