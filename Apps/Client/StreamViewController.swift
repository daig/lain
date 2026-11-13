import GameController
import LainClientCore
import os
import Synchronization
import UIKit
import UniformTypeIdentifiers

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
    /// Set once the session exists: the panel asks it for the host's stats while it shows, and it takes the
    /// iPad's Wi-Fi path and radio priority.
    var session: ClientSession? {
        didSet { session?.setNetwork(path: preferences.wifiPath, radioPriority: preferences.radioPriority) }
    }

    var status = ClientStatus.waitingForMac(wifi: false) {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = status.isConnected
            connected.set(status.isConnected)
            render()
            if isViewLoaded { updateInputMode() }
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
    /// The system keyboard's typing, for the host (no Magic Keyboard).
    private let keyCapture = KeyCaptureView()
    /// The small button that opens the touch menu; shown while there is no hardware keyboard.
    private let menuButton = UIButton(type: .system)
    /// How much of the view's bottom the docked system keyboard covers: the stream is fitted above it.
    private var keyboardInset: CGFloat = 0
    /// The streamed display's width over its height (0 until known), to place the stream in portrait.
    private var streamAspect: CGFloat = 0
    private var isPortrait: Bool { view.bounds.height > view.bounds.width }
    /// The keyboard is up because the iPad is in portrait (and goes away when it no longer is).
    private var keyboardIsAutomatic = false
    /// How many characters each dictated phrase typed, newest last: the transcript's Delete key takes one back.
    private var dictatedPhrases: [Int] = []
    private let dictationBar = UIStackView()
    /// Portrait, between the stream and the keyboard: more keys, and a trackpad strip that takes what is left.
    private let band = UIView()
    private let trackpad = TrackpadStrip()
    /// Landscape without a hardware keyboard: a small trackpad patch in each bottom corner, under the thumbs.
    private let cornerPads = [TrackpadStrip(corner: .layerMaxXMinYCorner), TrackpadStrip(corner: .layerMinXMinYCorner)]
    private static let cornerPadSize = CGSize(width: 150, height: 120)
    private lazy var extraKeys = ExtraKeys(pasteTarget: self)
    /// Where the transcript sits: at the top of the band in portrait, above the keyboard otherwise.
    private var transcriptInBand: NSLayoutConstraint?
    private var transcriptAboveKeyboard: NSLayoutConstraint?
    /// Dictation on the iPad, typed on the host; `dictationPill` shows it and stops it.
    private let dictation = Dictation()
    private let dictationPill = UIButton(type: .system)
    /// When Globe last went down, for the double-tap that toggles dictation; and whether that press was taken.
    private var lastGlobeDownNs: UInt64 = 0
    private var globeTaken = false
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
    /// Landscape is the display; portrait is the handheld layout, with the keyboard below the stream.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
    override var canBecomeFirstResponder: Bool { true }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true   // two-finger scroll and right-click on the screen
        overrideUserInterfaceStyle = .dark   // secondaryLabel etc. must read on the black stream background
        setUpRendering()
        setUpLabels()
        setUpGestures()
        setUpTouchKeyboard()
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.plainText.identifier])

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
        // The stream fills the view, or what the docked system keyboard leaves of it. In portrait it sits at the
        // top at its own shape, which leaves a band above the keyboard for the dictation transcript.
        var stream = view.bounds
        stream.size.height = max(stream.height - keyboardInset, 1)
        if isPortrait, streamAspect > 0 {
            let width = min(stream.width, stream.height * streamAspect)
            stream = CGRect(x: ((view.bounds.width - width) / 2).rounded(), y: 0, width: width.rounded(), height: (width / streamAspect).rounded())
        }
        updateInputMode()
        layoutBand(under: stream)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = stream
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: (stream.width * scale).rounded(), height: (stream.height * scale).rounded())
        CATransaction.commit()
        input.setTouchSurface(width: stream.width, height: stream.height)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
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
        updateInputMode()
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
        overlay.isHidden = pointerLocked || GCMouse.mice().isEmpty   // nothing to capture without a trackpad
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
        input.setScrollScale(preferences.scrollScale)
        input.setInvertScroll(preferences.reverseScroll)
        input.setTouchMode(preferences.touchMode)

        // 4 Hz: whether video is up (hides the connect status) and the HUD's numbers.
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVideoState() }
        }
    }

    private func refreshVideoState() {
        let cursor = input.cursor
        let aspect = cursor.displayPointHeight > 0 ? CGFloat(cursor.displayPointWidth / cursor.displayPointHeight) : 0
        if aspect != streamAspect {
            streamAspect = aspect
            view.setNeedsLayout()
        }
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
        if shown { setTouchKeyboard(false) } else { updateInputMode() }
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
            input.setScrollScale(p.scrollScale)
            input.setInvertScroll(p.reverseScroll)
            input.setTouchMode(p.touchMode)
            session?.setNetwork(path: p.wifiPath, radioPriority: p.radioPriority)
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
        on(.GCKeyboardDidConnect) { vc in
            GCKeyboard.coalesced.map(vc.attach(keyboard:))
            vc.hardwareKeyboardChanged()
        }
        on(.GCKeyboardDidDisconnect) { $0.hardwareKeyboardChanged() }
        on(.GCMouseDidConnect) { $0.render() }
        on(.GCMouseDidDisconnect) { $0.render() }
        on(UIResponder.keyboardWillChangeFrameNotification) { vc in vc.keyboardFrameChanged() }
        on(UIResponder.keyboardDidChangeFrameNotification) { vc in vc.keyboardFrameChanged() }
        on(UIResponder.keyboardDidHideNotification) { vc in vc.keyboardFrameChanged(hidden: true) }
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
                // A second Globe press soon after the first toggles dictation (as fn twice does on a Mac) and
                // isn't sent on, so the host sees one tap and doesn't start its own.
                if isDown {
                    let now = DispatchTime.now().uptimeNanoseconds
                    globeTaken = now - lastGlobeDownNs < 450_000_000
                    lastGlobeDownNs = globeTaken ? 0 : now
                    if globeTaken { toggleDictation() }
                }
                if globeTaken {
                    if !isDown { globeTaken = false }
                    continue
                }
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
        // Trackpad and wheel only. Fingers on the screen don't go through recognizers: the view's raw touches
        // feed the input pipeline's `TouchGestures` (below). Scroll pans take no touches at all (verified,
        // §13); pinch and rotate keep only indirect-pointer input, which carries trackpad transform gestures.
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

    // MARK: Keyboard without a keyboard

    // Input follows the configuration (no hardware keyboard in the first two):
    // - landscape: dictation. The edge button is a microphone: a tap starts and stops dictating; holding it
    //   opens a menu with the system keyboard (for what can't be dictated) and the panel.
    // - portrait: the system keyboard is always up below the stream, and its key row has the microphone and
    //   the panel; no button floats over the stream.
    // - hardware keyboard: nothing on screen; Globe twice dictates, Right Option held opens the panel.

    private var hostTypes: Bool {
        if case .session(let info) = status { return ProtocolFeature.textInput.isSupported(at: info.protocolVersion) }
        return false
    }

    private func setUpTouchKeyboard() {
        keyCapture.frame = .zero
        view.addSubview(keyCapture)
        keyCapture.onText = { [weak self] text in
            guard let self else { return }
            self.input.typeText(text, modifiers: self.keyCapture.keyRow.takeModifiers())
        }
        keyCapture.onBackspace = { [weak self] in self?.tapKey(.key(0x2A)) }   // HID Delete (Backspace)
        keyCapture.keyRow.onKey = { [weak self] key in self?.tapKey(key) }
        keyCapture.keyRow.onHide = { [weak self] in self?.setTouchKeyboard(false) }
        keyCapture.keyRow.onDictate = { [weak self] in self?.toggleDictation() }
        keyCapture.keyRow.onSettings = { [weak self] in self?.input.openPanel() }
        setUpBand()
        setUpDictation()

        menuButton.setImage(UIImage(systemName: "mic"), for: .normal)
        menuButton.tintColor = .white
        menuButton.backgroundColor = UIColor(white: 0.1, alpha: 0.55)
        menuButton.layer.cornerRadius = 24
        menuButton.layer.borderWidth = 1
        menuButton.layer.borderColor = UIColor(white: 1, alpha: 0.2).cgColor
        menuButton.accessibilityLabel = "Dictate"
        menuButton.accessibilityHint = "Touch and hold for the keyboard and settings"
        menuButton.addAction(UIAction { [weak self] _ in self?.toggleDictation() }, for: .touchUpInside)
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.touchMenu() ?? [])
        }])
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(menuButton)
        NSLayoutConstraint.activate([
            menuButton.widthAnchor.constraint(equalToConstant: 48),
            menuButton.heightAnchor.constraint(equalToConstant: 48),
            menuButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            menuButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        updateInputMode()
    }

    /// The edge button's menu (touch and hold).
    private func touchMenu() -> [UIMenuElement] {
        let showing = keyCapture.isFirstResponder
        let keyboard = UIAction(title: showing ? "Hide Keyboard" : "Keyboard",
                                subtitle: hostTypes ? nil : (status.isConnected ? "Update lain on the host first" : "Not connected"),
                                image: UIImage(systemName: showing ? "keyboard.chevron.compact.down" : "keyboard"),
                                attributes: hostTypes ? [] : .disabled) { [weak self] _ in self?.setTouchKeyboard(!showing) }
        let settings = UIAction(title: "Settings", image: UIImage(systemName: "slider.horizontal.3")) { [weak self] _ in
            self?.input.openPanel()
        }
        return [keyboard, settings]
    }

    private func setTouchKeyboard(_ shown: Bool) {
        if shown { keyCapture.becomeFirstResponder() } else if keyCapture.isFirstResponder { becomeFirstResponder() }
        if !shown { keyboardIsAutomatic = false }
    }

    /// Applies the configuration: which controls show, and whether the keyboard is up on its own.
    private func updateInputMode() {
        let hasKeyboard = GCKeyboard.coalesced != nil
        let portrait = isPortrait
        menuButton.isHidden = hasKeyboard || portrait
        keyCapture.keyRow.setCanHide(!portrait)
        if hasKeyboard {
            // The view that takes the system keyboard's typing would take the hardware keys' too, which
            // GameController already sends.
            setTouchKeyboard(false)
        } else if portrait {
            if hostTypes, panelView.isHidden, !keyCapture.isFirstResponder, view.window != nil {
                keyboardIsAutomatic = keyCapture.becomeFirstResponder()
            }
        } else if keyboardIsAutomatic {
            setTouchKeyboard(false)   // back in landscape: dictation only, the keyboard on request
        }
    }

    private func hardwareKeyboardChanged() { updateInputMode() }

    /// One press of a key that isn't a character, with the key row's lit modifiers held around it.
    private func tapKey(_ key: PhysicalKey) {
        let lit = keyCapture.keyRow.takeModifiers()
        let held: [PhysicalKey] = [(ModifierFlags.control, PhysicalKey.leftControl), (.option, .leftOption), (.command, .leftCommand)]
            .filter { lit.contains($0.0) }.map(\.1)
        for modifier in held { input.keyChanged(modifier, isDown: true) }
        input.keyChanged(key, isDown: true)
        input.keyChanged(key, isDown: false)
        for modifier in held.reversed() { input.keyChanged(modifier, isDown: false) }
    }

    /// The docked keyboard covers the bottom of the view; a floating one (or none) covers nothing to make room for.
    private func keyboardFrameChanged(hidden: Bool = false) {
        var inset: CGFloat = 0
        if !hidden, keyCapture.isFirstResponder {
            let frame = view.keyboardLayoutGuide.layoutFrame
            if frame.width >= view.bounds.width - 1, frame.maxY >= view.bounds.maxY - 1 { inset = max(view.bounds.maxY - frame.minY, 0) }
        }
        guard inset != keyboardInset else { return }
        keyboardInset = inset
        view.setNeedsLayout()
    }

    // MARK: The band (portrait)

    /// Under the stream in portrait there is room the stream's shape leaves: a row of the keys the keyboard's
    /// row lacks, and below it a trackpad strip, so the pointer has a precise mode under the thumbs while the
    /// (smaller) stream stays direct.
    private func setUpBand() {
        band.isHidden = true
        view.addSubview(band)
        extraKeys.onKey = { [weak self] key in self?.tapKey(key) }
        let input = self.input, cursor = video.cursor
        // Every trackpad area feeds the one pad: a thumb on each corner is its two fingers. A finger's travel is
        // all that matters, so each area reporting in its own coordinates is fine.
        for pad in [trackpad] + cornerPads {
            pad.onBegan = { id, p in
                cursor.pointerMoved()
                input.padTouchBegan(id: id, x: p.x, y: p.y)
            }
            pad.onMoved = { id, p in input.padTouchMoved(id: id, x: p.x, y: p.y) }
            pad.onEnded = { id in input.padTouchEnded(id: id) }
            pad.onCancelled = { input.padTouchesCancelled() }
        }
        for pad in cornerPads {
            pad.isHidden = true
            view.insertSubview(pad, belowSubview: band)
        }
        for v in [extraKeys, trackpad] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            band.addSubview(v)
        }
        NSLayoutConstraint.activate([
            extraKeys.topAnchor.constraint(equalTo: band.topAnchor),
            extraKeys.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            extraKeys.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            extraKeys.heightAnchor.constraint(equalToConstant: 38),
            trackpad.topAnchor.constraint(equalTo: extraKeys.bottomAnchor, constant: 8),
            trackpad.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            trackpad.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            trackpad.bottomAnchor.constraint(equalTo: band.bottomAnchor),
        ])
    }

    /// The band fills what is between the stream and the keyboard (or the bottom of the screen), in portrait
    /// without a hardware keyboard, when that is enough for the keys and a usable strip.
    private func layoutBand(under stream: CGRect) {
        let bottom = view.bounds.maxY - max(keyboardInset, view.safeAreaInsets.bottom)
        let frame = CGRect(x: 8, y: stream.maxY + 8, width: view.bounds.width - 16, height: bottom - stream.maxY - 16)
        let shown = isPortrait && streamAspect > 0 && GCKeyboard.coalesced == nil && frame.height >= 110
        if shown { band.frame = frame }
        if band.isHidden == shown {
            band.isHidden = !shown
            if !shown { input.padTouchesCancelled() }
        }
        // Landscape: the corner patches, at the bottom of the stream (above a docked keyboard).
        let corners = !isPortrait && GCKeyboard.coalesced == nil
        let size = Self.cornerPadSize, y = view.bounds.maxY - keyboardInset - size.height
        cornerPads[0].frame = CGRect(x: 0, y: y, width: size.width, height: size.height)
        cornerPads[1].frame = CGRect(x: view.bounds.maxX - size.width, y: y, width: size.width, height: size.height)
        for pad in cornerPads where pad.isHidden == corners {
            pad.isHidden = !corners
            if !corners { input.padTouchesCancelled() }
        }
        // The transcript: at the top of the band when there is one.
        if shown {
            transcriptAboveKeyboard?.isActive = false
            transcriptInBand?.isActive = true
        } else {
            transcriptInBand?.isActive = false
            transcriptAboveKeyboard?.isActive = true
        }
    }

    /// The band's Paste button (the system's paste control, which reads the clipboard without a prompt): the
    /// iPad's clipboard text is typed on the host.
    override func paste(itemProviders: [NSItemProvider]) {
        guard hostTypes, let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, !text.isEmpty else { return }
            Task { @MainActor [weak self] in self?.input.typeText(text) }
        }
    }

    // MARK: Dictation

    /// What is being heard shows in a pill above the keyboard (in portrait, in the band under the stream), with
    /// two keys voice can't press: Delete (takes back the last phrase typed, then single characters) and
    /// Return. Final phrases are typed on the host as they come. Started with the edge button, the key row's
    /// microphone, or Globe twice on a hardware keyboard; stopped the same way or by a tap on the pill.
    private func setUpDictation() {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = UIColor(white: 0.08, alpha: 0.9)
        config.baseForegroundColor = .white
        config.image = UIImage(systemName: "mic.fill")
        config.imagePadding = 8
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        config.titleLineBreakMode = .byTruncatingHead
        dictationPill.configuration = config
        dictationPill.titleLabel?.numberOfLines = 3
        dictationPill.addAction(UIAction { [weak self] _ in self?.dictation.stop() }, for: .touchUpInside)
        dictationPill.accessibilityHint = "Stops dictating"

        func key(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            var c = UIButton.Configuration.filled()
            c.baseBackgroundColor = UIColor(white: 0.08, alpha: 0.9)
            c.baseForegroundColor = .white
            c.image = UIImage(systemName: symbol)
            c.cornerStyle = .large
            c.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
            let b = UIButton(configuration: c, primaryAction: UIAction { _ in action() })
            b.accessibilityLabel = label
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            return b
        }
        dictationBar.axis = .horizontal
        dictationBar.spacing = 8
        dictationBar.alignment = .bottom
        dictationBar.addArrangedSubview(dictationPill)
        dictationBar.addArrangedSubview(key("delete.left", "Delete the last phrase") { [weak self] in self?.deleteDictated() })
        dictationBar.addArrangedSubview(key("return", "Return") { [weak self] in
            self?.dictatedPhrases.removeAll()
            self?.tapKey(.return)
        })
        dictationBar.isHidden = true
        dictationBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dictationBar)
        NSLayoutConstraint.activate([
            dictationBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dictationBar.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),   // clear of the corner patches
        ])
        transcriptAboveKeyboard = dictationBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -14)
        transcriptInBand = dictationBar.topAnchor.constraint(equalTo: band.topAnchor)
        transcriptAboveKeyboard?.isActive = true
        dictation.onState = { [weak self] state in self?.renderDictation(state, partial: "") }
        dictation.onPartial = { [weak self] text in
            guard let self else { return }
            self.renderDictation(self.dictation.state, partial: text)
        }
        dictation.onFinal = { [weak self] text in
            self?.dictatedPhrases.append(text.count)
            self?.input.typeText(text)
        }
    }

    private func toggleDictation() {
        if dictation.isActive { return dictation.stop() }
        guard hostTypes else {
            return renderDictation(.failed(status.isConnected ? "Update lain on the host to dictate" : "Not connected"), partial: "")
        }
        dictatedPhrases.removeAll()
        dictation.start()
    }

    /// Takes back the last phrase dictated (as many Deletes as it had characters); with none left, one character.
    private func deleteDictated() {
        for _ in 0..<(dictatedPhrases.popLast() ?? 1) { tapKey(.key(0x2A)) }
    }

    private func renderDictation(_ state: Dictation.State, partial: String) {
        let title: String?
        switch state {
        case .idle: title = nil
        case .preparing(let what): title = what
        case .listening: title = partial.isEmpty ? "Listening… tap to stop" : partial
        case .failed(let why): title = why
        }
        dictationBar.isHidden = title == nil
        extraKeys.alpha = title == nil ? 1 : 0   // in portrait the transcript takes their place
        for key in dictationBar.arrangedSubviews.dropFirst() { key.isHidden = state != .listening }
        dictationPill.configuration?.title = title
        dictationPill.configuration?.baseBackgroundColor = state == .listening ? UIColor.systemRed.withAlphaComponent(0.85) : UIColor(white: 0.08, alpha: 0.9)
        keyCapture.keyRow.setDictating(dictation.isActive)
        menuButton.setImage(UIImage(systemName: dictation.isActive ? "mic.fill" : "mic"), for: .normal)
        menuButton.backgroundColor = dictation.isActive ? UIColor.systemRed.withAlphaComponent(0.85) : UIColor(white: 0.1, alpha: 0.55)
        if case .failed = state {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.dictationPill.configuration?.title == title, !self.dictation.isActive else { return }
                self.dictationBar.isHidden = true
                self.extraKeys.alpha = 1
            }
        }
    }

    // MARK: Touch screen

    // Fingers on the screen drive the host's pointer (the panel's "Touch screen" option; the gestures are
    // `TouchGestures`). Only direct touches: the trackpad's pointer arrives as indirect touches when it isn't
    // locked, and the Pencil is left for later. While the panel is open, a tap acts on the row under it.

    private static func id(_ touch: UITouch) -> Int { ObjectIdentifier(touch).hashValue }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard panelView.isHidden else { return }
        for touch in touches where touch.type == .direct {
            let p = touch.location(in: view)
            video.cursor.pointerMoved()   // shows the cursor again after typing (§5.4)
            input.touchBegan(id: Self.id(touch), x: p.x, y: p.y)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .direct {
            let p = touch.location(in: view)
            input.touchMoved(id: Self.id(touch), x: p.x, y: p.y)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .direct {
            if !panelView.isHidden {
                let p = touch.location(in: panelView)
                if let row = panelView.row(at: p) {
                    apply(panel.click(row: row, hosts: hostList, preferences: preferences))
                } else if !panelView.bounds.contains(p) {
                    input.closePanel()   // a tap beside the panel closes it (no keyboard needed)
                }
            }
            input.touchEnded(id: Self.id(touch))   // unknown to the pipeline if it began with the panel open
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .direct }) { input.touchesCancelled() }
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
    func rowUnderCursor() -> Int? { row(at: cursorPoint) }

    /// The row at a point of the panel (its pointer, or a finger), if the line there acts on one.
    func row(at point: CGPoint) -> Int? {
        for (label, line) in zip(labels, lines) where line.row != nil {
            let frame = label.convert(label.bounds, to: self).insetBy(dx: -4, dy: -2)
            if frame.contains(point) { return line.row }
        }
        return nil
    }
}
