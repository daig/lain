import GameController
import LainClientCore
import UIKit

/// The client's one screen (§6.4, §6.6): captures the Magic Keyboard and trackpad under pointer lock
/// and feeds `ClientInput`, shows the connection state, a local cursor dot (until video exists, M3),
/// and the D19 overlay while the pointer isn't captured. All input logic lives in
/// `ClientInputPipeline`; this class only adapts UIKit and GameController to it.
///
/// GameController handlers are `@Sendable` closures that capture only `input`, and their
/// `handlerQueue` is `input.queue`, so they run on the input queue with no hop and never touch the
/// main actor.
final class StreamViewController: UIViewController, UIGestureRecognizerDelegate {
    let input: ClientInput

    var status = ClientStatus.waitingForMac {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = status.isConnected
            render()
        }
    }

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let overlay = UILabel()
    private let cursorDot = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    private var displayLink: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    private var pointerLocked = false
    private var lastScrollTranslation = CGPoint.zero

    init(input: ClientInput) {
        self.input = input
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
        setUpLabels()
        setUpGestures()
        cursorDot.backgroundColor = .white
        cursorDot.layer.cornerRadius = 5
        cursorDot.layer.borderColor = UIColor.black.cgColor
        cursorDot.layer.borderWidth = 1
        cursorDot.isUserInteractionEnabled = false
        cursorDot.isHidden = true
        view.addSubview(cursorDot)

        input.setPointerEnabled(false)   // D19: nothing from the trackpad until the pointer is locked
        observe()
        GCMouse.mice().forEach(attach(mouse:))
        if let keyboard = GCKeyboard.coalesced { attach(keyboard: keyboard) }

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
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
        overlay.isHidden = pointerLocked
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
    }

    private func pointerLockChanged() {
        let locked = view.window?.windowScene?.pointerLockState?.isLocked ?? false
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
        mouseInput.mouseMovedHandler = { @Sendable _, dx, dy in
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
        keyboard.keyboardInput?.keyChangedHandler = { @Sendable _, _, keyCode, pressed in
            guard let usage = UInt16(exactly: keyCode.rawValue) else { return }
            input.keyChanged(PhysicalKey(usage: usage), isDown: pressed)
        }
    }

    // MARK: UIKit presses: layout characters and Globe (never call super: UIKit must not act on keys)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) { handle(presses, isDown: true) }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) { handle(presses, isDown: false) }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) { handle(presses, isDown: false) }
    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {}

    private func handle(_ presses: Set<UIPress>, isDown: Bool) {
        for press in presses {
            guard let key = press.key else { continue }
            let usage = key.keyCode.rawValue
            if usage == Int(PhysicalKey.globe.usage) {
                input.keyChanged(.globe, isDown: isDown)   // GCKeyboard never reports Globe
            } else if isDown, let u = UInt16(exactly: usage) {
                input.learnCharacter(PhysicalKey(usage: u), key.charactersIgnoringModifiers)
            }
        }
    }

    // MARK: Scroll, pinch, rotate

    private func setUpGestures() {
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrollPan(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []   // trackpad/wheel scroll only, not touch drags
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotate(_:)))
        for recognizer in [scroll, pinch, rotate] as [UIGestureRecognizer] {
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

    // MARK: Display link: momentum, key repeat, cursor dot

    @objc private func tick() {
        input.tick()
        let c = input.cursor
        guard status.isConnected, c.displayPointWidth > 0, c.displayPointHeight > 0 else {
            cursorDot.isHidden = true
            return
        }
        cursorDot.isHidden = false
        let b = view.bounds
        cursorDot.center = CGPoint(x: c.x / c.displayPointWidth * b.width, y: c.y / c.displayPointHeight * b.height)
    }
}
