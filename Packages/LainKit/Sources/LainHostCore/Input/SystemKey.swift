import LainInput
import LainProtocol

/// Right Option is lain's *system key* (rust/HOST-PARITY.md §4, the owner's design of 2026-11-01): it stands
/// in for what iPadOS keeps for itself (some Command shortcuts and every three- and four-finger swipe), the
/// same physical keys on every host. Left Option stays a plain Option key.
///
/// - Right Option + a key: Command + that key (Right Opt-Tab is Cmd-Tab, and Command stays held while Right
///   Option does, so Tab again cycles the app switcher).
/// - Right Option + Up / Down: Ctrl-Up / Ctrl-Down (Mission Control, App Exposé); + Left / Right: Ctrl-Left /
///   Ctrl-Right (the previous / next Space). Each is sent as a chord of its own; the arrow's release sends nothing.
/// - Right Option tapped alone (released within `tapMaxNs`): Mission Control. A longer hold is not a tap:
///   the iPad shows its overlay while Right Option is held alone (v5).
/// - Right Option + a click: a Command-click.
///
/// Right Option itself never reaches the Mac while it is the system key (so a tap presses nothing). With
/// Left Option also held, both are plain Option.
///
/// Older clients turn Option-Tab, -Space, -H, -Q and -` into Command themselves (`KeyboardProcessor`): they
/// release Right Option and press Left Command before the key. That release is not a tap: a release is
/// only taken for a tap once the next event isn't a Command press (`pendingTap`), or once nothing has come
/// for `tapDelayNs` (the caller's timer, `flushTap`).
///
/// Pure apart from its output: each call returns the key events to post, in order.
public struct SystemKey: Sendable {
    public var isEnabled: Bool

    /// How long a release waits for the client's own Command press before it counts as a tap.
    public static let tapDelayNs: UInt64 = 60_000_000
    /// The longest press that is still a tap. The iPad shows its overlay after a longer hold (350 ms), so a
    /// hold that showed it is never a tap.
    public static let tapMaxNs: UInt64 = 300_000_000

    static let leftControl: UInt16 = 0xE0
    static let leftOption: UInt16 = 0xE2
    static let leftCommand: UInt16 = 0xE3
    static let rightOption: UInt16 = 0xE6
    static let rightCommand: UInt16 = 0xE7
    static let right: UInt16 = 0x4F, left: UInt16 = 0x50, down: UInt16 = 0x51, up: UInt16 = 0x52
    /// Arrow events carry the function flag on the Mac, and the Mission Control and Spaces shortcuts are
    /// defined with it (Control + fn).
    static let chordFlags: ModifierFlags = [.control, .function]

    private var leftOptionDown = false
    /// Right Option is down and was kept from the Mac.
    private var held = false
    /// Nothing else happened since Right Option went down: its release is a tap.
    private var tapArmed = false
    /// Left Command pressed on the Mac for the system key.
    private var commandDown = false
    /// A chorded arrow, whose release (and repeats) send nothing.
    private var chorded: UInt16?
    /// Right Option was released as a possible tap; the number tells a stale timer from a newer tap.
    public private(set) var pendingTap: UInt64?
    private var tapCount: UInt64 = 0
    /// When Right Option went down (the caller's clock; nil: no time given).
    private var downAtNs: UInt64?

    public init(isEnabled: Bool = true) { self.isEnabled = isEnabled }

    /// The system key is held: Right Option without Left Option.
    public var isHeld: Bool { isEnabled && held && !leftOptionDown }

