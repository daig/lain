import LainInput
import LainProtocol

/// Everything the client does with raw input before it goes on the wire (§6.3, §6.4), independent of
/// UIKit and GameController so it is fully testable on the Mac.
///
/// Inputs are the capture layer's raw events, each stamped with a `CLOCK_UPTIME_RAW` time in ns;
/// output is the `send` closure (the realtime channel once a session is up). Owns the keyboard
/// processor (remaps with hold semantics), the client-authoritative cursor (invariant 1), click
/// counting, held buttons, scroll momentum and key repeat.
///
/// Thread model: not `Sendable`. One instance lives on one serial `.userInteractive` queue, reached
/// through `ClientInput`. Nothing here awaits or takes a lock.
public final class ClientInputPipeline {
    /// Where messages go. A no-op until a session connects.
    public var send: (Message) -> Void
    /// Negate scroll deltas. Off by default: the pan translation already has the Mac's continuous-
    /// scroll sign, and macOS applies no extra natural-scrolling flip to synthetic continuous events.
    public var invertScroll = false
    /// D19: pointer input (moves, button-downs, scroll, gestures) flows only while this is set, which the
    /// capture layer ties to the pointer lock. Keyboard input flows regardless. Button-ups for buttons
    /// already down still pass so nothing sticks.
    public var pointerEnabled = true

    public private(set) var keyboard: KeyboardProcessor
    public private(set) var pointer: PointerTracker
    public private(set) var clicks: ClickCounter
    public private(set) var heldButtons = HeldButtons()
    public private(set) var momentum: MomentumSynthesizer
    public private(set) var keyRepeat: KeyRepeatGenerator
    /// The Mac's input source from the last `HelloAck` (D18), e.g. "com.apple.keylayout.Colemak".
    public private(set) var macInputSource = ""
    public private(set) var isConfigured = false

    /// A trackpad scroll is in progress (pan began, not yet ended).
    public private(set) var isScrolling = false
    /// The current scroll has sent its `.began` event.
    private var scrollStarted = false

    public init(displayPointWidth: Double = 1440, displayPointHeight: Double = 900,
                table: RemapTable = .default, curve: AccelerationCurve = AccelerationCurve(),
                momentum: MomentumSynthesizer.Config = .init(), send: @escaping (Message) -> Void = { _ in }) {
        self.send = send
        keyboard = KeyboardProcessor(table: table)
        pointer = PointerTracker(width: displayPointWidth, height: displayPointHeight, curve: curve)
        clicks = ClickCounter()
        self.momentum = MomentumSynthesizer(config: momentum)
        keyRepeat = KeyRepeatGenerator()
    }

    // MARK: Configuration

    /// Applies the Mac's settings from `HelloAck`: display size in points (the cursor space, recentred),
    /// double-click interval, key-repeat delay and interval.
    public func configure(_ ack: HelloAck) {
        pointer = PointerTracker(width: Double(ack.displayPointWidth), height: Double(ack.displayPointHeight),
                                 curve: pointer.curve)
        clicks = ClickCounter(intervalMs: ack.doubleClickIntervalMs, maxDistance: clicks.maxDistance)
        keyRepeat = KeyRepeatGenerator(delayMs: ack.keyRepeatDelayMs, intervalMs: ack.keyRepeatIntervalMs)
        macInputSource = ack.macInputSource
        isConfigured = true
    }

    public var curve: AccelerationCurve {
        get { pointer.curve }
        set { pointer.curve = newValue }
    }

    public var remapTable: RemapTable {
        get { keyboard.table }
        set { keyboard.table = newValue }
    }

    // MARK: Keyboard

    /// A physical key changed (GCKeyboard usage, or Globe from UIKit).
    public func keyChanged(_ key: PhysicalKey, isDown: Bool, at timeNs: UInt64) {
        for event in keyboard.process(key, isDown: isDown) {
            send(.keyEvent(event))
            keyRepeat.observe(event, at: timeNs)
        }
    }

    /// Teaches the layout map what a key types (UIKit `charactersIgnoringModifiers`, D18).
    public func learnCharacter(_ key: PhysicalKey, _ characters: String) {
        keyboard.layout.learn(key, character: characters)
    }

    // MARK: Pointer

    /// A GCMouse delta (y up-positive). Zero deltas are ignored.
    public func mouseMoved(dx: Double, dy: Double, at timeNs: UInt64) {
        guard pointerEnabled else { return }
        guard let move = pointer.move(dx: dx, dy: dy, at: timeNs, buttons: heldButtons.mask) else { return }
        send(.pointerMove(move))
    }

