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
    /// Multiplies scroll deltas (trackpad and wheel; the trackpad's momentum follows them). 1: as the iPad
    /// reports them.
    public var scrollScale = 1.0
    /// D19: pointer input (moves, button-downs, scroll, gestures) flows only while this is set, which the
    /// capture layer ties to the pointer lock. Keyboard input flows regardless. Button-ups for buttons
    /// already down still pass so nothing sticks.
    public var pointerEnabled = true
    /// Pointer input may flow: the pointer is locked, or the input is a touch on the screen (which needs no
    /// lock: D19 keeps the trackpad from driving two pointers, and a finger drives none of iPadOS's).
    private var pointerAllowed: Bool { pointerEnabled || applyingTouch }
    private var applyingTouch = false

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

    /// lain's own shortcuts, handled on the iPad and never sent to the Mac (the Mac would beep).
    public enum LocalShortcut: Sendable, Equatable {
        /// Ctrl-Opt-Cmd-L: show/hide the HUD.
        case toggleHUD
        /// Right Option, lain's system key, held alone for `overlayHoldNs`: the panel opens (true). It stays
        /// open, taking the keyboard and trackpad, until `closePanel()` or a Right Option tap (false).
        case overlay(Bool)
        /// While the panel is open: a key-down (never sent to the host).
        case panelKey(PhysicalKey)
        /// While the panel is open: the trackpad moved (GameController deltas, y up) or clicked.
        case panelPointer(dx: Double, dy: Double)
        case panelClick
    }

    /// How long Right Option must be held alone to show the overlay: longer than the hosts' longest tap
    /// (300 ms, `SystemKey.tapMaxNs`), so a hold that shows it never opens Mission Control on release.
    public static let overlayHoldNs: UInt64 = 350_000_000
    /// Right Option went down alone and nothing else came since (the panel is due at this + hold).
    private var systemKeyDownAtNs: UInt64?
    /// The panel is open: the keyboard and trackpad drive it, and nothing reaches the host.
    public private(set) var overlayShown = false
    /// The Right Option press that opened the panel is still down: its release goes to the host (which saw
    /// the press), and isn't a tap.
    private var openingPressHeld = false
    /// Right Option went down while the panel was open, nothing else since: its release closes the panel.
    private var closeTapArmed = false

    /// Before the panel opens: a Right Option hold alone is timed (`tick`); anything else cancels it, since
    /// Right Option + a key is a chord for the host. Every key still goes to the host unchanged.
    private func watchSystemKey(_ key: PhysicalKey, isDown: Bool, at timeNs: UInt64) {
        if key == .rightOption, isDown {
            // Alone: no other key held (a modifier, or the Left Option that makes it plain Option).
            systemKeyDownAtNs = keyboard.physicalModifiers.isEmpty && keyboard.macHeldKeys.isEmpty ? timeNs : nil
            return
        }
        if key == .rightOption || isDown { systemKeyDownAtNs = nil }
    }

    /// While the panel is open: true if the key was the panel's (not sent to the host).
    private func panelKey(_ key: PhysicalKey, isDown: Bool) -> Bool {
        if key == .rightOption {
            if isDown {
                closeTapArmed = true
                consumedKeys.insert(key)
                return true
            }
            if openingPressHeld {
                openingPressHeld = false
                return false   // the host lifts the Right Option it saw go down
            }
            consumedKeys.remove(key)
            if closeTapArmed { closePanel() }
            return true
        }
        if isDown {
            closeTapArmed = false
            consumedKeys.insert(key)
            onLocalShortcut(.panelKey(key))
            return true
        }
        return consumedKeys.remove(key) != nil
    }

    /// Opens the panel without the keyboard (the touch menu). Nothing is held, so nothing is owed to the host.
    public func openPanel(at timeNs: UInt64) {
        guard !overlayShown else { return }
        systemKeyDownAtNs = nil
        overlayShown = true
        openingPressHeld = false
        closeTapArmed = false
        keyRepeat.cancel()
        apply(touch.cancelled(), at: timeNs)
        onLocalShortcut(.overlay(true))
    }

    /// Closes the panel (Esc in it, a Right Option tap, a lost focus): input goes to the host again.
    public func closePanel() {
        systemKeyDownAtNs = nil
        closeTapArmed = false
        guard overlayShown else { return }
        overlayShown = false
        onLocalShortcut(.overlay(false))
    }

    /// Called on the input queue when a local shortcut fires.
    public var onLocalShortcut: (LocalShortcut) -> Void = { _ in }
    /// Keys whose down was taken by a local shortcut; their up is swallowed too.
    private var consumedKeys: Set<PhysicalKey> = []

    /// The shortcut a key-down triggers, matched by the layout's character (D18: Colemak "l" is on the
    /// key labelled U). The modifiers themselves still reach the Mac, which ignores them alone.
    private func localShortcut(for key: PhysicalKey) -> LocalShortcut? {
        guard !key.isModifier,
              keyboard.physicalModifiers.intersection([.shift, .control, .option, .command]) == [.control, .option, .command]
        else { return nil }
        return keyboard.layout.character(for: key) == "l" ? .toggleHUD : nil
    }

    /// A physical key changed (GCKeyboard usage, or Globe from UIKit).
    public func keyChanged(_ key: PhysicalKey, isDown: Bool, at timeNs: UInt64) {
        if overlayShown {
            if panelKey(key, isDown: isDown) { return }
        } else {
            watchSystemKey(key, isDown: isDown, at: timeNs)
        }
        if isDown, let shortcut = localShortcut(for: key) {
            consumedKeys.insert(key)
            onLocalShortcut(shortcut)
            return
        }
        if !isDown, consumedKeys.remove(key) != nil { return }
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

    // MARK: Text

    /// Text for the host to type (v6 `TextInput`: the on-screen keyboard, dictation), with `modifiers` held
    /// if any. The caller sends it only to a host with `ProtocolFeature.textInput`.
    public func typeText(_ text: String, modifiers: ModifierFlags = []) {
        guard !overlayShown else { return }
        for message in TextInput.split(text, modifiers: modifiers) { send(.textInput(message)) }
    }

    // MARK: Pointer

    /// A GCMouse delta (y up-positive). Zero deltas are ignored.
    public func mouseMoved(dx: Double, dy: Double, at timeNs: UInt64) {
        guard pointerEnabled else { return }
        if overlayShown { return onLocalShortcut(.panelPointer(dx: dx, dy: dy)) }
        guard let move = pointer.move(dx: dx, dy: dy, at: timeNs, buttons: heldButtons.mask) else { return }
        send(.pointerMove(move))
    }

    public func mouseButton(_ button: MouseButton, isDown: Bool, at timeNs: UInt64) {
        if isDown {
            systemKeyDownAtNs = nil   // a click with Right Option held is a Command-click on the host
            if overlayShown {
                if pointerEnabled { onLocalShortcut(.panelClick) }
                return
            }
            guard pointerAllowed, heldButtons.set(button, down: true) else { return }
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

    // MARK: Touch screen

    public private(set) var touch = TouchGestures()
    /// The size of the view the stream fills (points). The stream is aspect-fit in it, as the renderer draws it.
    public var touchSurface: (width: Double, height: Double) = (0, 0)

    public var touchMode: TouchMode { touch.mode }
    public func setTouchMode(_ mode: TouchMode, at timeNs: UInt64) { apply(touch.setMode(mode), at: timeNs) }

    /// A finger on the screen (`id` names it until it lifts; x and y in the view's points, y down). Not while
    /// the panel is open: the view gives its taps to the panel.
    public func touchBegan(id: Int, x: Double, y: Double, at timeNs: UInt64) {
        guard !overlayShown else { return }
        apply(touch.began(id: id, x: x, y: y, at: timeNs), at: timeNs)
    }

    public func touchMoved(id: Int, x: Double, y: Double, at timeNs: UInt64) {
        apply(touch.moved(id: id, x: x, y: y, at: timeNs), at: timeNs)
    }

    public func touchEnded(id: Int, at timeNs: UInt64) { apply(touch.ended(id: id, at: timeNs), at: timeNs) }

    /// The system took the touches (an edge gesture, an alert).
    public func touchesCancelled(at timeNs: UInt64) { apply(touch.cancelled(), at: timeNs) }

    /// The host point under a point of the view: the streamed display, aspect-fit and centred in the surface.
    func hostPoint(surfaceX: Double, surfaceY: Double) -> (x: Double, y: Double)? {
        guard let s = streamedDisplay, s.width > 0, s.height > 0, touchSurface.width > 0, touchSurface.height > 0 else { return nil }
        let scale = min(touchSurface.width / s.width, touchSurface.height / s.height)
        let (w, h) = (s.width * scale, s.height * scale)
        let u = (surfaceX - (touchSurface.width - w) / 2) / w, v = (surfaceY - (touchSurface.height - h) / 2) / h
        return s.clamped(x: s.x + u * s.width, y: s.y + v * s.height)
    }

    private func apply(_ actions: [TouchGestures.Action], at timeNs: UInt64) {
        guard !actions.isEmpty else { return }
        applyingTouch = true
        defer { applyingTouch = false }
        for action in actions {
            switch action {
            case .moveTo(let x, let y):
                guard let p = hostPoint(surfaceX: x, surfaceY: y),
                      let move = pointer.moveTo(x: p.x, y: p.y, buttons: heldButtons.mask) else { continue }
                send(.pointerMove(move))
            case .moveBy(let dx, let dy):
                // The tracker takes GCMouse deltas (y up) and applies the pointer-speed curve.
                guard let move = pointer.move(dx: dx, dy: -dy, at: timeNs, buttons: heldButtons.mask) else { continue }
                send(.pointerMove(move))
            case .button(let button, let isDown): mouseButton(button, isDown: isDown, at: timeNs)
            case .scrollBegan: scrollBegan(at: timeNs)
            case .scroll(let dx, let dy): scrollChanged(dx: dx, dy: dy, at: timeNs)
            case .scrollEnded: scrollEnded(at: timeNs)
            case .scrollCancelled: scrollCancelled(at: timeNs)
            }
        }
    }

    // MARK: Scroll

    /// Fingers touched down for a scroll (pan `.began`). Stops any running momentum.
    public func scrollBegan(at timeNs: UInt64) {
        guard pointerAllowed, !overlayShown else { return }   // the panel takes the trackpad
        if let stop = momentum.touchBegan(at: timeNs) { send(.scroll(stop)) }
        isScrolling = true
        scrollStarted = false
    }

    /// A scroll delta in points since the previous one (pan translation delta, passed through as is).
    public func scrollChanged(dx: Double, dy: Double, at timeNs: UInt64) {
        guard pointerAllowed, !overlayShown else { return }
        if !isScrolling { scrollBegan(at: timeNs) }
        guard dx != 0 || dy != 0 else { return }
        let k = invertScroll ? -scrollScale : scrollScale
        let (sx, sy) = (dx * k, dy * k)
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
        guard pointerAllowed, !overlayShown, dx != 0 || dy != 0 else { return }
        if let stop = momentum.cancel() { send(.scroll(stop)) }
        let k = invertScroll ? -scrollScale : scrollScale
        let (sx, sy) = (dx * k, dy * k)
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
        guard (pointerEnabled && !overlayShown) || phase == .ended || phase == .cancelled else { return }
        send(.gesture(Gesture(kind: kind, phase: phase, value: value)))
    }

    // MARK: Time

    /// Call at the display rate (~120 Hz): advances momentum and emits due key repeats.
    public func tick(at timeNs: UInt64) {
        if let scroll = momentum.tick(at: timeNs) { send(.scroll(scroll)) }
        if let repeated = keyRepeat.tick(at: timeNs) { send(.keyEvent(repeated)) }
        apply(touch.tick(at: timeNs), at: timeNs)
        if let down = systemKeyDownAtNs, !overlayShown, timeNs &- down >= Self.overlayHoldNs, timeNs >= down {
            systemKeyDownAtNs = nil
            overlayShown = true
            openingPressHeld = true
            closeTapArmed = false
            keyRepeat.cancel()
            apply(touch.cancelled(), at: timeNs)   // the panel takes the screen too
            onLocalShortcut(.overlay(true))
        }
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
        openingPressHeld = false
        closePanel()
        _ = heldButtons.releaseAll(x: pointer.x, y: pointer.y)
        touch.reset()
        keyRepeat.cancel()
        clicks.reset()
        momentum = MomentumSynthesizer(config: momentum.config)
        isScrolling = false
        scrollStarted = false
    }
}
