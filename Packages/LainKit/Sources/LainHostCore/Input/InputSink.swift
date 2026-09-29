import CoreGraphics
import LainProtocol

/// Where the host's decoded input goes (§5.5): `InputInjector` on the Mac, a recording fake in tests.
/// Every method is called on the realtime connection's serial queue and must not block for long.
public protocol InputSink: AnyObject, Sendable {
    func key(_ event: KeyEvent)
    func move(_ move: PointerMove)
    func button(_ button: PointerButton)
    func scroll(_ scroll: Scroll)
    /// Invariant 4: key-ups for every held key, then button-ups.
    func releaseAll()
    /// The streamed display's origin in global display space; positions arrive relative to it.
    func setDisplayOrigin(_ origin: CGPoint)
    /// The client's physical keyboard (ANSI/ISO/JIS) from `Hello`. The default implementation ignores it.
    func setKeyboardType(_ type: KeyboardType)
}

extension InputSink {
    public func setKeyboardType(_ type: KeyboardType) {}
}