    public func mouseButton(_ button: MouseButton, isDown: Bool, at timeNs: UInt64) {
        if isDown {
            guard pointerEnabled, heldButtons.set(button, down: true) else { return }
            if let stop = momentum.cancel() { send(.scroll(stop)) }   // a click stops a fling, as on the Mac
            let count = clicks.down(button, x: pointer.x, y: pointer.y, at: timeNs)
            send(.pointerButton(PointerButton(button: button, isDown: true, clickCount: count, x: pointer.x,
                                              y: pointer.y, modifiers: keyboard.macModifiers)))
        } else {
            guard heldButtons.set(button, down: false) else { return }   // orphan up
            send(.pointerButton(PointerButton(button: button, isDown: false, clickCount: clicks.upCount(button),
                                              x: pointer.x, y: pointer.y, modifiers: keyboard.macModifiers)))
        }
    }

    /// `CursorWarp` from the Mac overwrites the position (§6.3).
    public func warp(x: Double, y: Double) {
        pointer.warp(x: x, y: y)
    }

    // MARK: Scroll

    /// Fingers touched down for a scroll (pan `.began`). Stops any running momentum.
    public func scrollBegan(at timeNs: UInt64) {
        guard pointerEnabled else { return }
        if let stop = momentum.touchBegan(at: timeNs) { send(.scroll(stop)) }
        isScrolling = true
        scrollStarted = false
    }

    /// A scroll delta in points since the previous one (pan translation delta, passed through as is).
    public func scrollChanged(dx: Double, dy: Double, at timeNs: UInt64) {
        guard pointerEnabled else { return }
        if !isScrolling { scrollBegan(at: timeNs) }
        guard dx != 0 || dy != 0 else { return }
        let (sx, sy) = invertScroll ? (-dx, -dy) : (dx, dy)
        momentum.changed(dx: sx, dy: sy, at: timeNs)
        let phase: GesturePhase = scrollStarted ? .changed : .began
        scrollStarted = true
        send(.scroll(Scroll(dx: Float(sx), dy: Float(sy), phase: phase, momentumPhase: .none)))
    }

    /// Fingers lifted: ends the scroll phase and starts momentum if the fling was fast enough.
    public func scrollEnded(at timeNs: UInt64) {
        guard isScrolling else { return }
        isScrolling = false
        if scrollStarted {
            send(.scroll(Scroll(dx: 0, dy: 0, phase: .ended, momentumPhase: .none)))
            momentum.ended(at: timeNs)
        } else {
            _ = momentum.touchBegan(at: timeNs)   // drop samples; no momentum for a scroll that never moved
        }
        scrollStarted = false
    }

    /// The system cancelled the pan: end the phase without momentum.
    public func scrollCancelled(at timeNs: UInt64) {
        guard isScrolling else { return }
        isScrolling = false
        if scrollStarted { send(.scroll(Scroll(dx: 0, dy: 0, phase: .cancelled, momentumPhase: .none))) }
        _ = momentum.touchBegan(at: timeNs)
        scrollStarted = false
    }

    // MARK: Gestures

    /// Pinch (value = change in the absolute gesture scale since the previous event, so the host sees
    /// 1 + Σ value; `.ended`/`.cancelled` last) or rotate (value = incremental radians).
    public func gesture(_ kind: Gesture.Kind, phase: GesturePhase, value: Float, at timeNs: UInt64) {
        guard pointerEnabled || phase == .ended || phase == .cancelled else { return }
        send(.gesture(Gesture(kind: kind, phase: phase, value: value)))
    }

    // MARK: Time

    /// Call at the display rate (~120 Hz): advances momentum and emits due key repeats.
    public func tick(at timeNs: UInt64) {
        if let scroll = momentum.tick(at: timeNs) { send(.scroll(scroll)) }
        if let repeated = keyRepeat.tick(at: timeNs) { send(.keyEvent(repeated)) }
    }

    // MARK: Invariant 4

    /// Releases everything: with `notify`, ends any scroll or momentum on the Mac and sends `ReleaseAll`
    /// (the host lifts every key and button it holds); either way it forgets all held keys and buttons,
    /// stops repeat and momentum, so later key-ups for keys that were down are orphans and send nothing.
    /// `notify: false` is for a link that is already gone.
    public func releaseAll(_ reason: ReleaseAll.Reason, notify: Bool = true) {
        if notify {
            if isScrolling && scrollStarted {
                send(.scroll(Scroll(dx: 0, dy: 0, phase: .cancelled, momentumPhase: .none)))
            }
            if let stop = momentum.cancel() { send(.scroll(stop)) }
            send(.releaseAll(ReleaseAll(reason: reason)))
        }
        _ = keyboard.releaseAll()
        _ = heldButtons.releaseAll(x: pointer.x, y: pointer.y)
        keyRepeat.cancel()
        clicks.reset()
        momentum = MomentumSynthesizer(config: momentum.config)
        isScrolling = false
        scrollStarted = false
    }
}
