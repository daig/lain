import AppKit
import IOKit.pwr_mgt
import LainClientCore
import LainInput
import LainProtocol
import LainTransport
import os

/// Owns the macOS client's window, `ClientSession` (Wi-Fi/LAN-only), `ClientInput`, `ClientVideoPipeline`,
/// `ClientAudioPlayer`, optional `SystemShortcutTap`, display-sleep power assertion, and dynamic window
/// display sizing.
@MainActor
final class MacStreamWindowController: NSWindowController, NSWindowDelegate {
    let input = ClientInput()
    let video = ClientVideoPipeline()
    let audio = ClientAudioPlayer()

    private(set) var session: ClientSession?
    private(set) var status = ClientStatus.searching
    private(set) var preferences: ClientPreferences
    private(set) var macPrefs: MacClientPreferences
    private var panel = ControlPanel(includeTouchMode: false, isMac: true)

    let streamView: MacStreamView
    private var shortcutTap: SystemShortcutTap?
    private var currentSizing: MacDisplaySizing.Spec
    private var isFullScreen = false
    private var isManuallyDisconnected = false
    private var shortcutsTemporarilyDisarmed = false
    private var uiTimer: Timer?
    private var sleepAssertionID: IOPMAssertionID = 0
    private var hasSleepAssertion = false
    private let log = Logger(subsystem: "lain", category: "macclient")

    init(startSession: Bool = true) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = Double(screen?.backingScaleFactor ?? 2.0)
        let refreshHz = Float(screen?.maximumFramesPerSecond ?? 60)
        let defaultRect = NSRect(x: 0, y: 0, width: 1280, height: 800)

        let initialSizing = MacDisplaySizing.desired(pointWidth: Double(defaultRect.width),
                                                     pointHeight: Double(defaultRect.height),
                                                     backingScale: scale)
        self.currentSizing = initialSizing
        let macPrefs = MacClientPreferences.load()
        self.macPrefs = macPrefs
        let prefs = ClientPreferences.load(nativeScale: initialSizing.defaultDesiredScale)
        self.preferences = prefs

        let view = MacStreamView(input: input, video: video, initialRefreshRate: refreshHz)
        self.streamView = view

        let window = NSWindow(
            contentRect: defaultRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "lain"
        window.minSize = NSSize(width: 640, height: 420)
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = view
        window.center()
        window.setFrameAutosaveName("LainMacClientMainWindow")

        super.init(window: window)
        window.delegate = self

        // Recompute sizing against the restored autosaved window frame.
        let restored = window.contentLayoutRect.size
        let restoredScale = Double(window.backingScaleFactor)
        self.currentSizing = MacDisplaySizing.desired(pointWidth: Double(restored.width),
                                                      pointHeight: Double(restored.height),
                                                      backingScale: restoredScale)
        self.preferences.nativeDisplayScale = self.currentSizing.defaultDesiredScale
        if !self.macPrefs.hasCustomDisplayScale {
            self.preferences.displayScale = self.currentSizing.defaultDesiredScale
        }

        configureInput()
        configureViewCallbacks()
        audio.setMuted(macPrefs.soundMuted)

        if startSession {
            beginSession()
            startUITimer()
        }
        refreshStatusUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Setup

    private func configureInput() {
        input.setPointerEnabled(true)
        input.setReferenceWidth(currentSizing.referenceWidth)
        input.setInvertScroll(preferences.reverseScroll)
        input.setLocalShortcutHandler { [weak self] shortcut in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch shortcut {
                case .toggleHUD: self.toggleHUD()
                case .overlay(let shown): self.setPanel(shown)
                case .panelKey(let key): self.panelKey(key)
                case .panelPointer(let dx, let dy): self.streamView.panelView.moveCursor(dx: dx, dy: dy)
                case .panelClick: self.panelClick()
                }
            }
        }

        shortcutTap = SystemShortcutTap(input: input, cursor: video.cursor) { [weak self] in
            Task { @MainActor [weak self] in
                self?.releaseCaptureAndShortcuts()
            }
        }
        syncSystemShortcutTap()
    }