    /// One key event from the client: what to post instead. `nowNs` (monotonic) limits taps to `tapMaxNs`;
    /// nil: any length.
    public mutating func key(_ e: KeyEvent, nowNs: UInt64? = nil) -> [KeyEvent] {
        var out = resolvePendingTap(before: e)
        guard isEnabled else { return out + [e] }
        let keyboard = e.usagePage == PhysicalKey.keyboardPage
        if keyboard, e.usage == Self.rightOption {
            if e.isDown {
                guard !leftOptionDown else { return out + [e] }   // both Options: plain Option
                held = true
                tapArmed = true
                downAtNs = nowNs
                return out
            }
            guard held else { return out + [e] }   // went down as a plain Option
            held = false
            out += releaseCommand(modifiers: e.modifiers)
            if let down = downAtNs, let now = nowNs, now &- down > Self.tapMaxNs { tapArmed = false }
            if tapArmed {
                tapArmed = false
                tapCount &+= 1
                pendingTap = tapCount
            }
            return out
        }
        if keyboard, e.usage == Self.leftOption { leftOptionDown = e.isDown }
        if !e.modifiers.contains(.option) {
            // The client holds no Option: whatever we thought was held isn't.
            leftOptionDown = false
            if held {
                held = false
                tapArmed = false
                out += releaseCommand(modifiers: e.modifiers)
            }
        }
        // Left Option joined a held Right Option: both are plain Option from here on.
        if held, leftOptionDown, commandDown { out += releaseCommand(modifiers: e.modifiers) }

        if keyboard, let chord = chorded, e.usage == chord {
            if !e.isDown { chorded = nil }
            return out   // the chorded arrow's repeats and release
        }
        let isModifier = PhysicalKey(page: e.usagePage, usage: e.usage).isModifier
        guard isHeld else { return out + [e] }
        if !isModifier { tapArmed = false }
        if keyboard, e.isDown, !e.isRepeat, let arrow = [Self.up, Self.down, Self.left, Self.right].first(where: { $0 == e.usage }) {
            out += releaseCommand(modifiers: e.modifiers.subtracting(.option))
            out += Self.chord(arrow, clientModifiers: e.modifiers)
            chorded = arrow
            return out
        }
        if !isModifier, e.isDown, !commandDown {
            commandDown = true
            out.append(KeyEvent(usage: Self.leftCommand, isDown: true, modifiers: mapped(e.modifiers)))
        }
        var forwarded = e
        forwarded.modifiers = mapped(e.modifiers)
        out.append(forwarded)
        return out
    }

    /// A click's modifiers: Command for the system key.
    public mutating func buttonModifiers(_ modifiers: ModifierFlags) -> ModifierFlags {
        guard isHeld else { return modifiers }
        tapArmed = false
        var m = modifiers
        m.remove(.option)
        m.insert(.command)
        return m
    }

    /// The caller's timer: the release numbered `tap` is a tap if nothing has resolved it since.
    public mutating func flushTap(_ tap: UInt64) -> [KeyEvent] {
        guard pendingTap == tap else { return [] }
        pendingTap = nil
        return Self.chord(Self.up, clientModifiers: [])
    }

    /// The session's end (invariant 4): forget everything. The caller releases what was posted.
    public mutating func reset() {
        leftOptionDown = false
        held = false
        tapArmed = false
        commandDown = false
        chorded = nil
        pendingTap = nil
        downAtNs = nil
    }

    // MARK: Private

    /// A pending tap, before the next event: the client's own Command press (an older client's remap)
    /// cancels it; anything else makes it a tap.
    private mutating func resolvePendingTap(before e: KeyEvent) -> [KeyEvent] {
        guard let tap = pendingTap else { return [] }
        let remap = e.isDown && e.usagePage == PhysicalKey.keyboardPage && (e.usage == Self.leftCommand || e.usage == Self.rightCommand)
        if remap {
            pendingTap = nil
            return []
        }
        return flushTap(tap)
    }

    /// The client's modifiers as the Mac should see them while the system key is held.
    private func mapped(_ modifiers: ModifierFlags) -> ModifierFlags {
        guard isHeld else { return modifiers }
        var m = modifiers
        m.remove(.option)
        if commandDown { m.insert(.command) }
        return m
    }

    /// Lifts the Command the system key pressed; `modifiers` are what stays held (the client's own).
    private mutating func releaseCommand(modifiers: ModifierFlags) -> [KeyEvent] {
        guard commandDown else { return [] }
        commandDown = false
        return [KeyEvent(usage: Self.leftCommand, isDown: false, modifiers: modifiers)]
    }

    /// `arrow` with Control (and fn) held, alone. Control isn't pressed or released if the client holds it.
    static func chord(_ arrow: UInt16, clientModifiers: ModifierFlags) -> [KeyEvent] {
        let pressControl = !clientModifiers.contains(.control)
        var out: [KeyEvent] = []
        if pressControl { out.append(KeyEvent(usage: leftControl, isDown: true, modifiers: [.control])) }
        out.append(KeyEvent(usage: arrow, isDown: true, modifiers: chordFlags))
        out.append(KeyEvent(usage: arrow, isDown: false, modifiers: chordFlags))
        if pressControl { out.append(KeyEvent(usage: leftControl, isDown: false, modifiers: [])) }
        return out
    }
}
