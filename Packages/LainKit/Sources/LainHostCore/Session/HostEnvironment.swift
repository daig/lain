import CoreGraphics
import Foundation
import Synchronization

/// The display the session streams and injects into. M2: the main display; M3: the virtual display.
public struct HostDisplay: Sendable, Equatable {
    public var displayID: UInt32
    /// Top-left in global display space (points).
    public var origin: CGPoint
    /// Size in points: the client's cursor space (§6.3).
    public var pointSize: CGSize

    public init(displayID: UInt32, origin: CGPoint, pointSize: CGSize) {
        self.displayID = displayID
        self.origin = origin
        self.pointSize = pointSize
    }
}

/// Where the session learns about the Mac's display and cursor. Injected so tests run without hardware.
public protocol DisplayProvider: Sendable {
    func targetDisplay() -> HostDisplay
    /// The real cursor location in global display space (top-left origin, points), if known.
    func cursorLocation() -> CGPoint?
}

/// Display-sleep prevention and user-activity declarations (§5.5 Power), behind a protocol so tests
/// can record them.
public protocol PowerAssertions: Sendable {
    /// Held while a client is connected. Idempotent.
    func beginPreventingDisplaySleep()
    /// Idempotent.
    func endPreventingDisplaySleep()
    /// Injected input counts as user activity (resets the idle timers). The session throttles calls.
    func declareUserActivity()
}

/// The Mac's input settings the client needs in `HelloAck` (§7.5).
public struct HostInputSettings: Sendable, Equatable {
    public var doubleClickIntervalMs: UInt32
    public var keyRepeatDelayMs: UInt32
    public var keyRepeatIntervalMs: UInt32
    /// e.g. "com.apple.keylayout.Colemak" (D18).
    public var inputSourceID: String

    public init(doubleClickIntervalMs: UInt32, keyRepeatDelayMs: UInt32, keyRepeatIntervalMs: UInt32,
                inputSourceID: String) {
        self.doubleClickIntervalMs = doubleClickIntervalMs
        self.keyRepeatDelayMs = keyRepeatDelayMs
        self.keyRepeatIntervalMs = keyRepeatIntervalMs
        self.inputSourceID = inputSourceID
    }
}

#if os(macOS)
import IOKit.pwr_mgt

extension HostInputSettings {
    /// Read now from the Mac (the owner may change them between sessions).
    public static var current: HostInputSettings {
        HostInputSettings(doubleClickIntervalMs: MacInputSettings.doubleClickIntervalMs,
                          keyRepeatDelayMs: MacInputSettings.keyRepeatDelayMs,
                          keyRepeatIntervalMs: MacInputSettings.keyRepeatIntervalMs,
                          inputSourceID: MacInputSettings.inputSourceID)
    }
}

/// M2: the main display (the owner watches the Mac's own monitor).
public struct MainDisplayProvider: DisplayProvider {
    public init() {}

    public func targetDisplay() -> HostDisplay {
        let id = CGMainDisplayID()
        let bounds = CGDisplayBounds(id)
        return HostDisplay(displayID: id, origin: bounds.origin, pointSize: bounds.size)
    }

    public func cursorLocation() -> CGPoint? { CGEvent(source: nil)?.location }
}

/// IOPM assertions: `PreventUserIdleDisplaySleep` while connected, `IOPMAssertionDeclareUserActivity`
/// for injected input.
public final class IOPMPowerAssertions: PowerAssertions {
    private struct State {
        var displayAssertion: IOPMAssertionID?
        var activityAssertion: IOPMAssertionID = IOPMAssertionID(0)
    }
    private let state = Mutex(State())
    private let name: String

    public init(name: String = "lain: iPad connected") { self.name = name }

    deinit { endPreventingDisplaySleep() }

    public func beginPreventingDisplaySleep() {
        state.withLock { s in
            guard s.displayAssertion == nil else { return }
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
            if rc == kIOReturnSuccess { s.displayAssertion = id }
        }
    }

    public func endPreventingDisplaySleep() {
        state.withLock { s in
            if let id = s.displayAssertion { IOPMAssertionRelease(id) }
            s.displayAssertion = nil
            if s.activityAssertion != 0 {
                IOPMAssertionRelease(s.activityAssertion)
                s.activityAssertion = 0
            }
        }
    }

    public func declareUserActivity() {
        state.withLock { s in
            // Passing the previous ID back updates that assertion instead of creating a new one.
            _ = IOPMAssertionDeclareUserActivity(name as CFString, kIOPMUserActiveLocal, &s.activityAssertion)
        }
    }
}
#endif