    private func configureViewCallbacks() {
        streamView.onPairRequested = { [weak self] in self?.presentPairHost() }
        streamView.onReleaseCapture = { [weak self] in self?.releaseCaptureAndShortcuts() }
        streamView.onPanelRowClicked = { [weak self] row in
            guard let self else { return }
            self.apply(self.panel.click(row: row, hosts: self.hostList, preferences: self.preferences))
        }
        streamView.onPanelDismissed = { [weak self] in self?.input.closePanel() }
    }

    private func beginSession() {
        let model = ClientStatus.macHardwareModel()
        let refreshHz = UInt16(window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
        let desiredScale = macPrefs.hasCustomDisplayScale ? preferences.displayScale : currentSizing.defaultDesiredScale
        let hello = Hello(
            deviceModel: model,
            pixelWidth: currentSizing.pixelWidth,
            pixelHeight: currentSizing.pixelHeight,
            scale: currentSizing.scale,
            maxRefreshRate: refreshHz,
            decodeCapabilities: ClientVideoPipeline.probeDecodeCapabilities(),
            keyboardType: MacKeyboardInput.hostKeyboardType,
            desiredScale: desiredScale,
            desiredDisplayMode: preferences.wireDisplayMode
        )

        var wifi = ClientWiFiConfig(
            discovery: { BonjourHostDiscovery(serviceType: LainProtocol.bonjourServiceType) },
            lastHost: .userDefaults(),
            wakeOnLAN: WakeOnLAN.send
        )
        wifi.path = preferences.wifiPath
        wifi.options.radioPriority = preferences.radioPriority

        do {
            let s = try ClientSession(
                listenForUSB: false,
                secrets: KeychainSecretStore(),
                hello: hello,
                input: input,
                video: video,
                wifi: wifi
            ) { [weak self] status in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handleSessionStatus(ClientStatus(status))
                    }
                }
            }
            s.setAudioPlayer(audio)
            self.session = s
        } catch {
            status = .failed("\(error)")
            refreshStatusUI()
        }
    }

    private func startUITimer() {
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVideoState() }
        }
    }

    // MARK: - Lifecycle & Termination

    func quitSession() {
        uiTimer?.invalidate()
        uiTimer = nil
        streamView.setPointerCaptured(false, showHint: false)
        shortcutTap?.stop()
        releaseSleepAssertion()
        session?.quit()
    }

    func applicationDidBecomeActive() {
        shortcutsTemporarilyDisarmed = false
        video.requestKeyframe(.resumed)
        session?.sceneDidBecomeActive()
        syncSystemShortcutTap()
    }

    func applicationDidResignActive() {
        input.releaseAll(.focusLost)
        streamView.handleWindowKeyChanged(isKey: false)
        syncSystemShortcutTap()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        shortcutsTemporarilyDisarmed = false
        window?.makeFirstResponder(streamView)
        streamView.handleWindowKeyChanged(isKey: true)
        video.requestKeyframe(.resumed)
        if isFullScreen, macPrefs.capturePointerInFullScreen, status.isConnected, streamView.panelView.isHidden {
            streamView.setPointerCaptured(true, showHint: false)
        }
        syncSystemShortcutTap()
        updateWindowTitle()
    }

    func windowDidResignKey(_ notification: Notification) {
        input.releaseAll(.focusLost)
        streamView.handleWindowKeyChanged(isKey: false)
        syncSystemShortcutTap()
        updateWindowTitle()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        syncDisplaySizeToWindow()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        syncDisplaySizeToWindow()
        syncRefreshRate()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        syncDisplaySizeToWindow()
        syncRefreshRate()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        syncDisplaySizeToWindow()
        syncRefreshRate()
        if macPrefs.capturePointerInFullScreen, status.isConnected, streamView.panelView.isHidden {
            streamView.setPointerCaptured(true, showHint: true)
        }
        syncSystemShortcutTap()
        updateWindowTitle()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        streamView.setPointerCaptured(false, showHint: false)
        syncDisplaySizeToWindow()
        syncRefreshRate()
        syncSystemShortcutTap()
        updateWindowTitle()
    }

    // MARK: - Dynamic Display Sizing

    private func syncRefreshRate() {
        let hz = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        streamView.renderLoop?.setPreferredFrameRate(hz)
    }

    private func syncDisplaySizeToWindow() {
        guard macPrefs.matchWindowSize, let window else { return }
        let size = window.contentLayoutRect.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = Double(window.backingScaleFactor)
        let next = MacDisplaySizing.desired(pointWidth: Double(size.width), pointHeight: Double(size.height),
                                            backingScale: scale)
        guard MacDisplaySizing.needsUpdate(from: currentSizing, to: next) else { return }
        currentSizing = next
        preferences.nativeDisplayScale = next.defaultDesiredScale
        if !macPrefs.hasCustomDisplayScale {
            preferences.displayScale = next.defaultDesiredScale
        }
        input.setReferenceWidth(next.referenceWidth)
        let desiredScale = macPrefs.hasCustomDisplayScale ? preferences.displayScale : next.defaultDesiredScale
        log.notice("window display size → \(next.pixelWidth)×\(next.pixelHeight) @ \(desiredScale)")
        session?.setDesiredDisplay(pixelWidth: next.pixelWidth, pixelHeight: next.pixelHeight,
                                   desiredScale: desiredScale)
    }

    // MARK: - Session & Video State

    private func handleSessionStatus(_ newStatus: ClientStatus) {
        status = newStatus
        if newStatus.isConnected {
            acquireSleepAssertion()
            if isFullScreen, macPrefs.capturePointerInFullScreen, window?.isKeyWindow == true,
               streamView.panelView.isHidden {
                streamView.setPointerCaptured(true, showHint: true)
            }
        } else {
            releaseSleepAssertion()
            if streamView.isPointerCaptured {
                streamView.setPointerCaptured(false, showHint: false)
            }
        }
        syncSystemShortcutTap()
        refreshStatusUI()
    }

    private func refreshStatusUI() {
        let hasVideo = video.hasVideo && status.isConnected
        let showPair: Bool = switch status {
        case .searching, .waitingForMac, .needsCable, .pairingRefused: true
        default: false
        }
        streamView.updateStatus(status, hasVideo: hasVideo, showPairButton: showPair)
        updateWindowTitle()
    }

    private func refreshVideoState() {
        let hasVideoNow = video.hasVideo && status.isConnected
        streamView.updateStatus(status, hasVideo: hasVideoNow, showPairButton: {
            switch status {
            case .searching, .waitingForMac, .needsCable, .pairingRefused: true
            default: false
            }
        }())

        guard streamView.isHUDVisible || !streamView.panelView.isHidden else { return }
        let stats = video.stats()
        if streamView.isHUDVisible {
            streamView.updateHUDText(hudText(stats))
        }
        if !streamView.panelView.isHidden {
            renderPanel(stats)
        }
    }

    private func updateWindowTitle() {
        var title = "lain"
        if case .session(let info) = status {
            let name = info.hostName.isEmpty ? "Host" : info.hostName
            title = "lain — \(name) (\(ClientStatus.describe(info.transport)))"
        } else {
            title = "lain — \(status.macTitle)"
        }
        if streamView.isPointerCaptured {
            title += " · Pointer Captured"
        }
        window?.title = title
    }

    private func hudText(_ stats: VideoStats) -> String {
        var link = "no link"
        if case .session(let info) = status {
            link = ClientStatus.describe(info.transport)
                + (info.hostName.isEmpty ? "" : " · \(info.hostName)")
                + " · protocol v\(info.protocolVersion)"
            if let note = ClientStatus.olderMacNote(info) { link += "\n" + note }
        }
        return link + "\n" + stats.hudText
    }

    // MARK: - Control Panel

    private var hostList: ClientSession.HostList { session?.hostList() ?? ClientSession.HostList() }

    func togglePanel() {
        if streamView.panelView.isHidden {
            input.openPanel()
        } else {
            input.closePanel()
        }
    }

    private func setPanel(_ shown: Bool) {
        if shown && streamView.isPointerCaptured {
            // Release pointer capture so the user can move freely or click rows natively.
            streamView.setPointerCaptured(false, showHint: false)
        }
        streamView.setPanelOpen(shown)
        session?.setHostStatsInterval(ms: shown ? ControlPanel.hostStatsIntervalMs : 0)
        if shown {
            renderPanel(video.stats())
        }
        syncSystemShortcutTap()
        updateWindowTitle()
    }

    private func renderPanel(_ stats: VideoStats? = nil) {
        var info: ClientSession.ConnectionInfo?
        if case .session(let i) = status { info = i }
        let s = stats ?? streamView.panelView.lastStats
        streamView.panelView.lastStats = s
        guard !streamView.panelView.isHidden else { return }
        streamView.panelView.show(panel.lines(info: info, video: s, host: session?.hostStats,
                                              hosts: hostList, preferences: preferences, sound: audio.delay))
    }

    private func panelKey(_ key: PhysicalKey) {
        apply(panel.key(key, hosts: hostList, preferences: preferences))
    }

    private func panelClick() {
        guard let row = streamView.panelView.rowUnderCursor() else { return }
        apply(panel.click(row: row, hosts: hostList, preferences: preferences))
    }

    private func apply(_ action: ControlPanel.Action) {
        switch action {
        case .none:
            break
        case .close:
            input.closePanel()
            return
        case .selectHost(let id):
            selectHost(id)
        case .setPreferences(let p):
            let scaleChanged = p.displayScale != preferences.displayScale
            preferences = p
            p.save()
            if scaleChanged {
                macPrefs.hasCustomDisplayScale = true
                macPrefs.save()
            }
            applyPreferences()
        }
        renderPanel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.streamView.panelView.isHidden else { return }
            self.renderPanel()
        }
    }

    private func applyPreferences() {
        input.setInvertScroll(preferences.reverseScroll)
        session?.setNetwork(path: preferences.wifiPath, radioPriority: preferences.radioPriority)
        session?.setDesiredScale(preferences.displayScale)
        session?.setDesiredDisplayMode(preferences.wireDisplayMode)
    }

    // MARK: - Menu & User Actions

    func presentPairHost() {
        guard let window else { return }
        streamView.setPointerCaptured(false, showHint: false)
        syncSystemShortcutTap()
        PairingDialogs.presentPairHost(on: window, localHostId: nil) { [weak self] code in
            guard let self else { return }
            self.isManuallyDisconnected = false
            try self.session?.pair(code: code, select: true)
            self.streamView.showToast("Paired with \(code.hostName.isEmpty ? "host" : code.hostName)")
        }
    }

    func presentManageHosts() {
        guard let window else { return }
        streamView.setPointerCaptured(false, showHint: false)
        syncSystemShortcutTap()
        PairingDialogs.presentManageHosts(on: window, hosts: hostList.hosts) { [weak self] hostId in
            do {
                try self?.session?.forgetHost(hostId)
            } catch {
                self?.log.error("forgetHost failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func selectHost(_ id: String?) {
        isManuallyDisconnected = false
        session?.selectHost(id)
    }

    func toggleConnection() {
        if isManuallyDisconnected {
            isManuallyDisconnected = false
            session?.reconnect()
        } else {
            isManuallyDisconnected = true
            streamView.setPointerCaptured(false, showHint: false)
            session?.disconnectAndPause()
        }
    }

    var isDisconnectedByUser: Bool { isManuallyDisconnected }

    func setDisplayMode(mirror: Bool, computerNative: Bool) {
        preferences.mirrorDisplay = mirror
        preferences.mirrorComputerNative = computerNative
        preferences.save()
        session?.setDesiredDisplayMode(preferences.wireDisplayMode)
    }

    func setDisplayScale(_ scale: UInt16?) {
        if let scale {
            macPrefs.hasCustomDisplayScale = true
            macPrefs.save()
            preferences.displayScale = scale
            preferences.save()
            session?.setDesiredScale(scale)
        } else {
            macPrefs.hasCustomDisplayScale = false
            macPrefs.save()
            preferences.displayScale = currentSizing.defaultDesiredScale
            preferences.save()
            session?.setDesiredScale(currentSizing.defaultDesiredScale)
        }
    }

    func toggleMatchWindowSize() {
        macPrefs.matchWindowSize.toggle()
        macPrefs.save()
        if macPrefs.matchWindowSize {
            syncDisplaySizeToWindow()
        }
    }

    func setWiFiPath(_ path: WiFiPath) {
        preferences.wifiPath = path
        preferences.save()
        session?.setNetwork(path: path, radioPriority: preferences.radioPriority)
    }

    func setRadioPriority(_ priority: NetworkStreamOptions.RadioPriority) {
        preferences.radioPriority = priority
        preferences.save()
        session?.setNetwork(path: preferences.wifiPath, radioPriority: priority)
    }

    func toggleSoundMuted() {
        macPrefs.soundMuted.toggle()
        macPrefs.save()
        audio.setMuted(macPrefs.soundMuted)
    }

    func toggleReverseScroll() {
        preferences.reverseScroll.toggle()
        preferences.save()
        input.setInvertScroll(preferences.reverseScroll)
    }

    func togglePointerCapture() {
        let next = !streamView.isPointerCaptured
        streamView.setPointerCaptured(next, showHint: true)
        updateWindowTitle()
    }

    func toggleCapturePointerInFullScreen() {
        macPrefs.capturePointerInFullScreen.toggle()
        macPrefs.save()
        if isFullScreen {
            streamView.setPointerCaptured(macPrefs.capturePointerInFullScreen, showHint: true)
            updateWindowTitle()
        }
    }

    func toggleCaptureSystemShortcuts() {
        if !macPrefs.captureSystemShortcuts {
            if !SystemShortcutTap.hasAccess {
                _ = SystemShortcutTap.requestAccess()
                streamView.showToast("Grant Accessibility in System Settings, then re-enable Capture System Shortcuts", duration: 4.5)
                return
            }
            macPrefs.captureSystemShortcuts = true
            macPrefs.save()
            shortcutsTemporarilyDisarmed = false
            syncSystemShortcutTap()
            streamView.showToast("System shortcuts captured while focused · ⌃⌥Esc to release")
        } else {
            macPrefs.captureSystemShortcuts = false
            macPrefs.save()
            syncSystemShortcutTap()
        }
    }

    func releaseCaptureAndShortcuts() {
        let wasCaptured = streamView.isPointerCaptured
        let wasCapturingShortcuts = macPrefs.captureSystemShortcuts && !shortcutsTemporarilyDisarmed
        streamView.setPointerCaptured(false, showHint: false)
        shortcutsTemporarilyDisarmed = true
        syncSystemShortcutTap()
        input.releaseAll(.pointerLockLost)
        updateWindowTitle()
        if wasCaptured || wasCapturingShortcuts {
            streamView.showToast("Released pointer & system shortcuts")
        }
    }

    func toggleHUD() {
        let next = !streamView.isHUDVisible
        streamView.setHUDVisible(next, text: next ? hudText(video.stats()) : nil)
    }

    private func syncSystemShortcutTap() {
        let shouldRun = macPrefs.captureSystemShortcuts && SystemShortcutTap.hasAccess
        if shouldRun {
            _ = shortcutTap?.start()
        } else {
            shortcutTap?.stop()
        }
        let active = shouldRun
            && !shortcutsTemporarilyDisarmed
            && status.isConnected
            && streamView.panelView.isHidden
            && (window?.isKeyWindow == true)
            && NSApp.isActive
        shortcutTap?.setActive(active)
        streamView.capturesSystemShortcuts = active
    }

    // MARK: - Power Assertion (Prevent Display Sleep While Connected)

    private func acquireSleepAssertion() {
        guard !hasSleepAssertion else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "lain remote desktop session" as CFString,
            &sleepAssertionID
        )
        if result == kIOReturnSuccess {
            hasSleepAssertion = true
        }
    }

    private func releaseSleepAssertion() {
        guard hasSleepAssertion else { return }
        IOPMAssertionRelease(sleepAssertionID)
        sleepAssertionID = 0
        hasSleepAssertion = false
    }

    // MARK: - Menu Introspection

    var currentHostList: ClientSession.HostList { hostList }
    var hasAccessibilityAccess: Bool { SystemShortcutTap.hasAccess }
}
