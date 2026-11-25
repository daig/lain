import AppKit
import CoreGraphics
import LainClientCore
import LainInput
import LainProtocol
import os
import Synchronization

/// The macOS client's stream surface: hosts `StreamRenderLoop.layer` (`CAMetalLayer`), handles hybrid
/// pointer input (seamless absolute in windowed mode, dissociated relative in full-screen / captured mode),
/// native macOS scroll & trackpad gestures, keyboard capture, status overlay, stats HUD, and the
/// Right-Option `MacControlPanelView`.
final class MacStreamView: NSView {
    let input: ClientInput
    let video: ClientVideoPipeline

    var onPairRequested: (() -> Void)?
    var onReleaseCapture: (() -> Void)?
    var onPanelRowClicked: ((Int) -> Void)?
    var onPanelDismissed: (() -> Void)?

    private let connected = SharedFlag()
    private(set) var renderLoop: StreamRenderLoop?
    private var renderLoopStarted = false
    private var metalHostView: MetalHostView?
    private var trackingArea: NSTrackingArea?

    // Overlays
    private let statusStack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let pairButton = NSButton(title: "Pair Host…", target: nil, action: nil)
    private let hudLabel = NSTextField(wrappingLabelWithString: "")
    private let hudBack = NSView()
    private let toastLabel = NSTextField(labelWithString: "")
    private let toastBack = NSView()
    let panelView = MacControlPanelView()

    // State
    private var hasVideo = false
    private var isConnected = false
    private var isPanelOpen = false
    private var pointerInside = false
    private(set) var isPointerCaptured = false
    private var localCursorHidden = false
    private var toastHideTask: Task<Void, Never>?
    private let log = Logger(subsystem: "lain", category: "macclient.view")

    /// Whether the system-shortcut event tap is currently capturing `Cmd+Q`/`Cmd+H`/`Cmd+M`.
    var capturesSystemShortcuts = false

