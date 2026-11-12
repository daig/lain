#if os(macOS)
import AppKit
import Carbon
import CoreGraphics
import LainInput
import LainProtocol
import Synchronization

/// Posts the client's input into macOS (§5.5): CGEvents at the HID tap from a `.hidSystemState`
/// source, so they look like hardware to everything downstream. Tracks what it holds so `releaseAll`
/// (invariant 4) and disconnects can let go of everything.
///
/// Positions arrive in global display points (the client's cursor roams the whole desktop) and are
/// posted as they are.
public final class InputInjector: InputSink, @unchecked Sendable {
    public static var hasAccess: Bool { CGPreflightPostEventAccess() }
    /// Shows the Accessibility prompt the first time (§2). Returns the current state.
    @discardableResult public static func requestAccess() -> Bool { CGRequestPostEventAccess() }

    private let source: CGEventSource?
    private struct State {
        var heldKeys: [UInt16] = []          // macOS keycodes, press order
        var buttons = HeldButtons()
        var modifiers: ModifierFlags = []
        var position = CGPoint.zero
    }
    private let state = Mutex(State())

    public init(keyboardType: KeyboardType = .unknown) {
        source = CGEventSource(stateID: .hidSystemState)
        if let kbd = Self.cgKeyboardType(keyboardType) { source?.keyboardType = kbd }
        refreshLayoutKeys()
    }

    /// Set from the client's `Hello` at session start, before any key is posted.
    public func setKeyboardType(_ type: KeyboardType) {
        if let kbd = Self.cgKeyboardType(type) { source?.keyboardType = kbd }
    }

    // MARK: Keys

    /// A key from the client (physical HID key, already remapped by the client).
    public func key(_ e: KeyEvent) {
        guard let code = MacKeyCode.from(PhysicalKey(page: e.usagePage, usage: e.usage)) else { return }
        let proceed = state.withLock { s -> Bool in
            s.modifiers = e.modifiers
            if e.isDown {
                if !e.isRepeat, !s.heldKeys.contains(code) { s.heldKeys.append(code) }
                return e.isRepeat ? s.heldKeys.contains(code) : true
            }
            guard let i = s.heldKeys.firstIndex(of: code) else { return false }   // orphan up
            s.heldKeys.remove(at: i)
            return true
        }
        guard proceed else { return }
        postKey(code, down: e.isDown, repeat: e.isRepeat, modifiers: e.modifiers)
    }

    // MARK: Text

    /// macOS virtual keycodes for the two characters typed as keys.
    static let returnKey: UInt16 = 36, tabKey: UInt16 = 48

    /// The key (and whether Shift) that types each character in the Mac's current layout, for text sent with
    /// modifiers. Read on the main thread (Text Input Sources requires it) when the injector is made and
    /// after each use, so a layout change is picked up by the following chord.
    private let layoutKeys = Mutex<[Character: LayoutKey]>([:])
    public struct LayoutKey: Sendable, Equatable { public var code: UInt16, shift: Bool }

    private func refreshLayoutKeys() {
        DispatchQueue.main.async { [weak self] in
            let keys = Self.currentLayoutKeys()
            self?.layoutKeys.withLock { $0 = keys }
        }
    }

