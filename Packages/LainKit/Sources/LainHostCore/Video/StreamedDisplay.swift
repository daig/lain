import CoreGraphics
import Foundation
import LainProtocol
import LainTelemetry
import os
import Synchronization

/// The display the host streams (§5.1): a virtual display in Extend or Mirror (`primary`) mode, or the host's
/// own configured physical display (`captureExisting`).
public struct StreamedDisplay: Sendable, Equatable {
    public var displayID: UInt32
    /// The capture and encode size: the display's current mode in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Global point coordinates (top-left origin, main display at 0,0), as `CGDisplayBounds` reports them.
    public var bounds: CGRect
    public var refreshRate: Int
    /// How this display is placed on the host (v8 `HelloAck.displayMode`).
    public var displayMode: DisplayMode

    public init(displayID: UInt32, pixelWidth: Int, pixelHeight: Int, bounds: CGRect, refreshRate: Int,
                displayMode: DisplayMode = .extend) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bounds = bounds
        self.refreshRate = refreshRate
        self.displayMode = displayMode
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
    /// The same with a display mode (v8: `.extend`, `.primary` to mirror onto lain's display, or
    /// `.captureExisting` to mirror the host's own display). By default the mode is ignored.
    func create(pixelWidth: Int, pixelHeight: Int, scale: Double, mode: DisplayMode) async throws -> StreamedDisplay
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
    public func create(pixelWidth: Int, pixelHeight: Int, scale: Double, mode: DisplayMode) async throws -> StreamedDisplay {
        try await create(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale)
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
    private enum Active {
        case virtual(VirtualDisplay, mode: DisplayMode)
        case existing(CGDirectDisplayID)
    }
    private let active = Mutex<Active?>(nil)
    /// The virtual display `destroy()` last released, until it has left the active list.
    private let removed = Mutex<CGDirectDisplayID?>(nil)

    public init(spec: VirtualDisplay.Spec = VirtualDisplay.Spec(), refreshRate: Int = 120, keeper: DisplayKeeper? = nil) {
        self.spec = spec
        self.refreshRate = refreshRate
        self.keeper = keeper
    }

    public func create() async throws -> StreamedDisplay { try await create(spec, mode: .extend) }

    public func create(pixelWidth: Int, pixelHeight: Int) async throws -> StreamedDisplay {
        try await create(spec.sized(pixelWidth: pixelWidth, pixelHeight: pixelHeight), mode: .extend)
    }

    public func create(pixelWidth: Int, pixelHeight: Int, scale: Double) async throws -> StreamedDisplay {
        try await create(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, mode: .extend)
    }

    public func create(pixelWidth: Int, pixelHeight: Int, scale: Double, mode: DisplayMode) async throws -> StreamedDisplay {
        var s = spec.sized(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        s.scale = scale
        if mode == .captureExisting {
            if let existing = await captureExistingDisplay() { return existing }
            // Headless Mac with no physical monitor: fall back to creating lain's virtual display.
            return try await create(s, mode: .extend)
        }
        return try await create(s, mode: mode)
    }

    public func scales(pixelWidth: Int, pixelHeight: Int) -> [Double] {
        VirtualDisplay.Spec.scales(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    public var ownScale: Double { spec.scale }

    private static func keeperKey(for spec: VirtualDisplay.Spec, mode: DisplayMode) -> String {
        "\(spec.keeperKey):\(mode.rawValue)"
    }

    /// Captures the Mac's own existing main physical display (after clearing any kept virtual display and
    /// restoring host mirroring first). Returns nil on a headless Mac with no physical display.
    private func captureExistingDisplay() async -> StreamedDisplay? {
        let log = Telemetry.logger("vdisplay")
        await keeper?.clear()
        _ = VirtualDisplay.restoreHostDisplays()
        let physical = VirtualDisplay.activePhysicalDisplays()
        guard let target = physical.first(where: { CGDisplayIsMain($0) != 0 }) ?? physical.first else {
            log.notice("captureExisting requested, but no physical display is active; falling back to virtual display")
            return nil
        }
        let bounds = CGDisplayBounds(target)
        let mode = CGDisplayCopyDisplayMode(target)
        let rawW = mode?.pixelWidth ?? Int((bounds.width * 2).rounded())
        let rawH = mode?.pixelHeight ?? Int((bounds.height * 2).rounded())
        let (width, height) = VirtualDisplay.cappedCaptureSize(pixelWidth: rawW, pixelHeight: rawH)
        let hz = mode.map { Int($0.refreshRate.rounded()) }.flatMap { $0 > 0 ? $0 : nil } ?? 60
        active.withLock { $0 = .existing(target) }
        let result = StreamedDisplay(displayID: target, pixelWidth: width, pixelHeight: height, bounds: bounds,
                                     refreshRate: hz, displayMode: .captureExisting)
        log.notice("streaming existing host display \(result.displayID): \(result.pixelWidth)×\(result.pixelHeight) px at \(result.refreshRate) Hz, bounds \(String(describing: result.bounds))")
        return result
    }

    private func create(_ spec: VirtualDisplay.Spec, mode: DisplayMode) async throws -> StreamedDisplay {
        let log = Telemetry.logger("vdisplay")
        let key = Self.keeperKey(for: spec, mode: mode)
        let vd: VirtualDisplay
        var reused = false
        if let kept = await keeper?.take(key: key) as? KeptVirtualDisplay, let taken = kept.takeDisplay() {
            vd = taken
            reused = true
            active.withLock { $0 = .virtual(vd, mode: mode) }
            log.notice("streaming the kept display \(vd.displayID) (mode \(mode.rawValue))")
        } else {
            // Snapshot physical displays before creating ours so we know what to mirror onto it.
            vd = try await MainActor.run { try VirtualDisplay(spec) }
            active.withLock { $0 = .virtual(vd, mode: mode) }
        }
        do {
            try await vd.waitUntilActive()
            try await ensureStreamingMode(vd, spec: spec, log: log)
            if mode == .primary {
                let physical = VirtualDisplay.activePhysicalDisplays()
                if !physical.isEmpty {
                    if VirtualDisplay.mirror(physical, onto: vd.displayID) {
                        log.notice("mirrored \(physical.count) host display(s) onto lain display \(vd.displayID)")
                        // Wait briefly for the mirror set to settle, then verify our mode stayed intact.
                        let deadline = Date().addingTimeInterval(1)
                        while Date() < deadline, CGDisplayMirrorsDisplay(physical[0]) != vd.displayID {
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        try await ensureStreamingMode(vd, spec: spec, log: log)
                    } else {
                        log.error("failed to mirror host display(s) onto lain display \(vd.displayID)")
                    }
                } else if !reused {
                    log.notice("primary/mirror requested on headless host: no physical display to mirror")
                }
            }
        } catch {
            destroy()
            throw error
        }
        let currentMode = CGDisplayCopyDisplayMode(vd.displayID)
        let inSpec = vd.isInStreamingMode
        // In the spec's mode, capture scales the backing store to the stream size; otherwise the current mode's own pixels.
        let width = inSpec ? spec.streamWidth : (currentMode?.pixelWidth ?? spec.streamWidth)
        let height = inSpec ? spec.streamHeight : (currentMode?.pixelHeight ?? spec.streamHeight)
        let result = StreamedDisplay(displayID: vd.displayID, pixelWidth: width, pixelHeight: height, bounds: CGDisplayBounds(vd.displayID),
                                     refreshRate: currentMode.map { Int($0.refreshRate.rounded()) }.flatMap { $0 > 0 ? $0 : nil } ?? refreshRate,
                                     displayMode: mode)
        log.notice("streamed display \(result.displayID): \(result.pixelWidth)×\(result.pixelHeight) px at \(result.refreshRate) Hz, mode \(mode.rawValue), bounds \(String(describing: result.bounds))")
        return result
    }

    private func ensureStreamingMode(_ vd: VirtualDisplay, spec: VirtualDisplay.Spec, log: Logger) async throws {
        if !vd.isInStreamingMode, vd.selectNativeMode(refreshRate: Double(refreshRate)) == nil {
            log.error("the \(spec.pointWidth)×\(spec.pointHeight) pt (\(spec.backingWidth)×\(spec.backingHeight) px) @\(self.refreshRate) Hz mode isn't offered; streaming the current mode")
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !vd.isInStreamingMode {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    public func currentBounds() -> CGRect? {
        let id: CGDirectDisplayID? = active.withLock {
            switch $0 {
            case .virtual(let vd, _): vd.displayID
            case .existing(let id): id
            case nil: nil
            }
        }
        guard let id, VirtualDisplay.activeDisplays().contains(id) else { return nil }
        return CGDisplayBounds(id)
    }

    public func destroy() {
        // Releasing the object removes the virtual display (S2); physical displays are never removed.
        let taken = active.withLock { a -> Active? in
            defer { a = nil }
            return a
        }
        guard case .virtual(let vd, let mode) = taken else { return }
        if mode == .primary { _ = VirtualDisplay.restoreHostDisplays(mirroredTo: vd.displayID) }
        removed.withLock { $0 = vd.displayID }
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
        let taken = active.withLock { a -> Active? in
            defer { a = nil }
            return a
        }
        guard case .virtual(let vd, let mode) = taken else { return nil }
        let key = Self.keeperKey(for: vd.spec, mode: mode)
        if let keeper, keeper.keep(KeptVirtualDisplay(vd, mirrored: mode == .primary), key: key) { return nil }
        if mode == .primary { _ = VirtualDisplay.restoreHostDisplays(mirroredTo: vd.displayID) }
        return vd.displayID
    }
}

/// A `VirtualDisplay` held by the `DisplayKeeper` between sessions.
final class KeptVirtualDisplay: KeepableDisplay {
    private let display: Mutex<VirtualDisplay?>
    private let mirrored: Bool

    init(_ display: VirtualDisplay, mirrored: Bool = false) {
        self.display = Mutex(display)
        self.mirrored = mirrored
    }

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

    func releaseNow() {
        _ = release()
    }

    /// Unmirrors (if mirrored) and drops the last reference (removing the display, S2) before returning its id.
    private func release() -> CGDirectDisplayID? {
        guard let vd = takeDisplay() else { return nil }
        if mirrored { _ = VirtualDisplay.restoreHostDisplays(mirroredTo: vd.displayID) }
        let id = vd.displayID
        withExtendedLifetime(vd) {}
        return id
    }
}
#endif
