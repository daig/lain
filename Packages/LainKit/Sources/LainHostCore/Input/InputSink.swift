import CoreGraphics
import LainProtocol

/// Where the host's decoded input goes (§5.5): `InputInjector` on the Mac, a recording fake in tests.
/// Every method is called on the realtime connection's serial queue and must not block for long.
/// Pointer positions are global desktop points (top-left origin, main display at (0, 0)): the client's
/// cursor roams every display (`DisplayLayout`).
public protocol InputSink: AnyObject, Sendable {
    func key(_ event: KeyEvent)
    func move(_ move: PointerMove)
    func button(_ button: PointerButton)
    func scroll(_ scroll: Scroll)
    /// Invariant 4: key-ups for every held key, then button-ups.
    func releaseAll()
    /// The client's physical keyboard (ANSI/ISO/JIS) from `Hello`. The default implementation ignores it.
    func setKeyboardType(_ type: KeyboardType)
}

extension InputSink {
    public func setKeyboardType(_ type: KeyboardType) {}
}