    init(input: ClientInput, video: ClientVideoPipeline, initialRefreshRate: Float) {
        self.input = input
        self.video = video
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        appearance = NSAppearance(named: .darkAqua)

        setUpRendering(initialRefreshRate: initialRefreshRate)
        setUpOverlays()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if isPointerCaptured {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        }
        if localCursorHidden {
            NSCursor.unhide()
        }
        renderLoop?.stop()
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: - Setup

    private func setUpRendering(initialRefreshRate: Float) {
        let input = self.input
        let connected = self.connected
        do {
            let loop = try StreamRenderLoop(
                video: video,
                cursorPosition: { connected.value ? input.cursor.streamedPoint : nil },
                displayPointSize: { input.cursor.streamedSize },
                viewport: { input.viewport },
                preferredFrameRate: initialRefreshRate,
                tick: { input.tick() }
            )
            let host = MetalHostView(metalLayer: loop.layer)
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            metalHostView = host
            renderLoop = loop
        } catch {
            log.error("Metal renderer unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    private func setUpOverlays() {
        // Status stack (shown while no video is flowing)
        titleLabel.font = .systemFont(ofSize: 28, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center

        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 4

        pairButton.bezelStyle = .rounded
        pairButton.controlSize = .large
        pairButton.target = self
        pairButton.action = #selector(pairButtonClicked)

        statusStack.orientation = .vertical
        statusStack.alignment = .centerX
        statusStack.spacing = 10
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.addArrangedSubview(titleLabel)
        statusStack.addArrangedSubview(detailLabel)
        statusStack.addArrangedSubview(pairButton)
        // AppKit requires `detailLabel` to already be in `arrangedSubviews` before setting custom spacing.
        statusStack.setCustomSpacing(18, after: detailLabel)
        addSubview(statusStack)

        NSLayoutConstraint.activate([
            statusStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])

        // Stats HUD (top-right, toggled with ⌃⌥⌘L)
        hudBack.wantsLayer = true
        hudBack.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        hudBack.layer?.cornerRadius = 8
        hudBack.translatesAutoresizingMaskIntoConstraints = false
        hudBack.isHidden = true

        hudLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        hudLabel.textColor = .white
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        hudBack.addSubview(hudLabel)
        addSubview(hudBack)

        NSLayoutConstraint.activate([
            hudLabel.topAnchor.constraint(equalTo: hudBack.topAnchor, constant: 6),
            hudLabel.bottomAnchor.constraint(equalTo: hudBack.bottomAnchor, constant: -6),
            hudLabel.leadingAnchor.constraint(equalTo: hudBack.leadingAnchor, constant: 10),
            hudLabel.trailingAnchor.constraint(equalTo: hudBack.trailingAnchor, constant: -10),
            hudBack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            hudBack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])

        // Capture release hint toast (top-center, auto-hides)
        toastBack.wantsLayer = true
        toastBack.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.88).cgColor
        toastBack.layer?.cornerRadius = 10
        toastBack.layer?.borderWidth = 1
        toastBack.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        toastBack.translatesAutoresizingMaskIntoConstraints = false
        toastBack.isHidden = true

        toastLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        toastLabel.textColor = .white
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        toastBack.addSubview(toastLabel)
        addSubview(toastBack)

        NSLayoutConstraint.activate([
            toastLabel.topAnchor.constraint(equalTo: toastBack.topAnchor, constant: 7),
            toastLabel.bottomAnchor.constraint(equalTo: toastBack.bottomAnchor, constant: -7),
            toastLabel.leadingAnchor.constraint(equalTo: toastBack.leadingAnchor, constant: 14),
            toastLabel.trailingAnchor.constraint(equalTo: toastBack.trailingAnchor, constant: -14),
            toastBack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            toastBack.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])

        // Control Panel overlay (Right Option hold)
        panelView.isHidden = true
        panelView.translatesAutoresizingMaskIntoConstraints = false
        panelView.onClickRow = { [weak self] row in self?.onPanelRowClicked?(row) }
        addSubview(panelView)
        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.92),
            panelView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.92),
        ])
    }

    @objc private func pairButtonClicked() {
        onPairRequested?()
    }

    // MARK: - Layout & Backing Scale

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMetalLayerGeometry()
        startRenderLoopIfReady()
    }

    override func layout() {
        super.layout()
        updateMetalLayerGeometry()
        startRenderLoopIfReady()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalLayerGeometry()
    }

    private func startRenderLoopIfReady() {
        guard !renderLoopStarted, window != nil, bounds.width > 0, bounds.height > 0, let loop = renderLoop else { return }
        renderLoopStarted = true
        loop.start()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func updateMetalLayerGeometry() {
        let scale = window?.backingScaleFactor ?? 2.0
        input.setTouchSurface(width: Double(bounds.width), height: Double(bounds.height))
        guard bounds.width > 0, bounds.height > 0, let metalLayer = renderLoop?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, (bounds.width * scale).rounded()),
            height: max(1, (bounds.height * scale).rounded())
        )
        CATransaction.commit()
    }

    // MARK: - Status, HUD, Panel, Toast

    func updateStatus(_ status: ClientStatus, hasVideo: Bool, showPairButton: Bool) {
        self.hasVideo = hasVideo
        self.isConnected = status.isConnected
        connected.set(status.isConnected)
        titleLabel.stringValue = status.macTitle
        detailLabel.stringValue = status.macDetail
        statusStack.isHidden = hasVideo
        pairButton.isHidden = !showPairButton || hasVideo
        updateLocalCursorVisibility()
    }

    var isHUDVisible: Bool { !hudBack.isHidden }

    func setHUDVisible(_ visible: Bool, text: String? = nil) {
        hudBack.isHidden = !visible
        if let text { hudLabel.stringValue = text }
    }

    func updateHUDText(_ text: String) {
        guard !hudBack.isHidden else { return }
        hudLabel.stringValue = text
    }

    func setPanelOpen(_ open: Bool) {
        isPanelOpen = open
        panelView.isHidden = !open
        if open {
            panelView.centerCursor(showDot: isPointerCaptured)
        }
        updateLocalCursorVisibility()
    }

    func showToast(_ message: String, duration: TimeInterval = 2.8) {
        toastHideTask?.cancel()
        toastLabel.stringValue = message
        toastBack.isHidden = false
        toastBack.alphaValue = 1
        toastHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.toastBack.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.toastBack.alphaValue == 0 else { return }
                    self.toastBack.isHidden = true
                }
            }
        }
    }

    // MARK: - Pointer Capture & Local Cursor Visibility

    func setPointerCaptured(_ captured: Bool, showHint: Bool = true) {
        guard captured != isPointerCaptured else { return }
        if captured {
            guard window?.isKeyWindow == true, NSApp.isActive, !isPanelOpen else { return }
            isPointerCaptured = true
            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
            updateLocalCursorVisibility()
            if showHint {
                showToast("Pointer captured · ⌃⌥Esc or hold Right ⌥ to release")
            }
            log.notice("pointer captured (relative mode)")
        } else {
            isPointerCaptured = false
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            updateLocalCursorVisibility()
            log.notice("pointer released (seamless absolute mode)")
        }
    }

    func handleWindowKeyChanged(isKey: Bool) {
        if !isKey {
            if isPointerCaptured { setPointerCaptured(false, showHint: false) }
            pointerInside = false
        }
        updateLocalCursorVisibility()
    }

    /// Keeps `NSCursor.hide()` / `NSCursor.unhide()` strictly balanced.
    /// Hides the local macOS cursor while captured OR while hovering inside a connected stream (so only
    /// `VideoRenderer`'s crisp remote `CursorSprite` is shown — no double cursor).
    private func updateLocalCursorVisibility() {
        let shouldHide: Bool
        if isPointerCaptured {
            shouldHide = true
        } else {
            shouldHide = isConnected && hasVideo && !isPanelOpen && pointerInside && (window?.isKeyWindow == true) && NSApp.isActive
        }
        if shouldHide && !localCursorHidden {
            NSCursor.hide()
            localCursorHidden = true
        } else if !shouldHide && localCursorHidden {
            NSCursor.unhide()
            localCursorHidden = false
        }
    }

    private func surfacePoint(for event: NSEvent) -> (x: Double, y: Double) {
        let p = convert(event.locationInWindow, from: nil)
        return (Double(p.x), Double(bounds.height - p.y))
    }

    // MARK: - Mouse & Trackpad Pointer Events

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        updateLocalCursorVisibility()
        if !isPointerCaptured, isConnected, !isPanelOpen {
            let sp = surfacePoint(for: event)
            input.pointerMovedAbsolute(surfaceX: sp.x, surfaceY: sp.y)
        }
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        updateLocalCursorVisibility()
    }

    override func mouseMoved(with event: NSEvent) { handlePointerMove(event) }
    override func mouseDragged(with event: NSEvent) { handlePointerMove(event) }
    override func rightMouseDragged(with event: NSEvent) { handlePointerMove(event) }
    override func otherMouseDragged(with event: NSEvent) { handlePointerMove(event) }

    private func handlePointerMove(_ event: NSEvent) {
        video.cursor.pointerMoved()
        if isPointerCaptured {
            input.mouseMovedDirect(dx: Double(event.deltaX), dy: Double(event.deltaY))
        } else if isConnected, !isPanelOpen {
            let sp = surfacePoint(for: event)
            if !pointerInside {
                pointerInside = true
                updateLocalCursorVisibility()
            }
            input.pointerMovedAbsolute(surfaceX: sp.x, surfaceY: sp.y)
        }
    }

    override func mouseDown(with event: NSEvent) { handleMouseButton(.left, isDown: true, event: event) }
    override func mouseUp(with event: NSEvent) { handleMouseButton(.left, isDown: false, event: event) }
    override func rightMouseDown(with event: NSEvent) { handleMouseButton(.right, isDown: true, event: event) }
    override func rightMouseUp(with event: NSEvent) { handleMouseButton(.right, isDown: false, event: event) }
    override func otherMouseDown(with event: NSEvent) { handleMouseButton(.other, isDown: true, event: event) }
    override func otherMouseUp(with event: NSEvent) { handleMouseButton(.other, isDown: false, event: event) }

    private func handleMouseButton(_ button: MouseButton, isDown: Bool, event: NSEvent) {
        if isDown { window?.makeFirstResponder(self) }
        if isPanelOpen {
            if isPointerCaptured {
                input.mouseButton(button, isDown: isDown)
            } else if isDown {
                let p = convert(event.locationInWindow, from: nil)
                if !panelView.frame.contains(p) {
                    onPanelDismissed?()
                }
            }
            return
        }
        guard isConnected else { return }
        if isDown, !isPointerCaptured {
            let sp = surfacePoint(for: event)
            input.pointerMovedAbsolute(surfaceX: sp.x, surfaceY: sp.y)
        }
        input.mouseButton(button, isDown: isDown)
    }

    // MARK: - Scroll & Trackpad Gestures

    override func scrollWheel(with event: NSEvent) {
        guard isConnected, !isPanelOpen else { return }
        if event.hasPreciseScrollingDeltas {
            let phase = MacKeyboardInput.gesturePhase(event.phase)
            let momentum = MacKeyboardInput.momentumPhase(event.momentumPhase)
            input.scrollDirect(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY),
                               phase: phase, momentumPhase: momentum)
        } else {
            // Discrete mouse wheel reports lines; InputInjector divides pixels by pixelsPerLine (10).
            input.scrollWheel(dx: Double(event.scrollingDeltaX) * 10.0,
                              dy: Double(event.scrollingDeltaY) * 10.0)
        }
    }

    override func magnify(with event: NSEvent) {
        guard isConnected, !isPanelOpen else { return }
        let phase = MacKeyboardInput.gesturePhase(event.phase)
        input.gesture(.magnify, phase: phase, value: Float(event.magnification))
    }

    override func rotate(with event: NSEvent) {
        guard isConnected, !isPanelOpen else { return }
        let phase = MacKeyboardInput.gesturePhase(event.phase)
        // AppKit reports degrees; lain's protocol carries radians.
        let radians = Float(event.rotation * .pi / 180.0)
        input.gesture(.rotate, phase: phase, value: radians)
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        // Ignore AppKit repeats: ClientInputPipeline's KeyRepeatGenerator repeats at the host's rate.
        if event.isARepeat { return }
        let rawFlags = UInt64(event.modifierFlags.rawValue)
        if MacKeyboardInput.isReleaseChord(macKeyCode: event.keyCode, rawFlags: rawFlags) {
            onReleaseCapture?()
            return
        }
        guard let physical = MacKeyCode.physicalKey(forMacKeyCode: event.keyCode) else { return }
        video.cursor.keyDown()
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            input.learnCharacter(physical, chars)
        }
        input.keyChanged(physical, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        guard let physical = MacKeyCode.physicalKey(forMacKeyCode: event.keyCode) else { return }
        input.keyChanged(physical, isDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let physical = MacKeyCode.physicalKey(forMacKeyCode: event.keyCode) else { return }
        let rawFlags = UInt64(event.modifierFlags.rawValue)
        if physical == .capsLock {
            // macOS fires one flagsChanged per toggle; emit a tap so KeyboardProcessor toggles cleanly.
            input.keyChanged(.capsLock, isDown: true)
            input.keyChanged(.capsLock, isDown: false)
            return
        }
        guard let isDown = MacKeyboardInput.isModifierDown(macKeyCode: event.keyCode, rawFlags: rawFlags) else { return }
        input.keyChanged(physical, isDown: isDown)
    }

    /// Forwards `Cmd+...` shortcuts (like `Cmd+C`, `Cmd+V`, `Cmd+W`, `Cmd+T`, `Cmd+Z`, `Cmd+F`) directly
    /// to the remote host when the stream window is focused, while keeping local `Ctrl+Cmd+F` (Full Screen)
    /// and (unless system-shortcut capture is on) `Cmd+Q`/`Cmd+H`/`Cmd+M` available for the local Mac.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, isConnected, !isPanelOpen else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Always let ⌃⌘F toggle native macOS Full Screen cleanly.
        if mods == [.control, .command], event.charactersIgnoringModifiers?.lowercased() == "f" {
            return super.performKeyEquivalent(with: event)
        }
        // Unless System Shortcut Capture is active, let local Cmd+Q / Cmd+H / Cmd+M work on the local Mac.
        if !capturesSystemShortcuts, mods == .command,
           let ch = event.charactersIgnoringModifiers?.lowercased(),
           ch == "q" || ch == "h" || ch == "m" {
            return super.performKeyEquivalent(with: event)
        }
        // Forward all other Cmd/Ctrl/Opt chords directly to the remote host (e.g. Cmd+C/V/X/Z/W/T/S/F/A/L).
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Dedicated layer-backed host view for `StreamRenderLoop.layer` (`CAMetalLayer`), so AppKit overlay
/// subviews never mix with a layer-hosting `NSView`.
private final class MetalHostView: NSView {
    private let metalLayer: CAMetalLayer

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { metalLayer }
    override var isOpaque: Bool { true }
}

/// Lock-free boolean shared between the main thread and `StreamRenderLoop`'s render thread.
private final class SharedFlag: Sendable {
    private let flag = Atomic<Bool>(false)
    var value: Bool { flag.load(ordering: .relaxed) }
    func set(_ newValue: Bool) { flag.store(newValue, ordering: .relaxed) }
}
