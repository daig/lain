import CoreGraphics
import Foundation
import LainProtocol
import Synchronization

/// The display the session streams (its size goes in `HelloAck`). M2: the main display; M3: the
/// virtual display. Input is injected anywhere on the desktop in global points (`DisplayLayout`).
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

/// Where the session learns about the Mac's displays and cursor. Injected so tests run without hardware.
public protocol DisplayProvider: Sendable {
    /// The streamed display.
    func targetDisplay() -> HostDisplay
    /// Every display the cursor can reach, in global points, with the streamed one marked (full-desktop
    /// cursor, §5.1 target setup). The default is the target display alone.
    func desktopLayout() -> DisplayLayout
    /// The real cursor location in global display space (top-left origin, points), if known.
    func cursorLocation() -> CGPoint?
    /// This provider with the streamed display chosen by `displayID` (a session binds it to its video
    /// pipeline's virtual display). The default ignores it: fixed providers (tests) stay as they are.
    func streaming(_ displayID: @escaping @Sendable () -> UInt32?) -> any DisplayProvider
}

extension DisplayProvider {
    public func streaming(_ displayID: @escaping @Sendable () -> UInt32?) -> any DisplayProvider { self }

    public func desktopLayout() -> DisplayLayout {
        let d = targetDisplay()
        return DisplayLayout(displays: [DisplayLayout.Display(
            displayID: d.displayID, x: d.origin.x, y: d.origin.y, width: d.pointSize.width, height: d.pointSize.height,
            isStreamed: true)])
    }
}

/// One active display as CoreGraphics reports it.
public struct ActiveDisplay: Sendable, Equatable {
    /// macOS's headless placeholder: vendor "unkn", model "virt" (§5.1 Headless, verified 2026-09-28).
    public static let placeholderVendor: UInt32 = 0x756E_6B6E
    public static let placeholderModel: UInt32 = 0x7669_7274

    public var displayID: UInt32
    /// Global points, top-left origin (`CGDisplayBounds`).
    public var bounds: CGRect
    public var vendor: UInt32
    public var model: UInt32
    public var isMain: Bool

    public init(displayID: UInt32, bounds: CGRect, vendor: UInt32 = 0, model: UInt32 = 0, isMain: Bool = false) {
        self.displayID = displayID
        self.bounds = bounds
        self.vendor = vendor
        self.model = model
        self.isMain = isMain
    }

    /// The display macOS creates when no monitor is attached; not a real display.
    public var isPlaceholder: Bool { vendor == Self.placeholderVendor && model == Self.placeholderModel }
}

/// Lists the Mac's active displays (`CGGetActiveDisplayList` on the Mac, a fake in tests).
public protocol ActiveDisplaySource: Sendable {
    func activeDisplays() -> [ActiveDisplay]
}

/// The session's `DisplayProvider` for the full desktop: every active display (the macOS placeholder
/// left out when a real display exists), with the streamed one chosen by `streamedDisplayID`, which
/// the integrator binds to the video pipeline's virtual display (the main display until video exists).
/// Origins are whatever macOS arranged: lain never moves displays in Extend mode (§5.1).
public struct DisplayLayoutProvider: DisplayProvider {
    public let source: any ActiveDisplaySource
    public let streamedDisplayID: @Sendable () -> UInt32?
    private let cursor: @Sendable () -> CGPoint?

    public init(source: any ActiveDisplaySource, streamedDisplayID: @escaping @Sendable () -> UInt32?,
                cursor: @escaping @Sendable () -> CGPoint? = { nil }) {
        self.source = source
        self.streamedDisplayID = streamedDisplayID
        self.cursor = cursor
    }

    /// The displays the cursor can reach: all of them, minus the placeholder if a real one exists.
    public static func desktop(_ displays: [ActiveDisplay]) -> [ActiveDisplay] {
        let real = displays.filter { !$0.isPlaceholder }
        return real.isEmpty ? displays : real
    }

    /// The layout for `displays`; `streamed` marks at most one (nil or unknown: none).
    public static func layout(_ displays: [ActiveDisplay], streamed: UInt32?) -> DisplayLayout {
        DisplayLayout(displays: desktop(displays).map { d in
            DisplayLayout.Display(displayID: d.displayID, x: d.bounds.minX, y: d.bounds.minY, width: d.bounds.width,
                                  height: d.bounds.height, isStreamed: d.displayID == streamed)
        })
    }

