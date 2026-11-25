import GameController
import LainClientCore
import LainInput
import LainTransport
import os
import Synchronization
import UIKit

/// Root view controller for the Apple TV client (`LainTVClient`).
///
/// Subclasses `GCEventViewController` with `controllerUserInteractionEnabled = true` so Siri Remote
/// clickpad input arrives via UIKit indirect touches (`touchesBegan`/`Moved`/`Ended` — true raw
/// capacitive finger motion with zero `GCMicroGamepad.dpad` spring-back on lift) and physical presses
/// (`pressesBegan`/`Ended` for Center Click, outer-ring arrows, Play/Pause, and Back/Menu), while
/// Bluetooth keyboards (`GCKeyboard`) and gamepads (`GCExtendedGamepad`) still attach via GameController.
final class TVStreamViewController: GCEventViewController {
    let input: ClientInput
    let video: ClientVideoPipeline

    var session: ClientSession? {
        didSet {
            session?.setNetwork(path: preferences.wifiPath, radioPriority: preferences.radioPriority)
        }
    }

    var audio: ClientAudioPlayer?

    var status = ClientStatus.searching {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = status.isConnected
            connected.set(status.isConnected)
            video.activity.setLinkDown(!status.isConnected)
            updateControllerRouting()
            render()
        }
    }

    /// Exposed for hosted simulator tests: allows exercising remote input even without a live host link.
    var acceptsRemoteInputWhenDisconnected = false {
        didSet { updateControllerRouting() }
    }

    private var preferences: ClientPreferences
    private let referenceWidth: Double
    private let connected = SharedFlag()
    private var renderLoop: StreamRenderLoop?
    private var uiTimer: Timer?
    private var hasVideo = false
    private var observers: [NSObjectProtocol] = []

    private var panel = ControlPanel()
    private var overlayController: TVOverlayViewController?
    private var remoteState = ClientInputPipeline.RemoteState()

    /// Tracks the active UIKit indirect touch on the Siri Remote clickpad.
    private var lastIndirectPoint: CGPoint?
    private var activeIndirectTouch: ObjectIdentifier?
    /// View-point span corresponding to one normalized Siri Remote pad radius (`1.0`).
    private var indirectPadRadiusPoints: CGFloat { max(view.bounds.height * 0.5, 220) }

    /// Optional extended-gamepad thumbstick polling state (DualSense / Xbox).
    private var extendedLeftStick = SIMD2<Float>(0, 0)
    private var extendedRightStick = SIMD2<Float>(0, 0)
    private var extendedScrolling = false

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let pairStack = UIStackView()
    private var renderedUnpairedHosts: [ClientSession.UnpairedHost] = []
    private var renderedGenericPairButton = false
    private let hud = UILabel()
    private let modeBadge = UILabel()

    private static let log = Logger(subsystem: "lain", category: "tvclient")

    init(input: ClientInput, video: ClientVideoPipeline, referenceWidth: Double, nativeScale: UInt16) {
        var loaded = ClientPreferences.load(nativeScale: nativeScale)
        // Apple TV connects over the local network (Wi-Fi / Ethernet), not AWDL peer-to-peer.
        if UserDefaults.standard.string(forKey: "lain.wifiPath") == nil {
            loaded.wifiPath = .network
        }
        self.preferences = loaded
        self.input = input
        self.video = video
        self.referenceWidth = referenceWidth
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFirstResponder: Bool { true }
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        if !pairStack.isHidden, !pairStack.arrangedSubviews.isEmpty { return [pairStack] }
        return super.preferredFocusEnvironments
    }

    var isOverlayPresented: Bool { overlayController != nil }
    var currentRemoteState: ClientInputPipeline.RemoteState { remoteState }
    var isHUDVisible: Bool { !hud.isHidden }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        controllerUserInteractionEnabled = true

        setUpRendering()
        setUpLabels()
        observe()

        input.setPointerEnabled(true)
        input.setReferenceWidth(referenceWidth)
        input.setInvertScroll(preferences.reverseScroll)

        input.setLocalShortcutHandler { [weak self] shortcut in
            Task { @MainActor in
                switch shortcut {
                case .toggleHUD: self?.toggleHUD()
                case .overlay(let shown): self?.setOverlay(shown)
                case .panelKey, .panelPointer, .panelClick: break
                }
            }
        }
        input.setRemoteStateHandler { [weak self] state in
            Task { @MainActor in
                self?.remoteState = state
                self?.renderModeBadge()
                self?.refreshOverlay()
            }
        }

        if let keyboard = GCKeyboard.coalesced { attach(keyboard: keyboard) }
        GCController.controllers().forEach(attach(controller:))
        updateControllerRouting()
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let scale = traitCollection.displayScale
        input.setTouchSurface(width: bounds.width, height: bounds.height)
        guard let layer = renderLoop?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: (bounds.width * scale).rounded(),
                                    height: (bounds.height * scale).rounded())
        CATransaction.commit()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    func sceneBecameActive() {
        view.window?.makeKey()
        becomeFirstResponder()
        updateControllerRouting()
    }

    // MARK: Rendering & UI

    private func setUpRendering() {
        let input = self.input, connected = self.connected
        do {
            let loop = try StreamRenderLoop(
                video: video,
                cursorPosition: { connected.value ? input.cursor.streamedPoint : nil },
                displayPointSize: { input.cursor.streamedSize },
                viewport: { input.viewport },
                tick: { input.tick() })
            view.layer.addSublayer(loop.layer)
            loop.start()
            renderLoop = loop
        } catch {
            Self.log.error("renderer unavailable: \(String(describing: error), privacy: .public)")
        }

        hud.font = .monospacedSystemFont(ofSize: 22, weight: .regular)
        hud.textColor = .white
        hud.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        hud.numberOfLines = 0
        hud.isHidden = true
        hud.accessibilityIdentifier = "stream.hud"
        hud.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hud)

        modeBadge.font = .monospacedSystemFont(ofSize: 20, weight: .bold)
        modeBadge.textColor = .white
        modeBadge.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.88)
        modeBadge.layer.cornerRadius = 12
        modeBadge.layer.masksToBounds = true
        modeBadge.textAlignment = .center
        modeBadge.isHidden = true
        modeBadge.accessibilityIdentifier = "stream.modeBadge"
        modeBadge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeBadge)

        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            hud.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            modeBadge.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            modeBadge.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            modeBadge.heightAnchor.constraint(equalToConstant: 42),
        ])

        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVideoState() }
        }
    }

    private func setUpLabels() {
        titleLabel.font = .systemFont(ofSize: 56, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.accessibilityIdentifier = "connect.title"

        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0
        detailLabel.accessibilityIdentifier = "connect.detail"

        pairStack.axis = .vertical
        pairStack.alignment = .center
        pairStack.spacing = 16
        pairStack.isHidden = true

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel, pairStack])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.setCustomSpacing(40, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.75),
        ])
    }

    private func render() {
        guard isViewLoaded else { return }
        titleLabel.text = status.title
        detailLabel.text = status.detail
        titleLabel.isHidden = hasVideo
        detailLabel.isHidden = hasVideo
        refreshUnpairedButtons()
        renderModeBadge()
    }

    private func refreshUnpairedButtons() {
        let showDisconnected = !hasVideo && !status.isConnected
        let hosts = showDisconnected ? (session?.unpairedHosts() ?? []) : []
        let showGeneric: Bool
        if showDisconnected, hosts.isEmpty {
            switch status {
            case .connecting, .localNetworkDenied: showGeneric = false
            default: showGeneric = true
            }
        } else {
            showGeneric = false
        }

        if hosts != renderedUnpairedHosts || showGeneric != renderedGenericPairButton {
            renderedUnpairedHosts = hosts
            renderedGenericPairButton = showGeneric
            pairStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for host in hosts {
                let verb = host.keyRefused ? "Re-pair" : "Pair"
                let btn = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
                    self?.presentPairing(for: host)
                })
                btn.setTitle("\(verb) with \(host.name)…", for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 30, weight: .semibold)
                btn.accessibilityIdentifier = "connect.pair.\(host.id)"
                pairStack.addArrangedSubview(btn)
            }
            if showGeneric {
                let btn = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
                    self?.presentPairing(for: nil)
                })
                btn.setTitle("Enter Pairing Code…", for: .normal)
                btn.titleLabel?.font = .systemFont(ofSize: 30, weight: .semibold)
                btn.accessibilityIdentifier = "connect.pair.generic"
                pairStack.addArrangedSubview(btn)
            }
            let hasButtons = !pairStack.arrangedSubviews.isEmpty
            pairStack.isHidden = !hasButtons
            if hasButtons {
                setNeedsFocusUpdate()
                updateFocusIfNeeded()
            }
        } else {
            pairStack.isHidden = pairStack.arrangedSubviews.isEmpty
        }
    }

    func presentPairing(for host: ClientSession.UnpairedHost?, from presenter: UIViewController? = nil) {
        let modal = TVPairHostViewController(host: host)
        modal.modalPresentationStyle = .overFullScreen
        modal.modalTransitionStyle = .crossDissolve
        modal.onPair = { [weak self] raw in
            guard let self, let session = self.session else { return "Session unavailable." }
            let parsed: PairingCode
            do {
                parsed = try PairingCode.decode(raw)
            } catch {
                return "Invalid pairing code (\(error)). Make sure you copied the full lain1:… code."
            }
            do {
                try session.pair(code: parsed, select: true)
                return nil
            } catch {
                return "Couldn't save pairing: \(error)"
            }
        }
        (presenter ?? self).present(modal, animated: true)
    }

    private func renderModeBadge() {
        var parts: [String] = []
        if remoteState.dragLocked { parts.append("DRAG LOCK") }
        if remoteState.zoomed { parts.append("2× ZOOM") }
        if parts.isEmpty {
            modeBadge.isHidden = true
            return
        }
        modeBadge.text = "  " + parts.joined(separator: "  ·  ") + "  "
        modeBadge.backgroundColor = remoteState.dragLocked
            ? UIColor.systemOrange.withAlphaComponent(0.9)
            : UIColor.systemBlue.withAlphaComponent(0.88)
        modeBadge.isHidden = false
    }

    private func refreshVideoState() {
        let hasVideo = video.hasVideo
        if hasVideo != self.hasVideo {
            self.hasVideo = hasVideo
            render()
            updateControllerRouting()
        } else if !hasVideo && !status.isConnected {
            refreshUnpairedButtons()
        }
        if !hud.isHidden {
            let stats = video.stats()
            var link = "no link"
            if case .session(let info) = status {
                link = ClientStatus.describe(info.transport)
                    + (info.hostName.isEmpty ? "" : " · \(info.hostName)")
                    + " · protocol v\(info.protocolVersion)"
            }
            hud.text = link + "\n" + stats.hudText
        }
        if overlayController != nil { refreshOverlay() }
    }

    private func toggleHUD() {
        hud.isHidden.toggle()
        if !hud.isHidden { refreshVideoState() }
        refreshOverlay()
    }

    // MARK: Overlay (Quick Actions & Control Panel)

    private var hostTypes: Bool {
        if case .session(let info) = status { return ProtocolFeature.textInput.isSupported(at: info.protocolVersion) }
        return acceptsRemoteInputWhenDisconnected
    }

    private var hostList: ClientSession.HostList { session?.hostList() ?? ClientSession.HostList() }

    func setOverlay(_ shown: Bool) {
        if shown {
            guard overlayController == nil else { return }
            let vc = TVOverlayViewController()
            vc.modalPresentationStyle = .overFullScreen
            vc.modalTransitionStyle = .crossDissolve
            vc.onTypeText = { [weak self] text, sendReturn in
                guard let self else { return }
                if !text.isEmpty { self.input.typeText(text) }
                if sendReturn { self.tapKey(.return) }
            }
            vc.onTapKey = { [weak self] key, mods in
                self?.tapKey(key, holding: mods)
            }
            vc.onToggleZoom = { [weak self] in
                self?.input.toggleZoom()
            }
            vc.onToggleDragLock = { [weak self] in
                guard let self else { return }
                self.input.setRemoteDragLocked(!self.remoteState.dragLocked)
            }
            vc.onToggleHUD = { [weak self] in
                self?.toggleHUD()
            }
            vc.onSelectRow = { [weak self] row in
                guard let self else { return }
                self.apply(self.panel.click(row: row, hosts: self.hostList, preferences: self.preferences))
            }
            vc.onPairHost = { [weak self, weak vc] host in
                self?.presentPairing(for: host, from: vc)
            }
            vc.onClose = { [weak self] in
                self?.input.closePanel()
            }
            overlayController = vc
            session?.setHostStatsInterval(ms: ControlPanel.hostStatsIntervalMs)
            refreshOverlay()
            updateControllerRouting()
            present(vc, animated: true)
        } else {
            guard let vc = overlayController else { return }
            overlayController = nil
            session?.setHostStatsInterval(ms: 0)
            let finish: () -> Void = { [weak self] in
                self?.becomeFirstResponder()
                self?.updateControllerRouting()
            }
            if vc.isBeingPresented, let coordinator = vc.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.dismiss(animated: true, completion: finish)
                }
            } else {
                dismiss(animated: true, completion: finish)
            }
        }
    }

    private func refreshOverlay() {
        guard let vc = overlayController else { return }
        var info: ClientSession.ConnectionInfo?
        if case .session(let i) = status { info = i }
        let sheet = panel.sheet(info: info, video: video.stats(), host: session?.hostStats,
                                hosts: hostList, preferences: preferences, sound: audio?.delay)
        vc.update(sheet: sheet, remoteState: remoteState, hudVisible: !hud.isHidden, canType: hostTypes,
                  unpairedHosts: session?.unpairedHosts() ?? [])
    }

    private func apply(_ action: ControlPanel.Action) {
        switch action {
        case .none:
            break
        case .close:
            input.closePanel()
            return
        case .selectHost(let id):
            session?.selectHost(id)
        case .setPreferences(let p):
            preferences = p
            p.save()
            input.setInvertScroll(p.reverseScroll)
            session?.setNetwork(path: p.wifiPath, radioPriority: p.radioPriority)
            session?.setDesiredScale(p.activeDisplayScale)
            session?.setDesiredDisplayMode(p.wireDisplayMode)
        }
        refreshOverlay()
    }

    private func tapKey(_ key: PhysicalKey, holding modifiers: [PhysicalKey] = []) {
        for m in modifiers { input.keyChanged(m, isDown: true) }
        input.keyChanged(key, isDown: true)
        input.keyChanged(key, isDown: false)
        for m in modifiers.reversed() { input.keyChanged(m, isDown: false) }
    }

    // MARK: Controller Routing

    private var remoteStreamingActive: Bool {
        overlayController == nil && (status.isConnected || acceptsRemoteInputWhenDisconnected)
    }

    private func updateControllerRouting() {
        // Keep UIKit routing enabled so Siri Remote touches arrive as true indirect `UITouch`
        // events (no `GCMicroGamepad.dpad` spring-back on finger lift) and buttons arrive as `UIPress`.
        controllerUserInteractionEnabled = true
        if remoteStreamingActive {
            becomeFirstResponder()
        }
    }

    // MARK: GameController (Paired Keyboards & Extended Gamepads)

    private func observe() {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ body: @escaping @MainActor (TVStreamViewController) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self)
                }
            })
        }
        on(.GCControllerDidConnect) { vc in
            GCController.controllers().forEach(vc.attach(controller:))
        }
        on(.GCControllerDidDisconnect) { vc in
            vc.input.remoteCancelled()
            vc.input.mouseDisconnected()
        }
        on(.GCKeyboardDidConnect) { vc in GCKeyboard.coalesced.map(vc.attach(keyboard:)) }
        on(.GCKeyboardDidDisconnect) { vc in vc.input.keyboardDisconnected() }
    }

    private func attach(controller: GCController) {
        controller.handlerQueue = input.queue
        // Siri Remote clickpad/buttons are handled via UIKit indirect touches & presses above so
        // lifting the thumb never suffers from `GCMicroGamepad.dpad`'s return-to-center spring decay.
        guard let extended = controller.extendedGamepad else { return }
        attach(extended: extended, vendor: controller.vendorName)
    }

    private func attach(extended: GCExtendedGamepad, vendor: String?) {
        Self.log.notice("Extended gamepad connected: \(vendor ?? "unknown", privacy: .public)")
        let input = self.input
        let cursor = video.cursor
        extended.leftThumbstick.valueChangedHandler = { @Sendable _, x, y in
            guard hypot(x, y) > 0.12 else { return }
            cursor.pointerMoved()
            input.mouseMoved(dx: Double(x) * 14, dy: Double(y) * 14)
        }
        extended.rightThumbstick.valueChangedHandler = { @Sendable _, x, y in
            guard hypot(x, y) > 0.15 else { return }
            input.scrollWheel(dx: Double(-x) * 12, dy: Double(y) * 12)
        }
        extended.buttonA.pressedChangedHandler = { @Sendable _, _, pressed in
            input.mouseButton(.left, isDown: pressed)
        }
        extended.buttonB.pressedChangedHandler = { @Sendable _, _, pressed in
            input.mouseButton(.right, isDown: pressed)
        }
        extended.buttonMenu.pressedChangedHandler = { @Sendable _, _, pressed in
            if pressed { input.openPanel() }
        }
    }

    private func attach(keyboard: GCKeyboard) {
        keyboard.handlerQueue = input.queue
        let input = self.input
        let cursor = video.cursor
        keyboard.keyboardInput?.keyChangedHandler = { @Sendable _, _, keyCode, pressed in
            guard let usage = UInt16(exactly: keyCode.rawValue) else { return }
            if pressed, !(0xE0...0xE7).contains(usage) { cursor.keyDown() }
            input.keyChanged(PhysicalKey(usage: usage), isDown: pressed)
        }
    }

    // MARK: Siri Remote Indirect Touches & Presses (UIKit)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard remoteStreamingActive,
              let touch = touches.first(where: { $0.type == .indirect || $0.type == .indirectPointer }) else {
            super.touchesBegan(touches, with: event)
            return
        }
        activeIndirectTouch = ObjectIdentifier(touch)
        lastIndirectPoint = touch.preciseLocation(in: view)
        video.cursor.pointerMoved()
        input.remoteSurfaceTouched(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard remoteStreamingActive,
              let active = activeIndirectTouch,
              let touch = touches.first(where: { ObjectIdentifier($0) == active }),
              let prev = lastIndirectPoint else {
            super.touchesMoved(touches, with: event)
            return
        }
        let now = touch.preciseLocation(in: view)
        lastIndirectPoint = now
        let radius = indirectPadRadiusPoints
        let dx = Double((now.x - prev.x) / radius)
        // UIKit view y is down-positive; SiriRemoteInput expects y up-positive.
        let dy = Double((prev.y - now.y) / radius)
        video.cursor.pointerMoved()
        input.remoteIndirectMoved(dx: dx, dy: dy)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let active = activeIndirectTouch,
              touches.contains(where: { ObjectIdentifier($0) == active }) else {
            super.touchesEnded(touches, with: event)
            return
        }
        activeIndirectTouch = nil
        lastIndirectPoint = nil
        input.remoteSurfaceTouched(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeIndirectTouch != nil else {
            super.touchesCancelled(touches, with: event)
            return
        }
        activeIndirectTouch = nil
        lastIndirectPoint = nil
        input.remoteSurfaceTouched(false)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handlePresses(presses, isDown: true)
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handlePresses(presses, isDown: false)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = handlePresses(presses, isDown: false)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func handlePresses(_ presses: Set<UIPress>, isDown: Bool) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            // Hardware keyboard layout character learning (always active).
            if let key = press.key {
                if isDown, let u = UInt16(exactly: key.keyCode.rawValue) {
                    input.learnCharacter(PhysicalKey(usage: u), key.charactersIgnoringModifiers)
                }
                continue
            }
            // When disconnected (and not in test mode), allow Play/Pause to open Settings/Overlay
            // while letting Back pass through to tvOS so the user can exit the app.
            if !remoteStreamingActive {
                if press.type == .playPause {
                    if !isDown { input.openPanel() }
                    continue
                }
                unhandled.insert(press)
                continue
            }
            switch press.type {
            case .select: input.remoteCenterButton(isDown: isDown)
            case .upArrow: input.remoteRingDirection(.up, isDown: isDown)
            case .downArrow: input.remoteRingDirection(.down, isDown: isDown)
            case .leftArrow: input.remoteRingDirection(.left, isDown: isDown)
            case .rightArrow: input.remoteRingDirection(.right, isDown: isDown)
            case .playPause: input.remotePlayPause(isDown: isDown)
            case .menu: input.remoteMenu(isDown: isDown)
            default: unhandled.insert(press)
            }
        }
        return unhandled
    }
}

/// A Bool shared between the main actor (writer) and the render thread (reader).
private final class SharedFlag: Sendable {
    private let state = Atomic<Bool>(false)
    var value: Bool { state.load(ordering: .relaxed) }
    func set(_ value: Bool) { state.store(value, ordering: .relaxed) }
}
