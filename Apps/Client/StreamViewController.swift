import AudioToolbox
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

    /// The host's sound: silenced while dictation listens, so the microphone doesn't hear it.
    var audio: ClientAudioPlayer?

    var status = ClientStatus.waitingForMac(wifi: false) {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = status.isConnected
            connected.set(status.isConnected)
            video.activity.setLinkDown(!status.isConnected)   // a frozen picture isn't a quiet one
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
    /// The keyboard isn't on its way in or out: its frame is the one it will keep.
    private var keyboardSettled = true
    /// The streamed display's width over its height (0 until known), to place the stream in portrait.
    private var streamAspect: CGFloat = 0
    /// Where everything goes, from the window's size (`StreamLayout`): set on every layout.
    private var layout = StreamLayout()
    /// The streamed display's width, in points, that the pointer speeds were tuned at: this device's own.
    private let referenceWidth: Double
    /// A trackpad or mouse drives the pointer (and can be locked): no trackpad areas then. An iPhone has none.
    private var hasPointer: Bool { !GCMouse.mice().isEmpty && view.window?.windowScene?.pointerLockState != nil }
    /// A window too narrow for the panel's lines (a phone, a Split View half) has the settings as a sheet.
    private var usesSheet: Bool { view.bounds.width < 1000 }
    private var settingsSheet: SettingsSheet?
    /// A phone's screen held upright (the Duo closed): the controls beside or under the stream.
    private let controlStrip = ControlStrip()
    /// The keyboard is up because the iPad is in portrait (and goes away when it no longer is).
    private var keyboardIsAutomatic = false
    /// How many characters each dictated phrase typed, newest last: the transcript's Delete key takes one back.
    private var dictatedPhrases: [Int] = []
    /// Where there is no trackpad (landscape): the words being heard, small, low between the thumbs' trackpads
    /// (as the trackpad layouts show them in theirs; finished phrases are
    /// already on the host's screen), and Delete and Return beside the floating microphone.
    private let caption = UILabel()
    private let captionBack = UIView()
    /// The caption's bottom edge, from the view's top: level with the thumbs' trackpads, between them.
    private var captionBottom: NSLayoutConstraint?
    private let clusterBack = UIView()
    private lazy var clusterDelete = roundKey("delete.left", "Delete the last phrase") { [weak self] in self?.deleteDictated() }
    private lazy var clusterReturn = roundKey("return", "Return") { [weak self] in self?.sendDictated() }
    /// Portrait, between the stream and the keyboard: more keys, and a trackpad strip that takes what is left.
    private let band = UIView()
    private let trackpad = TrackpadStrip()
    /// Beside another app: a ribbon to scroll with, at the outer end of the trackpad strip's row.
    private let bandRibbon = ScrollRibbon()
    /// Landscape without a hardware keyboard: a small trackpad patch in each bottom corner, under the thumbs.
    private static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    private let cornerPads = [TrackpadStrip(corner: allCorners), TrackpadStrip(corner: allCorners)]
    private static let cornerPadSize = CGSize(width: 150, height: 120)
    /// How far the patches sit above the bottom: clear of the host's Dock (about 65 points on a Mac at the
    /// iPad's own scale), and where the thumbs rest when the iPad is held.
    private static let cornerPadLift: CGFloat = 104
    /// How far in from the side edges: with the lift, the patch's centre is about 110 points in and 165 up,
    /// where a thumb rests when the iPad is held by its lower corners (as a game's on-screen sticks sit).
    private static let cornerPadInset: CGFloat = 36
    private lazy var extraKeys = ExtraKeys(pasteTarget: self)
    /// Folded like a laptop and set down: the lower half, with no keyboard (`StreamLayout.Deck`).
    private let deck = DeckView()
    /// While dictating, in place of the band's keys (`extraKeys`): Delete phrase and Return.
    private let bandDictationKeys = DictationKeys()
    /// What dictation shows (what is heard, or why it failed), kept so a new layout can show it in its own place.
    private var dictationHeard: String?
    /// The keyboard's row of keys beside the stream, where a short landscape window has the keyboard up.
    private let sideKeys = SideKeys()
    /// Where the transcript sits: at the top of the band in portrait, above the keyboard otherwise.
    private var transcriptCenterX: NSLayoutConstraint?
    /// The connection status' centre (x, y) and greatest width: it sits where the stream will.
    private var statusPlace: [NSLayoutConstraint] = []
    /// The band's three arrangements: the keys above the strip, the strip alone, the keys at the strip's left.
    private enum BandForm { case stacked, stripOnly, stripAndRibbon, ribbonAndStrip, beside, besideOnRight }
    private var bandForms: [BandForm: [NSLayoutConstraint]] = [:]
    private var bandForm: BandForm?
    /// Dictation on the iPad, typed on the host.
    /// Read by the hardware keyboard's handler (on the input queue): dictation is on, so Return waits for it to
    /// stop (see `attach(keyboard:)`); and that Return's key-up, which mustn't reach the host alone.
    private let dictating = SharedFlag()
    private let returnHeldBack = SharedFlag()
    private let dictation = Dictation()
    /// When Globe last went down, for the double-tap that toggles dictation; and whether that press was taken.
    private var lastGlobeDownNs: UInt64 = 0
    private var globeTaken = false
    private var lastScrollTranslation = CGPoint.zero
    private var lastWheelTranslation = CGPoint.zero

    init(input: ClientInput, video: ClientVideoPipeline, referenceWidth: Double) {
        self.input = input
        self.video = video
        self.referenceWidth = referenceWidth
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
        if #available(iOS 27.1, *) {
            // Folding changes where the fold's region is and whether it counts: lay out again.
            view.addInteraction(UIHingeInteraction { [weak self] _, _ in self?.view.setNeedsLayout() })
        }

        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Drawable = the stream's frame in pixels: 2752×2064 on the 13" iPad Pro full screen, 1:1 with the stream.
        let scale = traitCollection.displayScale
        var shape = StreamLayout.Input(size: view.bounds.size)
        let safe = view.safeAreaInsets
        shape.safeArea = .init(top: safe.top, left: safe.left, bottom: safe.bottom, right: safe.right)
        // The keyboard as it is on the glass now, not as it is about to be: the inset counts only while the
        // keyboard is lain's (a keyboard on its way out after a turn still has its old frame), and the row
        // counts while it is really in the keyboard's window (asking for it to go doesn't remove it at once).
        // Mixing the two states made the layout flip between the row and the side keys without end.
        shape.keyboardInset = keyCapture.isFirstResponder ? keyboardInset : 0
        shape.keyRowHeight = shape.keyboardInset > 0 && keyCapture.keyRow.window != nil ? keyCapture.keyRow.bounds.height : 0
        shape.streamAspect = streamAspect
        shape.softKeyboard = GCKeyboard.coalesced == nil
        shape.touchPointer = !hasPointer
        shape.isCompact = traitCollection.horizontalSizeClass == .compact
        if let screen = view.window?.windowScene?.screen {
            shape.sharesScreen = view.bounds.width < screen.bounds.width - 1
            // Which side of the screen the window is on (Split View): its controls go to the outer edge.
            // iOS gives an app no frame on the screen (a view's coordinates never leave its window), but it
            // says where it would put the app's own side bar, which is the screen's outer edge: leading for the
            // app on the left. Where it says nothing, the right side, which is the arrangement tuned first.
            if #available(iOS 27.1, *) {
                shape.isOnLeftOfScreen = shape.sharesScreen && traitCollection.verticalBarEdge == .leading
            }
        }
        if #available(iOS 27.1, *) {
            shape.fold = view.reservedRegions(kind: .division, options: []).first(where: \.isActive)?.frame
            shape.occlusions = view.reservedRegions(kind: .occlusion, options: []).filter(\.isActive).map(\.frame)
        }
        // Where the keyboard comes up by itself (upright, on a phone or an iPad), it isn't there yet right after a
        // turn or a launch, and while it slides in its frame is only part of what it will be (its row of keys
        // first). Laying out for those moments shows arrangements made for no keyboard or a small one (a large
        // trackpad, the side strip): instead, until the keyboard has settled, lay out for the height it had in
        // this window the last time, and it arrives where room was left for it.
        if StreamLayout(shape).keyboardIsAutomatic, shape.softKeyboard, hostTypes, panelView.isHidden, settingsSheet == nil {
            let key = "lain.keyboardInset.\(Int(view.bounds.width))x\(Int(view.bounds.height))"
            if keyboardSettled, shape.keyboardInset > 0 {
                UserDefaults.standard.set(Double(shape.keyboardInset), forKey: key)
            } else {
                let known = CGFloat(UserDefaults.standard.double(forKey: key))
                if known > 0, known < view.bounds.height {
                    shape.keyboardInset = known
                    shape.keyRowHeight = 0
                }
            }
        }
        layout = StreamLayout(shape)
        let stream = layout.stream
        logGeometry()
        updateInputMode()
        layoutControls()
        input.setTouchSurface(width: stream.width, height: stream.height)
        input.setFillsView(layout.fillsStream)
        guard let layer = renderLoop?.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = stream
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: (stream.width * scale).rounded(), height: (stream.height * scale).rounded())
        CATransaction.commit()
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

    /// The window's shape whenever it changes (a turn, a fold, Split View), for the console.
    private var loggedGeometry = ""
    private func logGeometry() {
        let screen = view.window?.windowScene?.screen
        let t = traitCollection
        func name(_ c: UIUserInterfaceSizeClass) -> String { c == .regular ? "regular" : c == .compact ? "compact" : "?" }
        var line = "geometry: view \(view.bounds.size) safe \(view.safeAreaInsets) classes \(name(t.horizontalSizeClass))/\(name(t.verticalSizeClass))"
            + " keyboard \(keyboardInset) scale \(t.displayScale) screen \(screen?.bounds.size ?? .zero) native \(screen?.nativeBounds.size ?? .zero) \(screen?.maximumFramesPerSecond ?? 0) Hz"
        if #available(iOS 27.1, *) {
            for kind in [UIView.ReservedRegion.Kind.division, .occlusion] {
                for r in view.reservedRegions(kind: kind, options: [.includeInactive]) {
                    line += " | \(kind == .division ? "division" : "occlusion") \(r.frame) \(r.isActive ? "active" : "inactive")"
                }
            }
        }
        if #available(iOS 27.1, *) {
            let edge = t.verticalBarEdge
            line += " | bar edge \(edge == .leading ? "leading" : edge == .trailing ? "trailing" : "unspecified")"
        }
        guard line != loggedGeometry else { return }
        loggedGeometry = line
        Self.log.notice("\(line, privacy: .public)")
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
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
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
        // Centred on the stream's place (the layout moves it there), no wider than it.
        let centerX = stack.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        let centerY = stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        let width = stack.widthAnchor.constraint(lessThanOrEqualToConstant: 2000)
        statusPlace = [centerX, centerY, width]
        NSLayoutConstraint.activate([
            centerX, centerY, width,
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            overlay.heightAnchor.constraint(equalToConstant: 84),
            overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
        ])
    }

    private func render() {
        guard isViewLoaded else { return }
        titleLabel.text = status.title
        detailLabel.text = status.detail
        titleLabel.isHidden = hasVideo
        detailLabel.isHidden = hasVideo
        overlay.isHidden = pointerLocked || !hasPointer   // nothing to capture without a trackpad
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
                viewport: { input.viewport },
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
        // Pointer speeds are fixed per control and follow the host's resolution (`ClientInputPipeline`).
        input.setCurve(ClientInputPipeline.trackpadCurve)
        input.setReferenceWidth(referenceWidth)
        input.setInvertScroll(preferences.reverseScroll)
        input.setTouchMode(preferences.touchMode)

        // 4 Hz: whether video is up (hides the connect status) and the HUD's numbers.
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVideoState() }
        }
    }

    private func refreshVideoState() {
        if !deck.isHidden { watchActivity() }
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
        guard !hud.isHidden || !panelView.isHidden || settingsSheet != nil else { return }
        let stats = video.stats()
        if !hud.isHidden { hud.text = hudText(stats) }
        if !panelView.isHidden || settingsSheet != nil { renderPanel(stats) }
    }

    // MARK: Panel

    /// Opened by holding Right Option alone; the host's stats are asked for while it shows.
    private func setPanel(_ shown: Bool) {
        if usesSheet, panelView.isHidden {
            // The pipeline keeps the keyboard and the touches from the host while its panel is open; a sheet
            // takes the touches by itself, so the pipeline's panel closes at once.
            if shown {
                input.closePanel()
                presentSettings()
            }
            return
        }
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
        if let settingsSheet {
            settingsSheet.show(panel.sheet(info: info, video: stats, host: session?.hostStats, hosts: hostList,
                                           preferences: preferences, sound: audio?.delay))
        }
        guard !panelView.isHidden else { return }
        panelView.show(panel.lines(info: info, video: stats, host: session?.hostStats, hosts: hostList,
                                   preferences: preferences, sound: audio?.delay))
    }

    /// The settings as a sheet (a narrow window): the host's stats are asked for while it shows.
    private func presentSettings() {
        guard settingsSheet == nil, presentedViewController == nil else { return }
        let sheet = SettingsSheet()
        sheet.onSelect = { [weak self] row in
            guard let self else { return }
            self.apply(self.panel.click(row: row, hosts: self.hostList, preferences: self.preferences))
        }
        sheet.onClose = { [weak self] in
            guard let self else { return }
            self.settingsSheet = nil
            self.session?.setHostStatsInterval(ms: 0)
            self.becomeFirstResponder()
            self.updateInputMode()
        }
        settingsSheet = sheet
        setTouchKeyboard(false)
        session?.setHostStatsInterval(ms: ControlPanel.hostStatsIntervalMs)
        renderPanel(video.stats())
        let navigation = UINavigationController(rootViewController: sheet)
        navigation.overrideUserInterfaceStyle = .dark
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = true
        present(navigation, animated: true)
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
            input.setInvertScroll(p.reverseScroll)
            input.setTouchMode(p.touchMode)
            session?.setNetwork(path: p.wifiPath, radioPriority: p.radioPriority)
        }
        renderPanel()
        // The session applies a pick on its queue: show its result once it has.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.panelView.isHidden || self.settingsSheet != nil else { return }
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
        on(.GCMouseDidConnect) { $0.hardwareKeyboardChanged(); $0.render() }
        on(.GCMouseDidDisconnect) { $0.hardwareKeyboardChanged(); $0.render() }
        on(UIResponder.keyboardWillChangeFrameNotification) { vc in
            vc.keyboardSettled = false
            vc.keyboardFrameChanged()
        }
        on(UIResponder.keyboardDidChangeFrameNotification) { vc in
            vc.keyboardSettled = true
            vc.keyboardFrameChanged()
            vc.view.setNeedsLayout()
        }
        on(UIResponder.keyboardDidHideNotification) { vc in
            vc.keyboardSettled = true
            vc.keyboardFrameChanged(hidden: true)
        }
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
        keyboard.keyboardInput?.keyChangedHandler = { @Sendable [weak self] _, _, keyCode, pressed in
            guard let usage = UInt16(exactly: keyCode.rawValue) else { return }
            // Hide while typing: any non-modifier key-down hides the cursor until the pointer moves.
            if pressed, !(0xE0...0xE7).contains(usage) { cursor.keyDown() }
            // Return or Enter while dictating (Globe twice) sends what was said, and dictation stops, as on the
            // glass. The key waits: stopping types what was still being heard, which must reach the host first.
            if usage == 0x28 || usage == 0x58, let self {
                if pressed, self.dictating.value {
                    self.returnHeldBack.set(true)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.returnEndsDictation()
                        self.input.keyChanged(PhysicalKey(usage: usage), isDown: true)
                        self.input.keyChanged(PhysicalKey(usage: usage), isDown: false)
                    }
                    return
                }
                if !pressed, self.returnHeldBack.value {
                    self.returnHeldBack.set(false)
                    return
                }
            }
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
            // The system keyboard's Return while dictating: what was still being heard is typed first.
            if text.contains("\n") { self.returnEndsDictation() }
            self.input.typeText(text, modifiers: self.takeModifiers())
        }
        keyCapture.onBackspace = { [weak self] in self?.tapKey(.key(0x2A)) }   // HID Delete (Backspace)
        keyCapture.keyRow.onKey = { [weak self] key in self?.tapKey(key) }
        keyCapture.keyRow.onHide = { [weak self] in self?.setTouchKeyboard(false) }
        keyCapture.keyRow.onDictate = { [weak self] in self?.toggleDictation() }
        keyCapture.keyRow.onSettings = { [weak self] in self?.input.openPanel() }
        sideKeys.onKey = { [weak self] key in self?.tapKey(key) }
        sideKeys.onHide = { [weak self] in self?.setTouchKeyboard(false) }
        sideKeys.onDictate = { [weak self] in self?.toggleDictation() }
        sideKeys.onSettings = { [weak self] in self?.input.openPanel() }
        view.addSubview(sideKeys.left)
        view.addSubview(sideKeys.right)
        controlStrip.onDictate = { [weak self] in self?.toggleDictation() }
        controlStrip.onKeyboard = { [weak self] in
            guard let self else { return }
            self.setTouchKeyboard(!self.keyCapture.isFirstResponder)
        }
        controlStrip.onSettings = { [weak self] in self?.input.openPanel() }
        // A ribbon is short: a thumb's travel scrolls twice as far as two fingers' would.
        let input = self.input
        for ribbon in [controlStrip.ribbon, bandRibbon] {
            ribbon.onBegan = { input.glassScroll(.scrollBegan) }
            ribbon.onScroll = { dy in input.glassScroll(.scroll(dx: 0, dy: Double(dy) * 2)) }
            ribbon.onEnded = { input.glassScroll(.scrollEnded) }
            ribbon.onCancelled = { input.glassScroll(.scrollCancelled) }
        }
        controlStrip.isHidden = true
        view.addSubview(controlStrip)
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
        menuButton.bounds = CGRect(x: 0, y: 0, width: 48, height: 48)   // placed by the layout
        view.addSubview(menuButton)
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

    private func renderControls() {
        controlStrip.update(dictating: dictation.isActive, keyboardShown: keyCapture.isFirstResponder,
                            keyboardOffered: GCKeyboard.coalesced == nil, canType: hostTypes)
    }

    private func setTouchKeyboard(_ shown: Bool) {
        if shown { keyCapture.becomeFirstResponder() } else if keyCapture.isFirstResponder { becomeFirstResponder() }
        if !shown { keyboardIsAutomatic = false }
        renderControls()
    }

    /// Applies the configuration: which controls show, and whether the keyboard is up on its own.
    private func updateInputMode() {
        let hasKeyboard = GCKeyboard.coalesced != nil
        menuButton.isHidden = layout.edgeButton == nil
        keyCapture.keyRow.setCanHide(!layout.keyboardIsAutomatic)
        if hasKeyboard || layout.deck != nil {
            // The view that takes the system keyboard's typing would take the hardware keys' too, which
            // GameController already sends. The deck has no keyboard: one left up from before the fold goes.
            setTouchKeyboard(false)
        } else if layout.keyboardIsAutomatic {
            if hostTypes, panelView.isHidden, settingsSheet == nil, !keyCapture.isFirstResponder, view.window != nil {
                keyboardIsAutomatic = keyCapture.becomeFirstResponder()
            }
        } else if keyboardIsAutomatic {
            setTouchKeyboard(false)   // no longer portrait: the keyboard on request
        }
        renderControls()
    }

    /// A keyboard, trackpad or mouse was attached or detached: the trackpad areas and the band are placed in layout.
    private func hardwareKeyboardChanged() {
        updateInputMode()
        view.setNeedsLayout()
    }

    /// One press of a key that isn't a character, with the key row's lit modifiers held around it.
    /// The modifiers lit on whichever set of keys shows (the row above the keyboard, or the keys beside the stream).
    private func takeModifiers() -> ModifierFlags {
        layout.sideKeys.isEmpty ? keyCapture.keyRow.takeModifiers() : sideKeys.takeModifiers()
    }

    private func tapKey(_ key: PhysicalKey, holding extra: [PhysicalKey] = []) {
        let lit = takeModifiers()
        let held: [PhysicalKey] = [(ModifierFlags.control, PhysicalKey.leftControl), (.option, .leftOption), (.command, .leftCommand)]
            .filter { lit.contains($0.0) }.map(\.1).filter { !extra.contains($0) } + extra
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

    // MARK: The deck's alert

    private var activityPhase = ActivityDetector.Phase.still
    private var lastLoggedChange: Int?

    /// Four times a second while the deck shows: the part of the display the picture shows is what is watched;
    /// when it has been working and goes quiet, the phone chimes and taps, for an owner who has looked away.
    private func watchActivity() {
        video.activity.setRegion(input.viewport)
        let (phase, event, changed) = video.activity.tick()
        // For tuning on the device: how many cells each sample saw change, when that changes.
        if changed != lastLoggedChange {
            lastLoggedChange = changed
            Self.log.notice("activity: \(changed) cells changed, \(String(describing: phase))")
        }
        if phase != activityPhase {
            activityPhase = phase
            deck.setActivity(phase)
        }
        guard event == .wentQuiet, !dictation.isActive else { return }
        Self.log.notice("activity: went quiet")
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(1007)
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
        for pad in [trackpad, deck.trackpad] + cornerPads {
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
        deck.isHidden = true
        // The owner's own touches move the picture: not the activity the deck watches for.
        let activity = video.activity
        let (began, moved) = (deck.trackpad.onBegan, deck.trackpad.onMoved)
        deck.trackpad.onBegan = { id, p in activity.noteInput(); began(id, p) }
        deck.trackpad.onMoved = { id, p in activity.noteInput(); moved(id, p) }
        deck.onKey = { [weak self] key, held in
            activity.noteInput()
            self?.tapKey(key, holding: held)
        }
        deck.onDictate = { [weak self] in
            activity.noteInput()
            self?.toggleDictation()
        }
        for keys in [deck.dictationKeys, bandDictationKeys] {
            keys.onDeletePhrase = { [weak self] in
                activity.noteInput()
                self?.deleteDictated()
            }
            // Sending is the end of what was said: Return, and dictation stops.
            keys.onReturn = { [weak self] in self?.sendDictated() }
        }
        deck.onSettings = { [weak self] in self?.input.openPanel() }
        view.addSubview(deck)
        for v in [extraKeys, trackpad, bandRibbon, bandDictationKeys] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            band.addSubview(v)
        }
        NSLayoutConstraint.activate([
            // Dictating, Delete and Return take the keys' place, whichever form the band has.
            bandDictationKeys.leftAnchor.constraint(equalTo: extraKeys.leftAnchor),
            bandDictationKeys.rightAnchor.constraint(equalTo: extraKeys.rightAnchor),
            bandDictationKeys.topAnchor.constraint(equalTo: extraKeys.topAnchor),
            bandDictationKeys.bottomAnchor.constraint(equalTo: extraKeys.bottomAnchor),
            extraKeys.topAnchor.constraint(equalTo: band.topAnchor),
            trackpad.bottomAnchor.constraint(equalTo: band.bottomAnchor),
            // The ribbon: as tall as the strip, and wide enough for a thumb.
            bandRibbon.topAnchor.constraint(equalTo: band.topAnchor),
            bandRibbon.bottomAnchor.constraint(equalTo: band.bottomAnchor),
            bandRibbon.widthAnchor.constraint(equalToConstant: 52),
        ])
        // Left and right, not leading and trailing: the sides follow the hands, not the language.
        bandForms = [
            .stacked: [extraKeys.leftAnchor.constraint(equalTo: band.leftAnchor),
                       extraKeys.rightAnchor.constraint(equalTo: band.rightAnchor),
                       extraKeys.heightAnchor.constraint(equalToConstant: 38),
                       trackpad.leftAnchor.constraint(equalTo: band.leftAnchor),
                       trackpad.rightAnchor.constraint(equalTo: band.rightAnchor),
                       trackpad.topAnchor.constraint(equalTo: extraKeys.bottomAnchor, constant: 8)],
            .stripOnly: [trackpad.leftAnchor.constraint(equalTo: band.leftAnchor),
                         trackpad.rightAnchor.constraint(equalTo: band.rightAnchor),
                         trackpad.topAnchor.constraint(equalTo: band.topAnchor)],
            // The strip with the scroll ribbon at its right end, or at its left.
            .stripAndRibbon: [trackpad.leftAnchor.constraint(equalTo: band.leftAnchor),
                              trackpad.rightAnchor.constraint(equalTo: bandRibbon.leftAnchor, constant: -8),
                              bandRibbon.rightAnchor.constraint(equalTo: band.rightAnchor),
                              trackpad.topAnchor.constraint(equalTo: band.topAnchor)],
            .ribbonAndStrip: [bandRibbon.leftAnchor.constraint(equalTo: band.leftAnchor),
                              trackpad.leftAnchor.constraint(equalTo: bandRibbon.rightAnchor, constant: 8),
                              trackpad.rightAnchor.constraint(equalTo: band.rightAnchor),
                              trackpad.topAnchor.constraint(equalTo: band.topAnchor)],
            // Two keys (Esc, Paste) of a comfortable width, as tall as the strip, at its left, and the scroll
            // ribbon at the outer end, under the thumb...
            .beside: [extraKeys.leftAnchor.constraint(equalTo: band.leftAnchor),
                      extraKeys.widthAnchor.constraint(equalToConstant: 118),
                      extraKeys.bottomAnchor.constraint(equalTo: band.bottomAnchor),
                      trackpad.leftAnchor.constraint(equalTo: extraKeys.rightAnchor, constant: 8),
                      trackpad.rightAnchor.constraint(equalTo: bandRibbon.leftAnchor, constant: -8),
                      bandRibbon.rightAnchor.constraint(equalTo: band.rightAnchor),
                      trackpad.topAnchor.constraint(equalTo: band.topAnchor)],
            // ...or all of it the other way round, when the window is on the screen's left side.
            .besideOnRight: [extraKeys.rightAnchor.constraint(equalTo: band.rightAnchor),
                             extraKeys.widthAnchor.constraint(equalToConstant: 118),
                             extraKeys.bottomAnchor.constraint(equalTo: band.bottomAnchor),
                             bandRibbon.leftAnchor.constraint(equalTo: band.leftAnchor),
                             trackpad.leftAnchor.constraint(equalTo: bandRibbon.rightAnchor, constant: 8),
                             trackpad.rightAnchor.constraint(equalTo: extraKeys.leftAnchor, constant: -8),
                             trackpad.topAnchor.constraint(equalTo: band.topAnchor)],
        ]
    }

    /// Applies the layout's frames to the touch controls: the band (keys and trackpad strip), the thumb patches,
    /// the microphone button, the control strip and the transcript.
    private func layoutControls() {
        let shown = layout.band != nil
        if let frame = layout.band { band.frame = frame }
        if band.isHidden == shown {
            band.isHidden = !shown
            if !shown { input.padTouchesCancelled() }
        }
        let form: BandForm
        if layout.keysBesideStrip {
            form = layout.keysOnRight ? .besideOnRight : .beside
        } else if layout.bandHasKeys {
            form = .stacked
        } else if layout.stripHasRibbon {
            form = layout.ribbonOnLeft ? .ribbonAndStrip : .stripAndRibbon
        } else {
            form = .stripOnly
        }
        if form != bandForm {
            bandForm = form
            extraKeys.isHidden = !layout.bandHasKeys
            bandRibbon.isHidden = form == .stacked || form == .stripOnly
            NSLayoutConstraint.deactivate(bandForms.values.flatMap { $0 })
            NSLayoutConstraint.activate(bandForms[form] ?? [])
        }
        extraKeys.setForm(layout.isShared ? .shared : layout.isRemote ? .remote : .band)
        let corners = !layout.cornerPads.isEmpty
        for (pad, frame) in zip(cornerPads, layout.cornerPads) { pad.frame = frame }
        for pad in cornerPads where pad.isHidden == corners {
            pad.isHidden = !corners
            if !corners { input.padTouchesCancelled() }
        }
        if let center = layout.edgeButton { menuButton.center = center }
        // The row of keys is above the keyboard, or beside the stream: never both. Changing it reloads the
        // keyboard, which lays out again: after this pass, and only if the layout still says so.
        if keyCapture.showsKeyRow != layout.sideKeys.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.keyCapture.showsKeyRow = self.layout.sideKeys.isEmpty
            }
        }
        for (keys, frame) in zip([sideKeys.left, sideKeys.right], layout.sideKeys) { keys.frame = frame }
        sideKeys.left.isHidden = layout.sideKeys.isEmpty
        sideKeys.right.isHidden = layout.sideKeys.isEmpty
        if statusPlace.count == 3 {
            statusPlace[0].constant = layout.stream.midX - view.bounds.midX
            statusPlace[1].constant = layout.stream.midY - view.bounds.midY
            statusPlace[2].constant = max(layout.stream.width - 32, 100)
            titleLabel.font = .systemFont(ofSize: layout.stream.width < 500 ? 26 : 34, weight: .semibold)
        }
        controlStrip.isHidden = layout.controls == nil
        if let controls = layout.controls {
            controlStrip.frame = controls.frame
            controlStrip.setVertical(controls.isVertical)
        }
        if let frames = layout.deck { deck.apply(frames) }
        if deck.isHidden == (layout.deck != nil) {
            deck.isHidden = layout.deck == nil
            if deck.isHidden { input.padTouchesCancelled() }
            input.setPadPinchZooms(!deck.isHidden)   // the picture above isn't touched: the deck's pinch zooms it
            video.activity.setEnabled(!deck.isHidden)
        }
        // The transcript: at the top of the band or the deck when there is one, and clear of a fold.
        transcriptCenterX?.constant = layout.transcriptCenterX - view.bounds.midX
        placeDictation()   // a new layout shows dictation in its own place
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

    /// Dictation: final phrases are typed on the host as they come; the iPad shows only what is still being
    /// heard. Where the layout has a trackpad, in it, with Delete and Return in place of the keys beside it
    /// (`placeDictation`). Where it hasn't (landscape): a caption low between the thumbs' trackpads, and the floating microphone grows
    /// Delete above it and Return below. Started and stopped with a microphone (the edge button, the key row's,
    /// the deck's, the control strip's) or Globe twice on a hardware keyboard.
    private func setUpDictation() {
        caption.font = .systemFont(ofSize: 17, weight: .medium)
        caption.textColor = .white
        caption.numberOfLines = 2
        caption.lineBreakMode = .byTruncatingHead   // the newest words
        caption.textAlignment = .center
        captionBack.backgroundColor = UIColor(white: 0, alpha: 0.6)
        captionBack.layer.cornerRadius = 14
        captionBack.isUserInteractionEnabled = false
        captionBack.alpha = 0
        for v in [captionBack, caption] { v.translatesAutoresizingMaskIntoConstraints = false }
        captionBack.addSubview(caption)
        view.addSubview(captionBack)
        let centerX = captionBack.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        transcriptCenterX = centerX
        let bottom = captionBack.bottomAnchor.constraint(equalTo: view.topAnchor)
        captionBottom = bottom
        NSLayoutConstraint.activate([
            centerX, bottom,
            captionBack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.6),
            caption.topAnchor.constraint(equalTo: captionBack.topAnchor, constant: 8),
            caption.bottomAnchor.constraint(equalTo: captionBack.bottomAnchor, constant: -8),
            caption.leftAnchor.constraint(equalTo: captionBack.leftAnchor, constant: 16),
            caption.rightAnchor.constraint(equalTo: captionBack.rightAnchor, constant: -16),
        ])
        // The microphone's cluster: a capsule behind it and its two keys, placed around it in layout.
        clusterBack.backgroundColor = UIColor(white: 0.1, alpha: 0.55)
        clusterBack.layer.borderWidth = 1
        clusterBack.layer.borderColor = UIColor(white: 1, alpha: 0.2).cgColor
        clusterBack.layer.cornerRadius = 30
        clusterBack.isUserInteractionEnabled = false
        clusterBack.isHidden = true
        view.insertSubview(clusterBack, belowSubview: menuButton)
        for key in [clusterDelete, clusterReturn] {
            key.isHidden = true
            view.addSubview(key)
        }
        dictation.onState = { [weak self] state in self?.renderDictation(state, partial: "") }
        dictation.onPartial = { [weak self] text in
            guard let self else { return }
            self.renderDictation(self.dictation.state, partial: text)
        }
        dictation.onFinal = { [weak self] text in
            self?.video.activity.noteInput()
            self?.dictatedPhrases.append(text.count)
            self?.input.typeText(text)
        }
    }

    /// A round key of the microphone's size, for its cluster.
    private func roundKey(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor(white: 1, alpha: 0.14)
        b.layer.cornerRadius = 24
        b.bounds = CGRect(x: 0, y: 0, width: 48, height: 48)
        b.accessibilityLabel = label
        return b
    }

    /// Return: what was said is sent, and dictation stops.
    private func sendDictated() {
        video.activity.noteInput()
        returnEndsDictation()   // first: stopping types what was still being heard, which Return then sends
        tapKey(.return)
    }

    /// A Return is about to be sent while dictating (lain's key, the system keyboard's, a hardware keyboard's):
    /// what was said is done, so dictation stops (typing what was still being heard), and Delete no longer
    /// takes it back. Call before sending the Return.
    private func returnEndsDictation() {
        if dictation.isActive { dictation.stop() }
        dictatedPhrases.removeAll()
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
        let heard: String? = switch state {
        case .idle: nil
        case .preparing(let what): what
        case .listening: partial.isEmpty ? "Listening…" : partial
        case .failed(let why): why
        }
        dictationHeard = heard
        dictating.set(dictation.isActive)
        keyCapture.keyRow.setDictating(dictation.isActive)
        sideKeys.setDictating(dictation.isActive)
        placeDictation()
        renderControls()
        audio?.setMuted(dictation.isActive)
        menuButton.setImage(UIImage(systemName: dictation.isActive ? "mic.fill" : "mic"), for: .normal)
        menuButton.backgroundColor = dictation.isActive ? UIColor.systemRed.withAlphaComponent(0.85) : UIColor(white: 0.1, alpha: 0.55)
        if case .failed = state {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.dictationHeard == heard, !self.dictation.isActive else { return }
                self.dictationHeard = nil
                self.placeDictation()
            }
        }
    }

    /// Where dictation shows, in this layout. With a trackpad (the deck's, or the band's strip): what is heard
    /// is in the trackpad, and Delete and Return take the place of the keys beside it (where there are none,
    /// the system keyboard has its own). Without one (landscape): the caption low between the thumbs' trackpads, and Delete and Return
    /// around the floating microphone while it listens (with the keyboard up, or a hardware one, those keys
    /// are the keyboard's).
    private func placeDictation() {
        let pad: TrackpadStrip? = layout.deck != nil ? deck.trackpad : layout.band != nil ? trackpad : nil
        let dictating = dictation.isActive
        deck.trackpad.setTranscript(pad === deck.trackpad ? dictationHeard : nil)
        trackpad.setTranscript(pad === trackpad ? dictationHeard : nil)
        deck.setDictating(dictating)
        let bandKeys = pad === trackpad && dictating && !extraKeys.isHidden
        bandDictationKeys.isHidden = !bandKeys
        bandDictationKeys.setCompact(layout.keysBesideStrip)
        extraKeys.alpha = bandKeys ? 0 : 1

        let captioned = pad == nil ? dictationHeard : nil
        // Level with the bottom of the thumbs' trackpads; without them, just above the picture's bottom.
        captionBottom?.constant = layout.cornerPads.map(\.maxY).max() ?? layout.stream.maxY - 16
        if let captioned { caption.text = captioned }
        UIView.animate(withDuration: 0.2) { self.captionBack.alpha = captioned == nil ? 0 : 1 }

        let cluster = pad == nil && dictating && layout.edgeButton != nil
        for v in [clusterBack, clusterDelete, clusterReturn] { v.isHidden = !cluster }
        if cluster, let center = layout.edgeButton {
            // Delete above the microphone and Return below, inside the screen.
            let step: CGFloat = 58, y = min(max(center.y, step + 30), view.bounds.height - step - 30)
            menuButton.center = CGPoint(x: center.x, y: y)
            clusterDelete.center = CGPoint(x: center.x, y: y - step)
            clusterReturn.center = CGPoint(x: center.x, y: y + step)
            clusterBack.frame = CGRect(x: center.x - 30, y: y - step - 30, width: 60, height: 2 * step + 60)
        } else if let center = layout.edgeButton {
            menuButton.center = center
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
            // In the stream's own points; a touch beside the stream (under it on a phone) is not on the display.
            let p = touch.location(in: view), origin = layout.stream.origin
            // On the deck the picture stands on the hinge: a tap there would rock it, so it is only watched.
            guard layout.stream.contains(p), layout.deck == nil else { continue }
            video.cursor.pointerMoved()   // shows the cursor again after typing (§5.4)
            input.touchBegan(id: Self.id(touch), x: p.x - origin.x, y: p.y - origin.y)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .direct {
            let p = touch.location(in: view), origin = layout.stream.origin
            input.touchMoved(id: Self.id(touch), x: p.x - origin.x, y: p.y - origin.y)
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
