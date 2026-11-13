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

/// The scale a session's display is made at (v7): the one the client asked for (`Hello.desiredScale`), or the
/// host's own for a client that asked for none, brought to the nearest the host can make.
public struct DisplayScaleChoice: Sendable, Equatable {
    /// Pixels per point.
    public var applied: Double
    /// What the host can make for this client, ascending; empty: only `applied`.
    public var supported: [Double]
    /// The client asked for a scale (else `applied` is the host's own).
    public var askedFor: Bool

    public init(applied: Double, supported: [Double], askedFor: Bool = false) {
        self.applied = applied
        self.supported = supported
        self.askedFor = askedFor
    }

    /// `requested`: hundredths (0: none). The nearest supported scale to it (on a tie, the larger: a little
    /// more room rather than less), or to `own` when none was asked for.
    public static func choose(requested: UInt16, supported: [Double], own: Double) -> DisplayScaleChoice {
        let wanted = requested > 0 ? Double(requested) / 100 : own
        guard let nearest = supported.min(by: { a, b in
            let da = abs(a - wanted), db = abs(b - wanted)
            return da != db ? da < db : a > b   // the larger first on a tie
        }) else { return DisplayScaleChoice(applied: own, supported: [], askedFor: requested > 0) }
        return DisplayScaleChoice(applied: nearest, supported: supported, askedFor: requested > 0)
    }

    /// Hundredths, for `HelloAck`.
    public var wireApplied: UInt16 { UInt16((applied * 100).rounded()) }
    public var wireSupported: [UInt16] { supported.map { UInt16(($0 * 100).rounded()) } }
}

/// Creates and removes the streamed display. Injected so tests never create a real one.
public protocol StreamedDisplayProvider: Sendable {
    /// Creates the display and waits until it is active in its streaming mode.
    func create() async throws -> StreamedDisplay
    /// The same, for a client that asks for this many pixels (its `Hello`): the display takes that shape. By
    /// default the size is ignored.
    func create(pixelWidth: Int, pixelHeight: Int) async throws -> StreamedDisplay
    /// The same at `scale` pixels per point (one of `scales(pixelWidth:pixelHeight:)`). By default the scale
    /// is ignored.
    func create(pixelWidth: Int, pixelHeight: Int, scale: Double) async throws -> StreamedDisplay
    /// The scales a display for a client of this many pixels can be made at, ascending (v7
    /// `HelloAck.displayScales`); empty: only `ownScale`, by default.
    func scales(pixelWidth: Int, pixelHeight: Int) -> [Double]
    /// The scale for a client that asks for none (an older one): the owner's (`HostPreferences.displayScale`).
    var ownScale: Double { get }
    /// The display's current global point bounds (the owner may rearrange it in System Settings at any
    /// time), or nil when it no longer exists.
    func currentBounds() -> CGRect?
    /// Removes the display. Idempotent.
    func destroy()
    /// Waits (bounded) until the display `destroy()` removed has left the active display list: the
    /// window server removes it asynchronously, and the next session's display shares its identity.
    /// It runs its course even on a cancelled task: a failed start waits here on the session's own task,
    /// which a detach cancels.
    func waitUntilRemoved() async
    /// The session using the display ended (its link went away, or a takeover): the display is kept for
    /// the next session if the provider has a keeper (`DisplayKeeper`), else removed and waited out.
    func retire() async
}

extension StreamedDisplayProvider {
    public func create(pixelWidth: Int, pixelHeight: Int) async throws -> StreamedDisplay { try await create() }
    public func create(pixelWidth: Int, pixelHeight: Int, scale: Double) async throws -> StreamedDisplay {
        try await create(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }
    public func scales(pixelWidth: Int, pixelHeight: Int) -> [Double] { [] }
    public var ownScale: Double { HostPreferences.defaultScale }

    public func waitUntilRemoved() async {}

    /// The default: removed, as `destroy()`.
    public func retire() async {
        destroy()
        await waitUntilRemoved()
    }
}

#if os(macOS)
/// The real provider: a `VirtualDisplay` (the only user of the private API, invariant 5) in the 13" iPad
/// Pro's native mode, 2752×2064 px at 2× and 120 Hz (or the spec's scale, `HostPreferences.displayScale`).
/// **Never sets an origin** in Extend mode: macOS remembers the display's arrangement by its persistent
/// UUID, and the owner arranges it once in System Settings › Displays (§5.1, decided 2026-09-28).
///
/// With a `keeper`, a session's end hands the display over (`retire`), and the next session of the same
/// geometry takes it back (`create`) instead of making a new one (rust/HOST-PARITY.md §1).
public final class VirtualStreamedDisplayProvider: StreamedDisplayProvider {
    public let spec: VirtualDisplay.Spec
    public let refreshRate: Int
    public let keeper: DisplayKeeper?
    private let display = Mutex<VirtualDisplay?>(nil)
    /// The display `destroy()` last released, until it has left the active list.
    private let removed = Mutex<CGDirectDisplayID?>(nil)