    /// Every character the current keyboard layout types with no modifier or with Shift (main thread).
    public static func currentLayoutKeys() -> [Character: LayoutKey] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var out: [Character: LayoutKey] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for shift in [true, false] {   // unshifted last: it wins where both type the character
                for code in UInt16(0)..<128 {
                    var dead: UInt32 = 0, length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), shift ? UInt32(shiftKey >> 8) & 0xFF : 0,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead,
                                                chars.count, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let string = String(utf16CodeUnits: chars, count: length)
                    guard string.count == 1, let c = string.first, !c.isNewline, c != "\t" else { continue }
                    out[c] = LayoutKey(code: code, shift: shift)
                }
            }
        }
        return out
    }

    /// v6 `TextInput`. Plain text is typed one character at a time, as key events that carry the character
    /// itself (so the keyboard layout doesn't matter) with no modifiers (so a held Command can't make
    /// shortcuts of it). With `modifiers`, each character is the key that types it in the current layout,
    /// pressed with them held; a character the layout doesn't have is skipped. A line feed is the Return key
    /// and a tab the Tab key either way, which apps act on as keys.
    public func text(_ text: String, modifiers: ModifierFlags) {
        let keys = modifiers.isEmpty ? [:] : layoutKeys.withLock { $0 }
        for character in text {
            switch character {
            case "\n", "\r\n", "\r": tap(Self.returnKey, modifiers: modifiers)
            case "\t": tap(Self.tabKey, modifiers: modifiers)
            default:
                if modifiers.isEmpty {
                    let units = Array(String(character).utf16)
                    for down in [true, false] {
                        guard let ev = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                        ev.flags = []
                        ev.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                        ev.post(tap: .cghidEventTap)
                    }
                } else if let key = keys[character] ?? keys[Character(character.lowercased())] {
                    tap(key.code, modifiers: key.shift ? modifiers.union(.shift) : modifiers)
                }
            }
        }
        if !modifiers.isEmpty { refreshLayoutKeys() }
    }

    private func tap(_ code: UInt16, modifiers: ModifierFlags) {
        postKey(code, down: true, repeat: false, modifiers: modifiers)
        postKey(code, down: false, repeat: false, modifiers: modifiers)
    }

    // MARK: Pointer

    public func move(_ m: PointerMove) {
        let (point, buttons, mods) = state.withLock { s in
            s.position = CGPoint(x: m.x, y: m.y)
            return (s.position, s.buttons.mask, s.modifiers)
        }
        let (type, button) = Self.moveType(buttons: buttons)
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(m.dx.rounded()))
        ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(m.dy.rounded()))
        ev.flags = Self.cgFlags(mods)
        ev.post(tap: .cghidEventTap)
    }

    public func button(_ b: PointerButton) {
        let (point, changed) = state.withLock { s -> (CGPoint, Bool) in
            s.position = CGPoint(x: b.x, y: b.y)
            s.modifiers = b.modifiers
            return (s.position, s.buttons.set(b.button, down: b.isDown))
        }
        guard changed else { return }
        postButton(b.button, down: b.isDown, at: point, clickCount: b.clickCount, modifiers: b.modifiers)
    }

    // MARK: Scroll

    /// Continuous pixel scroll with phase and momentum phase (§5.5).
    public func scroll(_ s: Scroll) {
        guard let ev = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                               wheel1: Int32(s.dy.rounded()), wheel2: Int32(s.dx.rounded()), wheel3: 0) else { return }
        ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(s.dy))
        ev.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(s.dx))
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(s.dy))
        ev.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(s.dx))
        ev.setIntegerValueField(.scrollWheelEventScrollPhase, value: Self.scrollPhase(s.phase))
        ev.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Self.momentumPhase(s.momentumPhase))
        ev.flags = Self.cgFlags(state.withLock { $0.modifiers })
        ev.post(tap: .cghidEventTap)
    }

    // MARK: Release

    /// Invariant 4: key-ups for every held key (regular keys first), then button-ups.
    public func releaseAll() {
        let (keys, buttons, point) = state.withLock { s in
            defer {
                s.heldKeys.removeAll()
                s.modifiers = []
            }
            let regular = s.heldKeys.filter { !Self.modifierKeyCodes.contains($0) }.reversed()
            let mods = s.heldKeys.filter { Self.modifierKeyCodes.contains($0) }.reversed()
            return (Array(regular) + Array(mods), s.buttons.releaseAll(x: 0, y: 0), s.position)
        }
        for code in keys { postKey(code, down: false, repeat: false, modifiers: []) }
        for b in buttons { postButton(b.button, down: false, at: point, clickCount: 1, modifiers: []) }
    }

    // MARK: Posting

    private func postKey(_ code: UInt16, down: Bool, repeat isRepeat: Bool, modifiers: ModifierFlags) {
        guard let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        ev.flags = Self.cgFlags(modifiers)
        if isRepeat { ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        ev.post(tap: .cghidEventTap)
    }

    private func postButton(_ button: MouseButton, down: Bool, at point: CGPoint, clickCount: UInt8, modifiers: ModifierFlags) {
        let (type, cgButton) = Self.buttonType(button, down: down)
        guard let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        ev.flags = Self.cgFlags(modifiers)
        ev.post(tap: .cghidEventTap)
    }

    // MARK: Mapping (pure; unit-tested)

    static let modifierKeyCodes: Set<UInt16> = [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E, 0x3F, 0x39]

    public static func cgFlags(_ m: ModifierFlags) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.command) { f.insert(.maskCommand) }
        if m.contains(.function) { f.insert(.maskSecondaryFn) }
        if m.contains(.capsLock) { f.insert(.maskAlphaShift) }
        return f
    }

    /// Moving with a button held is a drag (§5.5).
    static func moveType(buttons: UInt8) -> (CGEventType, CGMouseButton) {
        if buttons & 1 != 0 { return (.leftMouseDragged, .left) }
        if buttons & 2 != 0 { return (.rightMouseDragged, .right) }
        if buttons & 4 != 0 { return (.otherMouseDragged, .center) }
        return (.mouseMoved, .left)
    }

    static func buttonType(_ b: MouseButton, down: Bool) -> (CGEventType, CGMouseButton) {
        switch b {
        case .left: (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (down ? .rightMouseDown : .rightMouseUp, .right)
        case .other: (down ? .otherMouseDown : .otherMouseUp, .center)
        }
    }

    /// kCGScrollPhase* values.
    static func scrollPhase(_ p: GesturePhase) -> Int64 {
        switch p {
        case .none: 0
        case .mayBegin: 128
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        }
    }

    /// kCGMomentumScrollPhase* values.
    static func momentumPhase(_ p: MomentumPhase) -> Int64 {
        switch p {
        case .none: 0
        case .began: 1
        case .changed: 2
        case .ended: 3
        }
    }

    /// CGEventSource keyboard types for Apple ANSI/ISO/JIS layouts (40/41/42). To be confirmed with a
    /// non-ANSI keyboard in M2.
    static func cgKeyboardType(_ t: KeyboardType) -> CGEventSourceKeyboardType? {
        switch t {
        case .unknown: nil
        case .ansi: 40
        case .iso: 41
        case .jis: 42
        }
    }
}

/// The Mac's input settings the client needs (`HelloAck`, §7.5).
public enum MacInputSettings {
    public static var doubleClickIntervalMs: UInt32 { UInt32((NSEvent.doubleClickInterval * 1000).rounded()) }
    public static var keyRepeatDelayMs: UInt32 { UInt32((NSEvent.keyRepeatDelay * 1000).rounded()) }
    public static var keyRepeatIntervalMs: UInt32 { UInt32((NSEvent.keyRepeatInterval * 1000).rounded()) }

    /// The current keyboard input source (D18), e.g. "com.apple.keylayout.Colemak".
    public static var inputSourceID: String {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "unknown" }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
#endif
