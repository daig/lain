import CoreGraphics
import LainProtocol
import LainTelemetry

/// Turns the client's decoded input messages into `InputSink` calls (§5.5). Pure apart from the
/// sink; runs synchronously on the realtime connection's queue (invariant 3: never queued, never awaits).
///
/// Gestures (v1): pinch → Cmd = / Cmd − via `PinchZoomMapper`; rotate is ignored (logged once).
public struct HostInputRouter: Sendable {
    /// What a message did, so the session can track the commanded cursor and user activity.
    public enum Outcome: Sendable, Equatable {
        /// Not an input message (control, cursor, video…); the caller handles it.
        case notInput
        /// An input message with no effect on the Mac (e.g. rotate in v1).
        case ignored
        /// Input was injected. `pointer` is the commanded position (display points) for pointer events.
        case injected(pointer: CGPoint?)
        /// `ReleaseAll`: everything held was released.
        case released
    }

    /// HID keyboard-page usages for the zoom shortcuts: '=' and '-' (same positions in QWERTY and
    /// Colemak), with Left Command held.
    public static let zoomInUsage: UInt16 = 0x2E
    public static let zoomOutUsage: UInt16 = 0x2D
    public static let commandUsage: UInt16 = 0xE3

    public let sink: any InputSink
    public private(set) var pinch: PinchZoomMapper
    /// The client's modifier state as of its last key or button event.
    public private(set) var modifiers: ModifierFlags = []
    private var loggedRotate = false

    public init(sink: any InputSink, pinch: PinchZoomMapper = PinchZoomMapper()) {
        self.sink = sink
        self.pinch = pinch
    }

    public mutating func handle(_ envelope: Envelope) -> Outcome { handle(envelope.message) }

    public mutating func handle(_ message: Message) -> Outcome {
        switch message {
        case .keyEvent(let e):
            modifiers = e.modifiers
            sink.key(e)
            return .injected(pointer: nil)
        case .pointerMove(let m):
            sink.move(m)
            return .injected(pointer: CGPoint(x: m.x, y: m.y))
        case .pointerButton(let b):
            modifiers = b.modifiers
            sink.button(b)
            return .injected(pointer: CGPoint(x: b.x, y: b.y))
        case .scroll(let s):
            sink.scroll(s)
            return .injected(pointer: nil)
        case .gesture(let g):
            return gesture(g)
        case .releaseAll:
            pinch.reset()
            modifiers = []
            sink.releaseAll()
            return .released
        default:
            return .notInput
        }
    }

    private mutating func gesture(_ g: Gesture) -> Outcome {
        switch g.kind {
        case .rotate:
            if !loggedRotate {
                loggedRotate = true
                Telemetry.logger("input").notice("rotate gestures are ignored in v1 (§5.5)")
            }
            return .ignored
        case .magnify:
            let steps = pinch.add(Double(g.value))
            if g.phase == .ended || g.phase == .cancelled { pinch.reset() }
            guard steps != 0 else { return .ignored }
            let usage = steps > 0 ? Self.zoomInUsage : Self.zoomOutUsage
            for _ in 0..<abs(steps) { pressWithCommand(usage) }
            return .injected(pointer: nil)
        }
    }

    /// One Cmd-<key> press. Presses Left Command only if the client isn't already holding it, and
    /// releases it afterwards so the Mac is back at the client's own modifiers.
    private func pressWithCommand(_ usage: UInt16) {
        let held = modifiers
        let withCommand = held.union(.command)
        let pressCommand = !held.contains(.command)
        if pressCommand { sink.key(KeyEvent(usage: Self.commandUsage, isDown: true, modifiers: withCommand)) }
        sink.key(KeyEvent(usage: usage, isDown: true, modifiers: withCommand))
        sink.key(KeyEvent(usage: usage, isDown: false, modifiers: withCommand))
        if pressCommand { sink.key(KeyEvent(usage: Self.commandUsage, isDown: false, modifiers: held)) }
    }
}