    public init(spec: VirtualDisplay.Spec = VirtualDisplay.Spec(), refreshRate: Int = 120, keeper: DisplayKeeper? = nil) {
        self.spec = spec
        self.refreshRate = refreshRate
        self.keeper = keeper
    }

    public func create() async throws -> StreamedDisplay { try await create(spec) }

    public func create(pixelWidth: Int, pixelHeight: Int) async throws -> StreamedDisplay {
        try await create(spec.sized(pixelWidth: pixelWidth, pixelHeight: pixelHeight))
    }

    public func create(pixelWidth: Int, pixelHeight: Int, scale: Double) async throws -> StreamedDisplay {
        var s = spec.sized(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        s.scale = scale
        return try await create(s)
    }

    public func scales(pixelWidth: Int, pixelHeight: Int) -> [Double] {
        VirtualDisplay.Spec.scales(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    public var ownScale: Double { spec.scale }

    private func create(_ spec: VirtualDisplay.Spec) async throws -> StreamedDisplay {
        let log = Telemetry.logger("vdisplay")
        let vd: VirtualDisplay
        if let kept = await keeper?.take(key: spec.keeperKey) as? KeptVirtualDisplay, let reused = kept.takeDisplay() {
            vd = reused
            display.withLock { $0 = vd }
            log.notice("streaming the kept display \(vd.displayID)")
        } else {
            // Created on the main thread, as the benches (and DeskPad) do.
            vd = try await MainActor.run { try VirtualDisplay(spec) }
            display.withLock { $0 = vd }
        }
        do {
            try await vd.waitUntilActive()
            if !vd.isInStreamingMode, vd.selectNativeMode(refreshRate: Double(refreshRate)) == nil {
                log.error("the \(spec.pointWidth)×\(spec.pointHeight) pt (\(spec.backingWidth)×\(spec.backingHeight) px) @\(self.refreshRate) Hz mode isn't offered; streaming the current mode")
            }
            // The mode switch lands asynchronously; wait (bounded) until the window server reports it.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, !vd.isInStreamingMode {
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            destroy()
            throw error
        }
        let mode = CGDisplayCopyDisplayMode(vd.displayID)
        let inSpec = vd.isInStreamingMode
        // In the spec's mode, capture scales the backing store to the stream size; otherwise the current mode's own pixels.
        let width = inSpec ? spec.streamWidth : (mode?.pixelWidth ?? spec.streamWidth)
        let height = inSpec ? spec.streamHeight : (mode?.pixelHeight ?? spec.streamHeight)
        let result = StreamedDisplay(displayID: vd.displayID, pixelWidth: width, pixelHeight: height, bounds: CGDisplayBounds(vd.displayID),
                                     refreshRate: mode.map { Int($0.refreshRate.rounded()) }.flatMap { $0 > 0 ? $0 : nil } ?? refreshRate)
        log.notice("streamed display \(result.displayID): \(result.pixelWidth)×\(result.pixelHeight) px at \(result.refreshRate) Hz, bounds \(String(describing: result.bounds))")
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

    public func retire() async {
        guard let removed = handOver() else { return }
        await VirtualDisplay.waitUntilGone(removed)
    }

    /// Gives the display to the keeper, or releases it (synchronously, so no reference outlives this call):
    /// the id to wait out when it was released.
    private func handOver() -> CGDirectDisplayID? {
        guard let vd = display.withLock({ d -> VirtualDisplay? in defer { d = nil }; return d }) else { return nil }
        if let keeper, keeper.keep(KeptVirtualDisplay(vd), key: vd.spec.keeperKey) { return nil }   // its own shape's
        return vd.displayID
    }
}

/// A `VirtualDisplay` held by the `DisplayKeeper` between sessions.
final class KeptVirtualDisplay: KeepableDisplay {
    private let display: Mutex<VirtualDisplay?>

    init(_ display: VirtualDisplay) { self.display = Mutex(display) }

    var isUsable: Bool {
        guard let id = display.withLock({ $0?.displayID }) else { return false }
        return VirtualDisplay.activeDisplays().contains(id)
    }

    /// Hands the display to a new session (once).
    func takeDisplay() -> VirtualDisplay? { display.withLock { d in defer { d = nil }; return d } }

    func remove() async {
        guard let id = release() else { return }
        await VirtualDisplay.waitUntilGone(id)
    }

    /// Drops the last reference (removing the display, S2) before returning its id.
    private func release() -> CGDirectDisplayID? { takeDisplay()?.displayID }
}
#endif
