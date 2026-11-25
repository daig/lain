import Foundation

/// macOS-client-specific settings stored alongside `ClientPreferences` in `UserDefaults`.
struct MacClientPreferences: Sendable, Equatable {
    /// Automatically capture relative pointer in full-screen so screen edges hit the remote menu bar / Dock
    /// instead of local macOS chrome, and allow roaming across multi-display Extend setups.
    var capturePointerInFullScreen = true
    /// Optional `CGEventTap` (requires macOS Accessibility permission) to forward Cmd+Tab, Cmd+Space,
    /// Ctrl+Arrows, etc. directly to the remote host while focused.
    var captureSystemShortcuts = false
    /// Dynamically resize the host virtual display to match this window's backing pixel size on resize end
    /// and full-screen transitions (in Mirror/Extend virtual-display modes).
    var matchWindowSize = true
    /// Locally mute the host's streamed audio.
    var soundMuted = false
    /// True once the user explicitly picked a display scale (overrides automatic scale tracking on resize).
    var hasCustomDisplayScale = false

    private static let captureFullScreenKey = "lain.mac.capturePointerInFullScreen"
    private static let captureShortcutsKey = "lain.mac.captureSystemShortcuts"
    private static let matchWindowSizeKey = "lain.mac.matchWindowSize"
    private static let soundMutedKey = "lain.mac.soundMuted"
    private static let customScaleKey = "lain.mac.hasCustomDisplayScale"

    static func load(from defaults: UserDefaults = .standard) -> MacClientPreferences {
        var p = MacClientPreferences()
        if defaults.object(forKey: captureFullScreenKey) != nil {
            p.capturePointerInFullScreen = defaults.bool(forKey: captureFullScreenKey)
        }
        p.captureSystemShortcuts = defaults.bool(forKey: captureShortcutsKey)
        if defaults.object(forKey: matchWindowSizeKey) != nil {
            p.matchWindowSize = defaults.bool(forKey: matchWindowSizeKey)
        }
        p.soundMuted = defaults.bool(forKey: soundMutedKey)
        p.hasCustomDisplayScale = defaults.bool(forKey: customScaleKey)
        return p
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(capturePointerInFullScreen, forKey: Self.captureFullScreenKey)
        defaults.set(captureSystemShortcuts, forKey: Self.captureShortcutsKey)
        defaults.set(matchWindowSize, forKey: Self.matchWindowSizeKey)
        defaults.set(soundMuted, forKey: Self.soundMutedKey)
        defaults.set(hasCustomDisplayScale, forKey: Self.customScaleKey)
    }
}
