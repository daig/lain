import GameController
import LainClientCore
import os
import Synchronization
import UIKit

/// The client's one screen (§6.2, §6.4, §6.6): captures the Magic Keyboard and trackpad under pointer
/// lock and feeds `ClientInput`; hosts the stream's `CAMetalLayer`, driven by `StreamRenderLoop`
/// (CAMetalDisplayLink at 120 Hz on its own thread: input tick, newest decoded frame, local cursor);
/// shows the connection state only while there's no video, the D19 overlay while the pointer isn't
/// captured, the panel opened by holding Right Option (lain's system key) alone (`ControlPanel`: the stream's
/// numbers, the hosts, the iPad's options, the shortcuts; it takes the keyboard and trackpad until Esc or a
/// Right Option tap), and a HUD toggled with **Ctrl-Opt-Cmd-L** (matched by the character "l" the iPad layout
/// produces, D18; the combo also reaches the Mac, where nothing uses it by default). The connect detail
/// and the HUD's first line name the transport (USB, or Wi-Fi with its path and interface, §7.7). All
/// input logic lives in `ClientInputPipeline`; this class only adapts UIKit and GameController to it.
///
/// GameController handlers are `@Sendable` closures that capture only `input`, and their
/// `handlerQueue` is `input.queue`, so they run on the input queue with no hop and never touch the
/// main actor.
final class StreamViewController: UIViewController, UIGestureRecognizerDelegate {
    let input: ClientInput
    let video: ClientVideoPipeline
    /// Set once the session exists: the overlay asks it for the Mac's stats while it shows.
    var session: ClientSession?

    var status = ClientStatus.waitingForMac(wifi: false) {
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
    private let panelView = PanelView()
    private var panel = ControlPanel()
    /// The iPad's own options, from the panel.
    private var preferences = ClientPreferences.load()
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
        // lain's own shortcuts are caught in the input pipeline (before anything reaches the Mac).
        input.setLocalShortcutHandler { shortcut in
            Task { @MainActor [weak self] in
                switch shortcut {
                case .toggleHUD: self?.toggleHUD()
                case .overlay(let shown): self?.setPanel(shown)
                case .panelKey(let key): self?.panelKey(key)
                case .panelPointer(let dx, let dy): self?.panelView.moveCursor(dx: dx, dy: dy)
                case .panelClick: self?.panelClick()
                }
            }
        }
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

    /// Back in front (Cmd-Tab, Home and back, Stage Manager). viewDidAppear doesn't run again, so reclaim
    /// key/first-responder status and re-request the pointer lock, which iPadOS grants only to the
    /// focused window in windowed modes. Diagnostics go to stdout (the `ipad.sh` console).
    func sceneBecameActive() {
        diag("scene active")
        view.window?.makeKey()
        becomeFirstResponder()
        setNeedsUpdateOfPrefersPointerLocked()
        pointerLockChanged()
        for delay in [0.25, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.diag("recheck +\(delay)s")
                if !self.pointerLocked { self.setNeedsUpdateOfPrefersPointerLocked() }
                self.pointerLockChanged()
            }
        }
    }

