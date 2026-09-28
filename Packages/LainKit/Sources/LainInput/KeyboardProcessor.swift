import LainProtocol

/// Turns physical key events from the iPad into the key events the Mac should see (§6.4):
/// applies the remap table with hold semantics, tracks what is held on the Mac for `ReleaseAll`
/// (invariant 4), and drops orphan key-ups and duplicate downs.
///
/// Hold semantics: Opt-Tab → Cmd-Tab releases Opt on the Mac and presses Cmd. While the physical Opt
/// key stays down, every key goes out with Cmd (so Tab again cycles the app switcher), and releasing
/// Opt releases Cmd.
public struct KeyboardProcessor: Sendable {
    public var table: RemapTable
    public var layout: LayoutCharacterMap

    /// Physical keys currently held on the iPad (as far as we have seen downs).
    private var physicalHeld: Set<PhysicalKey> = []
    /// Keys currently held on the Mac, in press order.
    private var macHeld: [PhysicalKey] = []
    private var capsLockOn = false
    private var hold: Hold?

    private struct Hold: Sendable {
        var to: ModifierFlags
        /// Physical source-modifier keys still down; the hold ends when this empties.
        var sourceKeys: Set<PhysicalKey>
        /// Synthesized modifier keys pressed on the Mac.
        var targetKeys: [PhysicalKey]
    }

    public init(table: RemapTable = .default, layout: LayoutCharacterMap = LayoutCharacterMap()) {
        self.table = table
        self.layout = layout
    }

    /// Modifiers held physically on the iPad.
    public var physicalModifiers: ModifierFlags {
        physicalHeld.reduce(into: []) { m, k in if let f = k.modifier { m.insert(f) } }
    }

    /// Modifiers the Mac currently sees held.
    public var macModifiers: ModifierFlags {
        var m: ModifierFlags = macHeld.reduce(into: []) { m, k in if let f = k.modifier { m.insert(f) } }
        if capsLockOn { m.insert(.capsLock) }
        return m
    }

    public var macHeldKeys: [PhysicalKey] { macHeld }
    public var isHoldingRemap: Bool { hold != nil }

    /// Processes one physical event; returns the events to send, in order (often one, sometimes none).
    public mutating func process(_ key: PhysicalKey, isDown: Bool) -> [KeyEvent] {
        var out: [KeyEvent] = []
        if isDown {
            guard physicalHeld.insert(key).inserted else { return [] }   // duplicate down
            if let flag = key.modifier {
                if var h = hold, isSource(flag) {
                    h.sourceKeys.insert(key)   // a second Opt while the hold is active stays hidden
                    hold = h
                    return []
                }
                emit(key, down: true, into: &out)
                return out
            }
            if hold == nil, let entry = table.match(character: layout.character(for: key), modifiers: physicalModifiers) {
                beginHold(entry, into: &out)
            }
            if key == .capsLock { capsLockOn.toggle() }
            emit(key, down: true, into: &out)
        } else {
            guard physicalHeld.remove(key) != nil else { return [] }   // orphan key-up (§6.4)
            if key.isModifier, var h = hold, h.sourceKeys.remove(key) != nil {
                if h.sourceKeys.isEmpty {
                    for t in h.targetKeys.reversed() { emit(t, down: false, into: &out) }
                    hold = nil
                } else {
                    hold = h
                }
                return out
            }
            emit(key, down: false, into: &out)
        }
        return out
    }

    /// Invariant 4: key-ups for everything held on the Mac (regular keys first, then modifiers),
    /// and forget all state. Later key-ups for keys that were down are then orphans and dropped.
    public mutating func releaseAll() -> [KeyEvent] {
        var out: [KeyEvent] = []
        let regular = macHeld.filter { !$0.isModifier }.reversed()
        let modifiers = macHeld.filter(\.isModifier).reversed()
        for k in Array(regular) + Array(modifiers) { emit(k, down: false, into: &out) }
        physicalHeld.removeAll()
        hold = nil
        return out
    }

    private var holdSourceFlags: ModifierFlags {
        hold.map { h in h.sourceKeys.reduce(into: ModifierFlags()) { m, k in if let f = k.modifier { m.insert(f) } } } ?? []
    }

    private func isSource(_ flag: ModifierFlags) -> Bool { holdSourceFlags.contains(flag) }

    private mutating func beginHold(_ entry: RemapEntry, into out: inout [KeyEvent]) {
        let sources = physicalHeld.filter { k in k.modifier.map { entry.from.contains($0) } ?? false }
        for s in macHeld where sources.contains(s) { emit(s, down: false, into: &out) }
        let targets = PhysicalKey.keys(for: entry.to).filter { !macHeld.contains($0) }
        for t in targets { emit(t, down: true, into: &out) }
        hold = Hold(to: entry.to, sourceKeys: sources, targetKeys: targets)
    }

    private mutating func emit(_ key: PhysicalKey, down: Bool, into out: inout [KeyEvent]) {
        if down {
            guard !macHeld.contains(key) else { return }
            macHeld.append(key)
        } else {
            guard let i = macHeld.firstIndex(of: key) else { return }
            macHeld.remove(at: i)
        }
        out.append(KeyEvent(usagePage: key.page, usage: key.usage, isDown: down, modifiers: macModifiers))
    }
}
