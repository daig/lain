import CoreGraphics
import Foundation

/// Detects cursor moves the client didn't command (§5.4 warp): the Mac's own mouse, or an app
/// warping the cursor. The session reports every injected input with `noteInput`, and samples the
/// real cursor location (global desktop points, on any display: nothing is clamped, since the client's
/// cursor roams the whole desktop) at about 60 Hz with `sample`. A warp is reported
/// when the real location differs from the last commanded one by more than `tolerance` and no input
/// has been injected for `quietNs` (so in-flight injected moves aren't mistaken for warps).
///
/// Before any position is known (a new session) the first quiet sample is reported, which gives the
/// client the Mac's cursor position at startup (§7.5 handshake step 4).
public struct CursorWarpDetector: Sendable {
    public static let defaultTolerance = 1.0
    public static let defaultQuietNs: UInt64 = 100_000_000

    public let tolerance: Double
    public let quietNs: UInt64
    /// Where the cursor should be: the last commanded or reported position.
    public private(set) var expected: CGPoint?
    public private(set) var lastInputNs: UInt64?

    public init(tolerance: Double = CursorWarpDetector.defaultTolerance,
                quietNs: UInt64 = CursorWarpDetector.defaultQuietNs) {
        self.tolerance = tolerance
        self.quietNs = quietNs
    }

    /// Any injected input at `nowNs`; `pointer` is the commanded position for pointer events.
    public mutating func noteInput(pointer: CGPoint?, atNs nowNs: UInt64) {
        lastInputNs = nowNs
        if let pointer { expected = pointer }
    }

    /// The real cursor location at `nowNs`. Returns the position to send as `CursorWarp`, if any.
    public mutating func sample(_ actual: CGPoint, atNs nowNs: UInt64) -> CGPoint? {
        if let last = lastInputNs, nowNs < last &+ quietNs { return nil }
        if let expected, hypot(actual.x - expected.x, actual.y - expected.y) <= tolerance { return nil }
        expected = actual
        return actual
    }

    /// The client got a new `DisplayLayout`: a warp it received before it may have been clamped to the
    /// old arrangement, so the next quiet sample reports the cursor again (after the layout).
    public mutating func resync() {
        expected = nil
    }

    /// A new session: nothing is known about the client's cursor.
    public mutating func reset() {
        expected = nil
        lastInputNs = nil
    }
}