    func diag(_ event: String) {
        let scene = view.window?.windowScene
        let state: String = switch scene?.activationState {
        case .foregroundActive: "active"
        case .foregroundInactive: "inactive"
        case .background: "background"
        default: "?"
        }
        let line = "\(event): scene=\(state) keyWindow=\(view.window?.isKeyWindow ?? false) "
            + "firstResponder=\(isFirstResponder) locked=\(scene?.pointerLockState?.isLocked ?? false)"
        Self.log.notice("\(line, privacy: .public)")
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

        overlay.text = "Click to capture the pointer\nIf it keeps releasing after app switches: Settings › Multitasking & Gestures › Full Screen Apps"
        overlay.font = .systemFont(ofSize: 17, weight: .medium)
        overlay.textColor = .white
        overlay.textAlignment = .center
        overlay.numberOfLines = 0
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
            overlay.heightAnchor.constraint(equalToConstant: 84),
            overlay.widthAnchor.constraint(equalToConstant: 620),
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

        panelView.isHidden = true
        panelView.accessibilityIdentifier = "stream.panel"
        panelView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panelView)
        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panelView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.92),
            panelView.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.92),
        ])
        input.setCurve(preferences.curve)
        input.setInvertScroll(preferences.reverseScroll)

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
        // One reading for both: the rates are since the previous `stats()` call.
        guard !hud.isHidden || !panelView.isHidden else { return }
        let stats = video.stats()
        if !hud.isHidden { hud.text = hudText(stats) }
        if !panelView.isHidden { renderPanel(stats) }
    }

    // MARK: Panel

    /// Opened by holding Right Option alone; the host's stats are asked for while it shows.
    private func setPanel(_ shown: Bool) {
        panelView.isHidden = !shown
        session?.setHostStatsInterval(ms: shown ? ControlPanel.hostStatsIntervalMs : 0)
        if shown {
            renderPanel(video.stats())
            panelView.centerCursor()
        }
    }

    private func renderPanel(_ stats: VideoStats? = nil) {
        var info: ClientSession.ConnectionInfo?
        if case .session(let i) = status { info = i }
        let stats = stats ?? panelView.lastStats
        panelView.lastStats = stats
        panelView.show(panel.lines(info: info, video: stats, host: session?.hostStats, hosts: hostList,
                                   preferences: preferences))
    }

    private var hostList: ClientSession.HostList { session?.hostList() ?? ClientSession.HostList() }

    private func panelKey(_ key: PhysicalKey) {
        apply(panel.key(key, hosts: hostList, preferences: preferences))
    }

    private func panelClick() {
        guard let row = panelView.rowUnderCursor() else { return }
        apply(panel.click(row: row, hosts: hostList, preferences: preferences))
    }

    private func apply(_ action: ControlPanel.Action) {
        switch action {
        case .none:
            break
        case .close:
            input.closePanel()   // the pipeline answers with .overlay(false)
            return
        case .selectHost(let id):
            session?.selectHost(id)
        case .setPreferences(let p):
            preferences = p
            p.save()
            input.setCurve(p.curve)
            input.setInvertScroll(p.reverseScroll)
        }
        renderPanel()
        // The session applies a pick on its queue: show its result once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.panelView.isHidden else { return }
            self.renderPanel()
        }
    }

    private func toggleHUD() {
        hud.isHidden.toggle()
        if !hud.isHidden { hud.text = hudText(video.stats()) }
    }

    /// The link first ("USB · Mac mini · protocol v4"), then whether the Mac's lain is older, then the
    /// video numbers.
    private func hudText(_ stats: VideoStats) -> String {
        var link = "no link"
        if case .session(let info) = status {
            link = ClientStatus.describe(info.transport) + (info.hostName.isEmpty ? "" : " · \(info.hostName)")
                + " · protocol v\(info.protocolVersion)"
            if let note = ClientStatus.olderMacNote(info) { link += "\n" + note }
        }
        return link + "\n" + stats.hudText
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
        on(UIPointerLockState.didChangeNotification) { vc in
            vc.diag("lock state changed")
            vc.pointerLockChanged()
        }
        on(UIWindow.didBecomeKeyNotification) { $0.diag("window became key") }
        on(UIWindow.didResignKeyNotification) { $0.diag("window resigned key") }
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

/// The panel's view: one label per line (so a click finds its row), the selected row highlighted, and a
/// pointer of its own while the panel has the trackpad.
final class PanelView: UIView {
    private let stack = UIStackView()
    private var labels: [UILabel] = []
    private var lines: [ControlPanel.Line] = []
    private let cursor = UIView()
    private var cursorPoint = CGPoint.zero
    /// The last stream numbers shown (a key between two refreshes re-renders with them).
    var lastStats = VideoStats()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.08, alpha: 0.92)
        layer.cornerRadius = 18
        layer.borderWidth = 1
        layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        isUserInteractionEnabled = false
        stack.axis = .vertical
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
        ])
        cursor.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        cursor.layer.cornerRadius = 6
        cursor.backgroundColor = .white
        cursor.layer.borderColor = UIColor.black.cgColor
        cursor.layer.borderWidth = 1.5
        addSubview(cursor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ new: [ControlPanel.Line]) {
        while labels.count < new.count {
            let label = UILabel()
            label.numberOfLines = 1
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            labels.append(label)
            stack.addArrangedSubview(label)
        }
        while labels.count > new.count { labels.removeLast().removeFromSuperview() }
        for (i, (label, line)) in zip(labels, new).enumerated() {
            label.text = line.isSelected ? " " + line.text + " " : " " + line.text
            switch line.style {
            case .title:
                label.font = .systemFont(ofSize: 20, weight: .semibold)
                label.textColor = .white
            case .heading:
                label.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
                label.textColor = UIColor(white: 1, alpha: 0.5)
            case .text:
                label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
                label.textColor = .white
            case .dim:
                label.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
                label.textColor = UIColor(white: 1, alpha: 0.45)
            }
            label.backgroundColor = line.isSelected ? UIColor.systemBlue.withAlphaComponent(0.55) : .clear
            if line.style == .heading, i > 0 { stack.setCustomSpacing(16, after: labels[i - 1]) }
            else if i > 0 { stack.setCustomSpacing(3, after: labels[i - 1]) }
        }
        lines = new
        bringSubviewToFront(cursor)
    }

    func centerCursor() {
        layoutIfNeeded()
        cursorPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        cursor.center = cursorPoint
    }

    /// GameController deltas (y up), at roughly the host's pointer speed.
    func moveCursor(dx: Double, dy: Double) {
        cursorPoint.x = min(max(cursorPoint.x + dx * 1.5, 0), bounds.width)
        cursorPoint.y = min(max(cursorPoint.y - dy * 1.5, 0), bounds.height)
        cursor.center = cursorPoint
    }

    /// The row the panel's pointer is on, if its line acts on one.
    func rowUnderCursor() -> Int? {
        for (label, line) in zip(labels, lines) where line.row != nil {
            let frame = label.convert(label.bounds, to: self).insetBy(dx: -4, dy: -2)
            if frame.contains(cursorPoint) { return line.row }
        }
        return nil
    }
}
