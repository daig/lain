import LainProtocol

/// Client-side key repeat (§5.5): the client generates repeats from the Mac's `keyRepeatDelay` and
/// `keyRepeatInterval` (`HelloAck`), and the host marks them `keyboardEventAutorepeat`. Only the most
/// recently pressed non-modifier key repeats, as on the Mac.
public struct KeyRepeatGenerator: Sendable {
    public var delayNs: UInt64
    public var intervalNs: UInt64
    private var repeating: KeyEvent?
    private var nextNs: UInt64 = 0

    public init(delayMs: UInt32 = 225, intervalMs: UInt32 = 30) {
        delayNs = UInt64(delayMs) * 1_000_000
        intervalNs = UInt64(max(intervalMs, 1)) * 1_000_000
    }

    public var isRepeating: Bool { repeating != nil }

    /// Feed every key event sent to the Mac.
    public mutating func observe(_ event: KeyEvent, at timeNs: UInt64) {
        let key = PhysicalKey(page: event.usagePage, usage: event.usage)
        if key.isModifier || key == .capsLock {
            repeating?.modifiers = event.modifiers   // held key keeps repeating with the new modifiers
            return
        }
        if event.isDown {
            repeating = KeyEvent(usagePage: event.usagePage, usage: event.usage, isDown: true, isRepeat: true,
                                 modifiers: event.modifiers)
            nextNs = timeNs + delayNs
        } else if let r = repeating, r.usagePage == event.usagePage, r.usage == event.usage {
            repeating = nil
        }
    }

    /// A repeat due at `timeNs`, if any. At most one per call: a late tick never produces a burst.
    public mutating func tick(at timeNs: UInt64) -> KeyEvent? {
        guard let r = repeating, timeNs >= nextNs else { return nil }
        nextNs += intervalNs
        if nextNs <= timeNs { nextNs = timeNs + intervalNs }
        return r
    }

    public mutating func cancel() { repeating = nil }
}
