import AppKit
import LainClientCore
import LainProtocol
import LainTransport

@main
@MainActor
final class LainMacClientApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// As a test host (`LainMacClientTests`), the app does not start Bonjour discovery or open a session.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

    /// `NSApplication.delegate` is weak; keep the delegate strongly retained for the process lifetime.
    private static var sharedDelegate: LainMacClientApp?

    private var windowController: MacStreamWindowController?

    // Dynamic menus populated in `menuNeedsUpdate(_:)`
    private let connectionMenu = NSMenu(title: "Connection")
    private let displayMenu = NSMenu(title: "Display")
    private let inputMenu = NSMenu(title: "Input")

    static func main() {
        let app = NSApplication.shared
        let delegate = LainMacClientApp()
        sharedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        let controller = MacStreamWindowController(startSession: !Self.isTestHost)
        self.windowController = controller
        populateConnectionMenu(connectionMenu, wc: controller)
        populateDisplayMenu(displayMenu, wc: controller)
        populateInputMenu(inputMenu, wc: controller)
        if !Self.isTestHost {
            controller.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        windowController?.applicationDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        windowController?.applicationDidResignActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowController?.quitSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Main Menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About lain", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide lain", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit lain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // Connection menu
        let connItem = NSMenuItem()
        connectionMenu.delegate = self
        connItem.submenu = connectionMenu
        mainMenu.addItem(connItem)

        // Display menu
        let dispItem = NSMenuItem()
        displayMenu.delegate = self
        dispItem.submenu = displayMenu
        mainMenu.addItem(dispItem)

        // Input menu
        let inpItem = NSMenuItem()
        inputMenu.delegate = self
        inpItem.submenu = inputMenu
        mainMenu.addItem(inpItem)

        // Window menu
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winMenu.addItem(.separator())
        let fullScreen = winMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        winItem.submenu = winMenu
        mainMenu.addItem(winItem)
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let wc = windowController else { return }
        if menu === connectionMenu {
            populateConnectionMenu(menu, wc: wc)
        } else if menu === displayMenu {
            populateDisplayMenu(menu, wc: wc)
        } else if menu === inputMenu {
            populateInputMenu(menu, wc: wc)
        }
    }

    private func populateConnectionMenu(_ menu: NSMenu, wc: MacStreamWindowController) {
        menu.removeAllItems()
        let pair = menu.addItem(withTitle: "Pair Host…", action: #selector(pairHost), keyEquivalent: "")
        pair.target = self
        let manage = menu.addItem(withTitle: "Manage Paired Hosts…", action: #selector(manageHosts), keyEquivalent: "")
        manage.target = self

        let toggleTitle = wc.isDisconnectedByUser ? "Connect" : "Disconnect"
        let toggle = menu.addItem(withTitle: toggleTitle, action: #selector(toggleConnection), keyEquivalent: "")
        toggle.target = self

        let hostList = wc.currentHostList
        menu.addItem(.separator())
        let header = menu.addItem(withTitle: "Hosts", action: nil, keyEquivalent: "")
        header.isEnabled = false
        if hostList.hosts.isEmpty {
            let none = menu.addItem(withTitle: "No Paired Hosts", action: nil, keyEquivalent: "")
            none.isEnabled = false
        } else {
            let auto = menu.addItem(withTitle: "Automatic", action: #selector(selectHostItem(_:)), keyEquivalent: "")
            auto.target = self
            auto.representedObject = nil
            auto.state = hostList.selected == nil ? .on : .off
            for host in hostList.hosts {
                let suffix = host.isCurrent ? " (connected)" : (host.isSeen ? " (in reach)" : "")
                let item = menu.addItem(withTitle: host.name + suffix, action: #selector(selectHostItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = host.id
                item.state = hostList.selected == host.id ? .on : .off
            }
        }

        menu.addItem(.separator())
        let pathItem = NSMenuItem(title: "Wi-Fi Path", action: nil, keyEquivalent: "")
        let pathSub = NSMenu()
        for (title, path): (String, WiFiPath) in [
            ("Automatic", .automatic),
            ("Direct (Peer to Peer)", .direct),
            ("Through the Network", .network),
        ] {
            let item = pathSub.addItem(withTitle: title, action: #selector(selectWiFiPath(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path.rawValue
            item.state = wc.preferences.wifiPath == path ? .on : .off
        }
        pathItem.submenu = pathSub
        menu.addItem(pathItem)

        let prioItem = NSMenuItem(title: "Radio Priority", action: nil, keyEquivalent: "")
        let prioSub = NSMenu()
        for (title, prio): (String, NetworkStreamOptions.RadioPriority) in [
            ("Standard", .standard),
            ("Interactive Video", .interactiveVideo),
        ] {
            let item = prioSub.addItem(withTitle: title, action: #selector(selectRadioPriority(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = prio.rawValue
            item.state = wc.preferences.radioPriority == prio ? .on : .off
        }
        prioItem.submenu = prioSub
        menu.addItem(prioItem)

        menu.addItem(.separator())
        let sound = menu.addItem(withTitle: "Mute Host Sound", action: #selector(toggleSoundMuted), keyEquivalent: "")
        sound.target = self
        sound.state = wc.macPrefs.soundMuted ? .on : .off
    }

    private func populateDisplayMenu(_ menu: NSMenu, wc: MacStreamWindowController) {
        menu.removeAllItems()
        let hosts = wc.currentHostList

        let modeHeader = menu.addItem(withTitle: "Display Mode", action: nil, keyEquivalent: "")
        modeHeader.isEnabled = false

        let mirrorThis = menu.addItem(withTitle: "Mirror (Match Window)", action: #selector(selectMirrorMatchWindow), keyEquivalent: "")
        mirrorThis.target = self
        mirrorThis.state = (wc.preferences.mirrorDisplay && !wc.preferences.mirrorComputerNative) ? .on : .off

        let mirrorNative = menu.addItem(withTitle: "Mirror (Host's Native Display)", action: #selector(selectMirrorHostNative), keyEquivalent: "")
        mirrorNative.target = self
        mirrorNative.state = (wc.preferences.mirrorDisplay && wc.preferences.mirrorComputerNative) ? .on : .off

        let extend = menu.addItem(withTitle: "Extend Desktop", action: #selector(selectExtendDisplay), keyEquivalent: "")
        extend.target = self
        extend.state = !wc.preferences.mirrorDisplay ? .on : .off

        menu.addItem(.separator())
        let matchSize = menu.addItem(withTitle: "Resize Host Display to Match Window", action: #selector(toggleMatchWindowSize), keyEquivalent: "")
        matchSize.target = self
        matchSize.state = wc.macPrefs.matchWindowSize ? .on : .off

        if !hosts.displayScales.isEmpty, wc.preferences.wireDisplayMode != .captureExisting {
            let scaleItem = NSMenuItem(title: "Display Scale", action: nil, keyEquivalent: "")
            let scaleSub = NSMenu()
            let autoScale = scaleSub.addItem(withTitle: "Automatic (Match Screen)", action: #selector(selectDisplayScale(_:)), keyEquivalent: "")
            autoScale.target = self
            autoScale.representedObject = nil
            autoScale.state = !wc.macPrefs.hasCustomDisplayScale ? .on : .off
            scaleSub.addItem(.separator())
            for s in hosts.displayScales {
                let whole = s / 100, frac = s % 100
                let label = frac == 0 ? "\(whole)×" : (frac % 10 == 0 ? "\(whole).\(frac / 10)×" : "\(whole).\(String(format: "%02d", frac))×")
                let item = scaleSub.addItem(withTitle: label, action: #selector(selectDisplayScale(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Int(s)
                item.state = (wc.macPrefs.hasCustomDisplayScale && wc.preferences.displayScale == s) ? .on : .off
            }
            scaleItem.submenu = scaleSub
            menu.addItem(scaleItem)
        }

        menu.addItem(.separator())
        let hud = menu.addItem(withTitle: "Show Stats HUD (⌃⌥⌘L)", action: #selector(toggleHUD), keyEquivalent: "")
        hud.target = self
        hud.state = wc.streamView.isHUDVisible ? .on : .off

        let panel = menu.addItem(withTitle: "Toggle Control Panel (Hold Right ⌥)", action: #selector(togglePanel), keyEquivalent: "")
        panel.target = self
        panel.state = !wc.streamView.panelView.isHidden ? .on : .off
    }

    private func populateInputMenu(_ menu: NSMenu, wc: MacStreamWindowController) {
        menu.removeAllItems()

        let captureNow = menu.addItem(withTitle: "Capture Pointer (Relative Mode)", action: #selector(togglePointerCapture), keyEquivalent: "")
        captureNow.target = self
        captureNow.state = wc.streamView.isPointerCaptured ? .on : .off

        let captureFS = menu.addItem(withTitle: "Auto-Capture Pointer in Full Screen", action: #selector(toggleCapturePointerInFullScreen), keyEquivalent: "")
        captureFS.target = self
        captureFS.state = wc.macPrefs.capturePointerInFullScreen ? .on : .off

        menu.addItem(.separator())
        let shortcutTitle = wc.hasAccessibilityAccess
            ? "Capture System Shortcuts (⌘Tab, ⌘Space…)"
            : "Capture System Shortcuts (Needs Accessibility…)"
        let sysShortcuts = menu.addItem(withTitle: shortcutTitle, action: #selector(toggleCaptureSystemShortcuts), keyEquivalent: "")
        sysShortcuts.target = self
        sysShortcuts.state = (wc.macPrefs.captureSystemShortcuts && wc.hasAccessibilityAccess) ? .on : .off

        let release = menu.addItem(withTitle: "Release Capture (⌃⌥Esc)", action: #selector(releaseCapture), keyEquivalent: "")
        release.target = self

        menu.addItem(.separator())
        let reverseScroll = menu.addItem(withTitle: "Reverse Scroll Direction", action: #selector(toggleReverseScroll), keyEquivalent: "")
        reverseScroll.target = self
        reverseScroll.state = wc.preferences.reverseScroll ? .on : .off
    }

    // MARK: - Actions

    @objc private func pairHost() { windowController?.presentPairHost() }
    @objc private func manageHosts() { windowController?.presentManageHosts() }
    @objc private func toggleConnection() { windowController?.toggleConnection() }

    @objc private func selectHostItem(_ sender: NSMenuItem) {
        windowController?.selectHost(sender.representedObject as? String)
    }

    @objc private func selectWiFiPath(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let path = WiFiPath(rawValue: raw) else { return }
        windowController?.setWiFiPath(path)
    }

    @objc private func selectRadioPriority(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let prio = NetworkStreamOptions.RadioPriority(rawValue: raw) else { return }
        windowController?.setRadioPriority(prio)
    }

    @objc private func toggleSoundMuted() { windowController?.toggleSoundMuted() }
    @objc private func selectMirrorMatchWindow() { windowController?.setDisplayMode(mirror: true, computerNative: false) }
    @objc private func selectMirrorHostNative() { windowController?.setDisplayMode(mirror: true, computerNative: true) }
    @objc private func selectExtendDisplay() { windowController?.setDisplayMode(mirror: false, computerNative: false) }
    @objc private func toggleMatchWindowSize() { windowController?.toggleMatchWindowSize() }

    @objc private func selectDisplayScale(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? Int {
            windowController?.setDisplayScale(UInt16(v))
        } else {
            windowController?.setDisplayScale(nil)
        }
    }

    @objc private func toggleHUD() { windowController?.toggleHUD() }
    @objc private func togglePanel() { windowController?.togglePanel() }
    @objc private func togglePointerCapture() { windowController?.togglePointerCapture() }
    @objc private func toggleCapturePointerInFullScreen() { windowController?.toggleCapturePointerInFullScreen() }
    @objc private func toggleCaptureSystemShortcuts() { windowController?.toggleCaptureSystemShortcuts() }
    @objc private func releaseCapture() { windowController?.releaseCaptureAndShortcuts() }
    @objc private func toggleReverseScroll() { windowController?.toggleReverseScroll() }
}
