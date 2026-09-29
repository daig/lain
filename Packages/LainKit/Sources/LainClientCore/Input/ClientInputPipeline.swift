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
        streamedDisplay = DesktopDisplay(x: 0, y: 0, width: displayPointWidth, height: displayPointHeight)
        clicks = ClickCounter()
        self.momentum = MomentumSynthesizer(config: momentum)
        keyRepeat = KeyRepeatGenerator()
    }

    // MARK: Configuration

    /// Applies the Mac's settings from `HelloAck`: the streamed display's size in points, double-click
    /// interval, key-repeat delay and interval. Until a `DisplayLayout` arrives, the cursor space is that
    /// one display at (0, 0), recentred (the M2 behaviour, and the fallback for a host that sends none).
    public func configure(_ ack: HelloAck) {
        let display = DesktopDisplay(x: 0, y: 0, width: Double(ack.displayPointWidth),
                                     height: Double(ack.displayPointHeight))
        pointer = PointerTracker(displays: [display], curve: pointer.curve)
        streamedDisplay = display
        hasLayout = false
        clicks = ClickCounter(intervalMs: ack.doubleClickIntervalMs, maxDistance: clicks.maxDistance)
        keyRepeat = KeyRepeatGenerator(delayMs: ack.keyRepeatDelayMs, intervalMs: ack.keyRepeatIntervalMs)
        macInputSource = ack.macInputSource
        isConfigured = true
    }

    /// The Mac's display arrangement (full-desktop cursor, §5.1 target setup): the cursor roams every
    /// display in global points. The session's first layout recentres the cursor on the streamed display
    /// (a `CursorWarp` follows with the real position); later ones keep its global position, snapped
    /// onto the nearest display if its display went away or shrank. An empty layout is ignored.
    public func applyLayout(_ layout: DisplayLayout) {
        guard !layout.displays.isEmpty else { return }
        let rects = layout.displays.map { DesktopDisplay(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        let streamed = layout.displays.firstIndex(where: \.isStreamed)
        streamedDisplay = streamed.map { rects[$0] }
        if hasLayout {
            pointer.setDesktop(rects)
        } else {
            pointer = PointerTracker(displays: rects, startIndex: streamed ?? 0, curve: pointer.curve)
            hasLayout = true
        }
    }

    /// The display shown on the iPad, in global points; nil if the layout marks none.
    public private(set) var streamedDisplay: DesktopDisplay?
    /// A `DisplayLayout` has been applied since the last `configure`.
    public private(set) var hasLayout = false

    /// The cursor is on the streamed display (the renderer draws it only then).
    public var cursorOnStream: Bool {
        guard let s = streamedDisplay else { return false }
        return pointer.x >= s.x && pointer.x < s.x + s.width && pointer.y >= s.y && pointer.y < s.y + s.height
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

    /// The keyboard went away (Magic Keyboard detached): GameController sends no key-ups for keys that
    /// were down, so lift them on the Mac now and stop repeating (invariant 4).
    public func keyboardDisconnected() {
        for event in keyboard.releaseAll() { send(.keyEvent(event)) }
        keyRepeat.cancel()
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

    /// A mouse went away (the Magic Keyboard trackpad detached): no button-ups will come for buttons that
    /// were down, so send them now.
    public func mouseDisconnected() {
        for up in heldButtons.releaseAll(x: pointer.x, y: pointer.y, modifiers: keyboard.macModifiers) {
            send(.pointerButton(up))
        }
    }

    /// `CursorWarp` from the Mac overwrites the position (§6.3; global points, any display).
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

    /// A mouse-wheel notch (discrete scroll): passed through with no phase and no momentum, as a
    /// wheel scrolls on the Mac. Stops a running fling.
    public func scrollWheel(dx: Double, dy: Double, at timeNs: UInt64) {
        guard pointerEnabled, dx != 0 || dy != 0 else { return }
        if let stop = momentum.cancel() { send(.scroll(stop)) }
        let (sx, sy) = invertScroll ? (-dx, -dy) : (dx, dy)
        send(.scroll(Scroll(dx: Float(sx), dy: Float(sy), phase: .none, momentumPhase: .none)))
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
