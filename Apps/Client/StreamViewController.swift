import GameController
import LainClientCore
import os
import Synchronization
import UIKit

/// The client's one screen (§6.2, §6.4, §6.6): captures the Magic Keyboard and trackpad under pointer
/// lock and feeds `ClientInput`; hosts the stream's `CAMetalLayer`, driven by `StreamRenderLoop`
/// (CAMetalDisplayLink at 120 Hz on its own thread: input tick, newest decoded frame, local cursor);
/// shows the connection state only while there's no video, the D19 overlay while the pointer isn't
/// captured, and a HUD toggled with **Ctrl-Opt-Cmd-L** (matched by the character "l" the iPad layout
/// produces, D18; the combo also reaches the Mac, where nothing uses it by default). All input logic
/// lives in `ClientInputPipeline`; this class only adapts UIKit and GameController to it.
///
/// GameController handlers are `@Sendable` closures that capture only `input`, and their
/// `handlerQueue` is `input.queue`, so they run on the input queue with no hop and never touch the
/// main actor.
final class StreamViewController: UIViewController, UIGestureRecognizerDelegate {
    let input: ClientInput
    let video: ClientVideoPipeline

    var status = ClientStatus.waitingForMac {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = status.isConnected
            connected.set(status.isConnected)
            render()
        }
    }

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let overlay = UILabel()
    private let hud = UILabel()
    /// Read by the render thread: draw the local cursor only while a session is up.
    private let connected = SharedFlag()
    private var renderLoop: StreamRenderLoop?
    private var uiTimer: Timer?
    private var hasVideo = false
    private var observers: [NSObjectProtocol] = []
    private var pointerLocked = false
    private var lastScrollTranslation = CGPoint.zero
    private var lastWheelTranslation = CGPoint.zero

    init(input: ClientInput, video: ClientVideoPipeline) {
        self.input = input
        self.video = video
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var prefersPointerLocked: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var canBecomeFirstResponder: Bool { true }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark   // secondaryLabel etc. must read on the black stream background
        setUpRendering()
        setUpLabels()
        setUpGestures()

        input.setPointerEnabled(false)   // D19: nothing from the trackpad until the pointer is locked
        observe()
        GCMouse.mice().forEach(attach(mouse:))
        if let keyboard = GCKeyboard.coalesced { attach(keyboard: keyboard) }

        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let layer = renderLoop?.layer else { return }
        // Drawable = the view in pixels: 2752×2064 on the 13" iPad Pro full screen, 1:1 with the stream.
        let scale = traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = view.bounds
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: (view.bounds.width * scale).rounded(), height: (view.bounds.height * scale).rounded())
        CATransaction.commit()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        // A resizable iPadOS 26+ app isn't rotated by supportedInterfaceOrientations alone; ask for landscape.
        // iPadOS 27 refuses this in windowed modes (verified in the simulator); on the Magic Keyboard the
        // iPad is landscape anyway.
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
            // Expected in windowed modes: "does not allow for programmatic changes to interface orientation".
            Self.log.notice("landscape request refused: \(error.localizedDescription, privacy: .public)")
        }
        setNeedsUpdateOfPrefersPointerLocked()
        pointerLockChanged()
    }

    // MARK: Layout

    private func setUpLabels() {
        titleLabel.font = .systemFont(ofSize: 34, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.accessibilityIdentifier = "connect.title"
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.accessibilityIdentifier = "connect.detail"
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center

        overlay.text = "Click to capture the pointer"
        overlay.font = .systemFont(ofSize: 20, weight: .medium)
        overlay.textColor = .white
        overlay.textAlignment = .center
        overlay.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.35)
        overlay.layer.cornerRadius = 12
        overlay.layer.masksToBounds = true
        overlay.accessibilityIdentifier = "stream.captureHint"

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, overlay])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(32, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isUserInteractionEnabled = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            overlay.heightAnchor.constraint(equalToConstant: 52),
            overlay.widthAnchor.constraint(equalToConstant: 360),
        ])
    }

    private func render() {
        guard isViewLoaded else { return }
        titleLabel.text = status.title
        detailLabel.text = status.detail
        titleLabel.isHidden = hasVideo
        detailLabel.isHidden = hasVideo
        overlay.isHidden = pointerLocked
    }

    // MARK: Rendering (M3)

    /// The Metal layer sits behind everything; the render loop's display link also ticks the input
    /// pipeline (momentum, key repeat), replacing M2's CADisplayLink.
    private func setUpRendering() {
        let input = self.input, connected = self.connected
        do {
            let loop = try StreamRenderLoop(
                video: video,
                cursorPosition: {
                    // Full desktop (§6.3): the cursor roams every Mac display; it's drawn here only
                    // while it's on the streamed one, in that display's points.
                    connected.value ? input.cursor.streamedPoint : nil
                },
                displayPointSize: { input.cursor.streamedSize },
                tick: { input.tick() })
            view.layer.addSublayer(loop.layer)
            loop.start()
            renderLoop = loop
        } catch {
            Self.log.error("renderer unavailable: \(String(describing: error), privacy: .public)")
        }

        hud.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        hud.textColor = .white
        hud.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hud.numberOfLines = 0
        hud.isHidden = true
        hud.isUserInteractionEnabled = false
        hud.accessibilityIdentifier = "stream.hud"
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            hud.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
        ])

        // 4 Hz: whether video is up (hides the connect status) and the HUD's numbers.
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVideoState() }
        }
    }

    private func refreshVideoState() {
        let hasVideo = video.hasVideo
        if hasVideo != self.hasVideo {
            self.hasVideo = hasVideo
            render()
        }
        if !hud.isHidden { hud.text = video.stats().hudText }
    }

    private func toggleHUD() {
        hud.isHidden.toggle()
        if !hud.isHidden { hud.text = video.stats().hudText }
    }

    // MARK: Pointer lock (D19)

    private func observe() {
        let center = NotificationCenter.default
        // Handlers take no Notification (it isn't Sendable); mice and the keyboard are re-scanned instead.
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (StreamViewController) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self)
                }
            })
        }
        on(UIPointerLockState.didChangeNotification) { $0.pointerLockChanged() }
        on(.GCMouseDidConnect) { vc in GCMouse.mice().forEach(vc.attach(mouse:)) }
        on(.GCMouseDidBecomeCurrent) { vc in GCMouse.mice().forEach(vc.attach(mouse:)) }
        on(.GCKeyboardDidConnect) { vc in GCKeyboard.coalesced.map(vc.attach(keyboard:)) }
        // Nothing guarantees final ups from a detached Magic Keyboard; lift what it held (invariant 4).
        // The scene stays active and Universal Control mice keep the pointer lock, so nothing else would.
        on(.GCKeyboardDidDisconnect) { $0.input.keyboardDisconnected() }
        on(.GCMouseDidDisconnect) { $0.input.mouseDisconnected() }
    }

    private static let log = Logger(subsystem: "lain", category: "client")

    private func pointerLockChanged() {
        let state = view.window?.windowScene?.pointerLockState
        let locked = state?.isLocked ?? false
        Self.log.notice("pointer lock: \(state == nil ? "no state" : (locked ? "locked" : "unlocked"), privacy: .public)")
        guard locked != pointerLocked else { return }
        pointerLocked = locked
        if locked {
            input.setPointerEnabled(true)
        } else {
            input.setPointerEnabled(false)
            input.releaseAll(.pointerLockLost)   // invariant 4
        }
        render()
    }

    // MARK: GameController (runs on the input queue)

    /// Every mouse gets handlers; iPadOS 27 lists Universal Control virtual mice besides the trackpad,
    /// and whichever the user touches drives the one cursor. GCMouse scroll is ignored (§6.4).
    private func attach(mouse: GCMouse) {
        mouse.handlerQueue = input.queue
        guard let mouseInput = mouse.mouseInput else { return }
        let input = self.input
        let cursor = video.cursor
        mouseInput.mouseMovedHandler = { @Sendable _, dx, dy in
            cursor.pointerMoved()   // shows the cursor again after typing (§5.4)
            input.mouseMoved(dx: Double(dx), dy: Double(dy))
        }
        let buttons: [(MouseButton, GCControllerButtonInput?)] = [
            (.left, mouseInput.leftButton), (.right, mouseInput.rightButton), (.other, mouseInput.middleButton),
        ]
        for (button, control) in buttons {
            control?.pressedChangedHandler = { @Sendable _, _, pressed in
                input.mouseButton(button, isDown: pressed)
            }
        }
    }

    /// GCKeyboard reports physical HID positions on page 7 (`GCKeyCode.rawValue` is the usage).
    private func attach(keyboard: GCKeyboard) {
        keyboard.handlerQueue = input.queue
        let input = self.input
        let cursor = video.cursor
        keyboard.keyboardInput?.keyChangedHandler = { @Sendable _, _, keyCode, pressed in
            guard let usage = UInt16(exactly: keyCode.rawValue) else { return }
            // Hide while typing: any non-modifier key-down hides the cursor until the pointer moves.
            if pressed, !(0xE0...0xE7).contains(usage) { cursor.keyDown() }
            input.keyChanged(PhysicalKey(usage: usage), isDown: pressed)
        }
    }

    // MARK: UIKit presses: layout characters and Globe (never call super: UIKit must not act on keys)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { handle(presses, isDown: true) }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { handle(presses, isDown: false) }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { handle(presses, isDown: false) }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

    /// Ctrl-Opt-Cmd-L, by the character the iPad layout produces (D18; Colemak "l" is QWERTY "U").
    private static func isHUDShortcut(_ key: UIKey) -> Bool {
        let mods = key.modifierFlags.intersection([.control, .alternate, .command, .shift])
        return mods == [.control, .alternate, .command] && key.charactersIgnoringModifiers.lowercased() == "l"
    }

    private func handle(_ presses: Set<UIPress>, isDown: Bool) {
        for press in presses {
            guard let key = press.key else { continue }
            let usage = key.keyCode.rawValue
            if usage == Int(PhysicalKey.globe.usage) {
                input.keyChanged(.globe, isDown: isDown)   // GCKeyboard never reports Globe
            } else if isDown, let u = UInt16(exactly: usage) {
                input.learnCharacter(PhysicalKey(usage: u), key.charactersIgnoringModifiers)
                if Self.isHUDShortcut(key) { toggleHUD() }
            }
        }
    }

    // MARK: Scroll, pinch, rotate

    private func setUpGestures() {
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrollPan(_:)))
        scroll.allowedScrollTypesMask = .continuous   // trackpad: phases and synthesized momentum
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheelPan(_:)))
        wheel.allowedScrollTypesMask = .discrete      // mouse wheel: plain deltas, no momentum
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotate(_:)))
        // Trackpad and wheel only: no touchscreen drags, pinches or rotations (§6.4: touch is off by
        // default). Scroll pans take no touches at all (verified, §13); pinch and rotate keep only
        // indirect-pointer input, which carries trackpad transform gestures.
        scroll.allowedTouchTypes = []
        wheel.allowedTouchTypes = []
        let trackpadOnly = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pinch.allowedTouchTypes = trackpadOnly
        rotate.allowedTouchTypes = trackpadOnly
        for recognizer in [scroll, wheel, pinch, rotate] as [UIGestureRecognizer] {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Pan translation becomes per-event deltas, passed through unchanged (§6.4).
    @objc private func scrollPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        switch g.state {
        case .began:
            lastScrollTranslation = .zero
            input.scrollBegan()
            scrollDelta(to: t)
        case .changed:
            scrollDelta(to: t)
        case .ended:
            scrollDelta(to: t)
            input.scrollEnded()
        case .cancelled, .failed:
            input.scrollCancelled()
        default:
            break
        }
    }

    private func scrollDelta(to t: CGPoint) {
        let dx = t.x - lastScrollTranslation.x, dy = t.y - lastScrollTranslation.y
        lastScrollTranslation = t
        if dx != 0 || dy != 0 { input.scrollChanged(dx: Double(dx), dy: Double(dy)) }
    }

    /// Wheel notches: translation deltas with no phases or momentum.
    @objc private func wheelPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: view)
        if g.state == .began { lastWheelTranslation = .zero }
        guard g.state == .began || g.state == .changed || g.state == .ended else { return }
        let dx = t.x - lastWheelTranslation.x, dy = t.y - lastWheelTranslation.y
        lastWheelTranslation = t
        input.scrollWheel(dx: Double(dx), dy: Double(dy))
    }

    /// The pinch recognizer's scale at the previous event (1 at `.began`).
    private var lastPinchScale: CGFloat = 1

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        guard let phase = Self.phase(g.state) else { return }
        // Wire contract (§6.4): value = change in the gesture's absolute scale since the previous event,
        // so the host's 1 + Σ value is the recognizer's scale. (Resetting `scale` to 1 each event would
        // send ratios instead, which sum to ln(scale).)
        if phase == .began { lastPinchScale = 1 }
        let value = Float(g.scale - lastPinchScale)
        lastPinchScale = g.scale
        input.gesture(.magnify, phase: phase, value: phase == .began || phase == .changed ? value : 0)
    }

    @objc private func rotate(_ g: UIRotationGestureRecognizer) {
        guard let phase = Self.phase(g.state) else { return }
        let value = Float(g.rotation)   // incremental radians since the last event
        g.rotation = 0
        input.gesture(.rotate, phase: phase, value: phase == .began || phase == .changed ? value : 0)
    }

    private static func phase(_ state: UIGestureRecognizer.State) -> GesturePhase? {
        switch state {
        case .began: .began
        case .changed: .changed
        case .ended: .ended
        case .cancelled, .failed: .cancelled
        default: nil
        }
    }
}

/// A Bool shared between the main actor (writer) and the render thread (reader).
final class SharedFlag: Sendable {
    private let state = Atomic<Bool>(false)
    var value: Bool { state.load(ordering: .relaxed) }
    func set(_ value: Bool) { state.store(value, ordering: .relaxed) }
}
