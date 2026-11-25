import ApplicationServices
import AppKit
import CoreGraphics
import LainClientCore
import LainInput
import LainProtocol
import os
import Synchronization

/// Optional `CGEventTap` that intercepts macOS system shortcuts (`Cmd+Tab`, `Cmd+Space`, `Cmd+H`, `Cmd+Q`,
/// `Cmd+\``, `Ctrl+Arrows`) while the lain stream window is key and focused, forwarding them straight to
/// the remote host instead of letting the local Mac act on them.
///
/// Requires Accessibility permission (`AXIsProcessTrusted()`). Always leaves `⌃⌥Esc` untouched as a local
/// release chord and disables itself immediately whenever the window resigns key or the Control Panel opens.
final class SystemShortcutTap: @unchecked Sendable {
    static var hasAccess: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private let input: ClientInput
    private let cursor: CursorOverlay
    private let onReleaseChord: @Sendable () -> Void
    private let activeFlag = Atomic<Bool>(false)
    private let log = Logger(subsystem: "lain", category: "macclient.tap")

    // Main-thread only:
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(input: ClientInput, cursor: CursorOverlay, onReleaseChord: @escaping @Sendable () -> Void) {
        self.input = input
        self.cursor = cursor
        self.onReleaseChord = onReleaseChord
    }

    deinit {
        stop()
    }

    var isRunning: Bool { tap != nil }

    /// Enables or disables interception without tearing down the tap port on every focus switch.
    func setActive(_ active: Bool) {
        activeFlag.store(active, ordering: .relaxed)
    }

    /// Creates and attaches the event tap to the main run loop if Accessibility is granted.
    @MainActor
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard Self.hasAccess else { return false }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let tapSelf = Unmanaged<SystemShortcutTap>.fromOpaque(userInfo).takeUnretainedValue()
                return tapSelf.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            log.error("CGEvent.tapCreate failed despite AXIsProcessTrusted")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
        log.notice("system shortcut event tap started")
        return true
    }

    func stop() {
        activeFlag.store(false, ordering: .relaxed)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            tap = nil
            log.notice("system shortcut event tap stopped")
        }
    }

    // MARK: Tap Callback

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard activeFlag.load(ordering: .relaxed) else {
            return Unmanaged.passUnretained(event)
        }
        let macCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let rawFlags = event.flags.rawValue

        // Local escape hatch: ⌃⌥Esc releases capture and stops intercepting.
        if type == .keyDown, MacKeyboardInput.isReleaseChord(macKeyCode: macCode, rawFlags: rawFlags) {
            activeFlag.store(false, ordering: .relaxed)
            onReleaseChord()
            return nil
        }

        // Only intercept events that macOS would otherwise steal globally; let regular keys and modifiers
        // flow to AppKit (`MacStreamView`) so layout learning (`charactersIgnoringModifiers`), Right Option
        // panel hold, and modifier state stay 100% unified.
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }
        guard Self.isSystemInterceptedShortcut(macKeyCode: macCode, flags: event.flags) else {
            return Unmanaged.passUnretained(event)
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat { return nil }
        guard let physical = MacKeyCode.physicalKey(forMacKeyCode: macCode) else {
            return Unmanaged.passUnretained(event)
        }
        let isDown = (type == .keyDown)
        if isDown { cursor.keyDown() }
        input.keyChanged(physical, isDown: isDown)
        return nil
    }

    /// Shortcuts that macOS WindowServer/Dock/Spotlight normally swallow before the active app sees them.
    private static func isSystemInterceptedShortcut(macKeyCode: UInt16, flags: CGEventFlags) -> Bool {
        let cmd = flags.contains(.maskCommand)
        let ctrl = flags.contains(.maskControl)
        let opt = flags.contains(.maskAlternate)
        // Cmd+Tab (0x30), Cmd+Space (0x31), Cmd+` (0x32), Cmd+H (0x04), Cmd+Q (0x0C), Cmd+M (0x2E)
        if cmd && !ctrl {
            switch macKeyCode {
            case 0x30, 0x31, 0x32, 0x04, 0x0C, 0x2E:
                return true
            default:
                break
            }
        }
        // Ctrl+Arrows (Mission Control / App Exposé / Spaces: 0x7B..0x7E)
        if ctrl && !cmd && !opt && (0x7B...0x7E).contains(macKeyCode) {
            return true
        }
        return false
    }
}