    public func desktopLayout() -> DisplayLayout {
        Self.layout(source.activeDisplays(), streamed: streamedDisplayID())
    }

    /// The streamed display, else the main one, else the first; a zero display if there are none.
    public func targetDisplay() -> HostDisplay {
        let all = source.activeDisplays()
        let streamed = streamedDisplayID()
        guard let d = all.first(where: { $0.displayID == streamed }) ?? all.first(where: \.isMain) ?? all.first else {
            return HostDisplay(displayID: 0, origin: .zero, pointSize: .zero)
        }
        return HostDisplay(displayID: d.displayID, origin: d.bounds.origin, pointSize: d.bounds.size)
    }

    public func cursorLocation() -> CGPoint? { cursor() }

    public func streaming(_ displayID: @escaping @Sendable () -> UInt32?) -> any DisplayProvider {
        DisplayLayoutProvider(source: source, streamedDisplayID: displayID, cursor: cursor)
    }
}

/// Display-sleep prevention and user-activity declarations (§5.5 Power), behind a protocol so tests
/// can record them.
public protocol PowerAssertions: Sendable {
    /// Held while a client is connected. Counted: each session begins once and ends once, and the
    /// assertion is held while begins outnumber ends, so a hand-over between two sessions (USB taking
    /// over from Wi-Fi, §7.7) can't drop it.
    func beginPreventingDisplaySleep()
    /// Balances one `beginPreventingDisplaySleep`; an end without a begin is ignored.
    func endPreventingDisplaySleep()
    /// Injected input counts as user activity (resets the idle timers). The session throttles calls.
    func declareUserActivity()
}

/// The begin/end count behind `IOPMPowerAssertions` (§5.5 Power), apart from IOKit so it can be tested.
struct PowerAssertionCount: Sendable, Equatable {
    private(set) var count = 0

    /// Returns whether this begin must create the assertion (0 → 1).
    mutating func begin() -> Bool {
        count += 1
        return count == 1
    }

    /// Returns whether this end must release the assertion (1 → 0). An unmatched end changes nothing.
    mutating func end() -> Bool {
        guard count > 0 else { return false }
        count -= 1
        return count == 0
    }
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

/// The Mac's active displays from CoreGraphics.
public struct CGActiveDisplaySource: ActiveDisplaySource {
    public init() {}

    public func activeDisplays() -> [ActiveDisplay] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            ActiveDisplay(displayID: id, bounds: CGDisplayBounds(id), vendor: CGDisplayVendorNumber(id),
                          model: CGDisplayModelNumber(id), isMain: CGDisplayIsMain(id) != 0)
        }
    }
}

extension DisplayLayoutProvider {
    /// The real Mac: CoreGraphics displays and cursor. `streamedDisplayID` defaults to the main display
    /// (M2, before video); the integrator passes the virtual display's ID.
    public static func system(streamedDisplayID: @escaping @Sendable () -> UInt32? = { CGMainDisplayID() })
        -> DisplayLayoutProvider {
        DisplayLayoutProvider(source: CGActiveDisplaySource(), streamedDisplayID: streamedDisplayID,
                              cursor: { CGEvent(source: nil)?.location })
    }
}

/// IOPM assertions: `PreventUserIdleDisplaySleep` while connected (counted: held while begins outnumber
/// ends), `IOPMAssertionDeclareUserActivity` for injected input.
public final class IOPMPowerAssertions: PowerAssertions {
    private struct State {
        var count = PowerAssertionCount()
        var displayAssertion: IOPMAssertionID?
        var activityAssertion: IOPMAssertionID = IOPMAssertionID(0)

        mutating func release() {
            if let id = displayAssertion { IOPMAssertionRelease(id) }
            displayAssertion = nil
            if activityAssertion != 0 {
                IOPMAssertionRelease(activityAssertion)
                activityAssertion = 0
            }
        }
    }
    private let state = Mutex(State())
    private let name: String

    public init(name: String = "lain: iPad connected") { self.name = name }

    deinit { state.withLock { $0.release() } }

    public func beginPreventingDisplaySleep() {
        state.withLock { s in
            guard s.count.begin(), s.displayAssertion == nil else { return }
            var id = IOPMAssertionID(0)
            let rc = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
            if rc == kIOReturnSuccess { s.displayAssertion = id }
        }
    }

    public func endPreventingDisplaySleep() {
        state.withLock { s in
            guard s.count.end() else { return }
            s.release()
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
