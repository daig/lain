import Foundation

/// The owner's host settings (rust/HOST-PARITY.md §1–§4), from the menu, kept in the app's defaults.
public struct HostPreferences: Sendable, Equatable {
    /// How long lain's display outlives a session whose link went away, so the iPad's return takes it
    /// back (windows stay put). 0: removed at once, as before.
    public var displayKeepAliveSeconds: Int = 30 {
        didSet { displayKeepAliveSeconds = Self.clampKeepAlive(displayKeepAliveSeconds) }
    }
    /// Pixels per point on lain's display: 2 is the iPad's own (1376×1032 points on a 13" iPad Pro); less
    /// is more space, more is larger. Applies to the next session.
    public var displayScale: Double = HostPreferences.defaultScale {
        didSet { displayScale = Self.clampScale(displayScale) }
    }
    /// After the owner stops lain's capture from the Mac's menu bar, start it again by itself (at most once
    /// per `HostSession.resumeMinGap`).
    public var resumeAfterStop = true
    /// Right Option is lain's system key (`SystemKey`). Applies to the next session.
    public var systemKey = true

    public init() {}

    public static let defaultScale = 2.0
    public static let keepAliveChoices = [0, 10, 30, 60, 120, 300]
    public static let scaleChoices = [1.5, 1.75, 2.0, 2.25, 2.5]
    public static let keepAliveRange = 0...600
    /// Below 1.5 the display's backing store would pass 3600 px; above 3 the desktop gets too small.
    public static let scaleRange = 1.5...3.0

    static func clampKeepAlive(_ s: Int) -> Int { min(max(s, keepAliveRange.lowerBound), keepAliveRange.upperBound) }
    static func clampScale(_ s: Double) -> Double {
        s.isFinite ? min(max(s, scaleRange.lowerBound), scaleRange.upperBound) : defaultScale
    }

    // MARK: Defaults

    enum Key {
        static let keepAlive = "displayKeepAliveSeconds"
        static let scale = "displayScale"
        static let resume = "resumeAfterStop"
        static let systemKey = "systemKey"
    }

    /// The stored settings (each one missing takes its default).
    public static func load(from defaults: UserDefaults = .standard) -> HostPreferences {
        var p = HostPreferences()
        if defaults.object(forKey: Key.keepAlive) != nil { p.displayKeepAliveSeconds = defaults.integer(forKey: Key.keepAlive) }
        if defaults.object(forKey: Key.scale) != nil { p.displayScale = defaults.double(forKey: Key.scale) }
        if defaults.object(forKey: Key.resume) != nil { p.resumeAfterStop = defaults.bool(forKey: Key.resume) }
        if defaults.object(forKey: Key.systemKey) != nil { p.systemKey = defaults.bool(forKey: Key.systemKey) }
        return p
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(displayKeepAliveSeconds, forKey: Key.keepAlive)
        defaults.set(displayScale, forKey: Key.scale)
        defaults.set(resumeAfterStop, forKey: Key.resume)
        defaults.set(systemKey, forKey: Key.systemKey)
    }
}
