import Foundation
import LainClientCore
import LainInput
import LainProtocol
import LainTransport
import Testing

@Suite struct MacClientSupportTests {
    // MARK: - MacDisplaySizing

    @Test func displaySizingStandardMacBookPro() {
        let spec = MacDisplaySizing.desired(pointWidth: 1512, pointHeight: 982, backingScale: 2.0)
        #expect(spec.pixelWidth == 3024)
        #expect(spec.pixelHeight == 1964)
        #expect(spec.scale == 2)
        #expect(spec.defaultDesiredScale == 200)
        #expect(spec.referenceWidth == 1512)
    }

    @Test func displaySizing1xExternalMonitor() {
        let spec = MacDisplaySizing.desired(pointWidth: 1920, pointHeight: 1080, backingScale: 1.0)
        #expect(spec.pixelWidth == 1920)
        #expect(spec.pixelHeight == 1080)
        #expect(spec.scale == 1)
        #expect(spec.defaultDesiredScale == 100)
        #expect(spec.referenceWidth == 1920)
    }

    @Test func displaySizing5KStudioDisplayCapsAt3840PreservingAspect() {
        let spec = MacDisplaySizing.desired(pointWidth: 2560, pointHeight: 1440, backingScale: 2.0)
        #expect(spec.pixelWidth == 3840)
        #expect(spec.pixelHeight == 2160)
        #expect(spec.scale == 2)
        #expect(spec.defaultDesiredScale == 150)
    }

    @Test func displaySizingSmallWindowClampsToMinimum480AndEven() {
        let spec = MacDisplaySizing.desired(pointWidth: 201, pointHeight: 151, backingScale: 1.0)
        #expect(spec.pixelWidth == 480)
        #expect(spec.pixelHeight == 480)
        #expect(spec.pixelWidth % 2 == 0)
        #expect(spec.pixelHeight % 2 == 0)
    }

    @Test func displaySizingNeedsUpdateUsesTolerance() {
        let a = MacDisplaySizing.desired(pointWidth: 1440, pointHeight: 900, backingScale: 2.0)
        let b = MacDisplaySizing.desired(pointWidth: 1442, pointHeight: 900, backingScale: 2.0)
        let c = MacDisplaySizing.desired(pointWidth: 1500, pointHeight: 900, backingScale: 2.0)
        #expect(!MacDisplaySizing.needsUpdate(from: a, to: b))
        #expect(MacDisplaySizing.needsUpdate(from: a, to: c))
    }

    // MARK: - MacKeyCode Reverse Mapping

    @Test func macKeyCodeReverseMappingCoversStandardAndModifierKeys() {
        // Letters, digits, control keys, arrows, left/right modifiers, fn.
        let expected: [(UInt16, PhysicalKey)] = [
            (0x00, .key(0x04)),          // A
            (0x24, .return),             // Return
            (0x30, .tab),                // Tab
            (0x31, .space),              // Space
            (0x35, .escape),             // Escape
            (0x33, .key(0x2A)),          // Backspace
            (0x7B, .key(0x50)),          // Left arrow
            (0x7C, .key(0x4F)),          // Right arrow
            (0x7D, .key(0x51)),          // Down arrow
            (0x7E, .key(0x52)),          // Up arrow
            (0x3B, .leftControl),
            (0x3E, .rightControl),
            (0x38, .leftShift),
            (0x3C, .rightShift),
            (0x3A, .leftOption),
            (0x3D, .rightOption),
            (0x37, .leftCommand),
            (0x36, .rightCommand),
            (0x39, .capsLock),
            (0x3F, .globe),
            (0x2A, .key(0x31)),          // Canonical US backslash
            (0x69, .key(0x68)),          // Canonical F13
        ]
        for (macCode, hid) in expected {
            #expect(MacKeyCode.physicalKey(forMacKeyCode: macCode) == hid)
            #expect(MacKeyCode.from(hid) == macCode)
        }
    }

    // MARK: - Pointer & Scroll Extensions

    @Test func absolutePointerMapsSurfaceCoordinatesToHostPoints() {
        var sent: [Message] = []
        let p = ClientInputPipeline(displayPointWidth: 1440, displayPointHeight: 900) { sent.append($0) }
        p.touchSurface = (720, 450)   // 2:1 scale fit
        p.pointerMovedAbsolute(surfaceX: 360, surfaceY: 225)
        // Center of 1440x900 is already (720, 450), so move to top-left quarter:
        p.pointerMovedAbsolute(surfaceX: 180, surfaceY: 112.5)
        guard case .pointerMove(let m)? = sent.last else {
            Issue.record("expected pointerMove")
            return
        }
        #expect(abs(m.x - 360) < 0.01)
        #expect(abs(m.y - 225) < 0.01)
    }

    @Test func directMouseMoveMovesOneToOneAndCrossesDisplays() {
        var sent: [Message] = []
        let p = ClientInputPipeline(displayPointWidth: 1000, displayPointHeight: 800) { sent.append($0) }
        p.applyLayout(DisplayLayout(displays: [
            DisplayLayout.Display(displayID: 1, x: 0, y: 0, width: 1000, height: 800, isStreamed: true),
            DisplayLayout.Display(displayID: 2, x: 1000, y: 0, width: 1000, height: 800, isStreamed: false),
        ]))
        // Starts centered on display 1 at (500, 400).
        p.mouseMovedDirect(dx: 600, dy: 50)
        guard case .pointerMove(let m)? = sent.last else {
            Issue.record("expected pointerMove")
            return
        }
        #expect(abs(m.x - 1100) < 0.01)
        #expect(abs(m.y - 450) < 0.01)
        #expect(!p.cursorOnStream)
    }

    @Test func scrollDirectPassesNativePhasesAndMomentumWithoutSynthesizing() {
        var sent: [Message] = []
        let p = ClientInputPipeline(displayPointWidth: 1440, displayPointHeight: 900) { sent.append($0) }
        p.scrollDirect(dx: 0, dy: -12, phase: .began, momentumPhase: .none)
        p.scrollDirect(dx: 0, dy: -8, phase: .ended, momentumPhase: .none)
        p.scrollDirect(dx: 0, dy: -5, phase: .none, momentumPhase: .began)
        p.scrollDirect(dx: 0, dy: 0, phase: .none, momentumPhase: .ended)
        // Advancing ticks must NOT emit synthesized momentum events.
        p.tick(at: 100_000_000)
        p.tick(at: 116_000_000)
        #expect(sent.count == 4)
        #expect(sent[0] == .scroll(Scroll(dx: 0, dy: -12, phase: .began, momentumPhase: .none)))
        #expect(sent[2] == .scroll(Scroll(dx: 0, dy: -5, phase: .none, momentumPhase: .began)))
    }

    // MARK: - Wi-Fi-only ClientSession & PairingCode

    @Test func wifiOnlySessionDoesNotBindUSBAndPairsViaCode() async throws {
        let store = InMemorySecretStore()
        let lastHost = LastConnectedHost.memory()
        let discovery = FixedHostDiscovery(hosts: [], state: .searching)
        let wifi = ClientWiFiConfig(discovery: { discovery }, options: .loopback, lastHost: lastHost)
        let statuses = Inbox<ClientSession.Status>()
        let macHello = Hello(deviceModel: "Mac16,1", pixelWidth: 2560, pixelHeight: 1600, scale: 2,
                             maxRefreshRate: 120, decodeCapabilities: [.hevcMain], keyboardType: .ansi,
                             desiredScale: 200, desiredDisplayMode: .primary)
        let session = try ClientSession(listenForUSB: false, secrets: store, hello: macHello, wifi: wifi) {
            statuses.put($0)
        }
        defer { session.stop() }
        #expect(session.port == 0)
        #expect(await statuses.first { $0 == .searching } == .searching)

        let hostId = UUID().uuidString
        let secret = (0..<32).map { UInt8($0 &+ 1) }
        let code = try PairingCode(hostId: hostId, secret: secret, hostName: "Linux Box")
        try session.pair(code: code)

        #expect(store.secret(for: PairingAccounts.mac(hostId)) == secret)
        let list = session.hostList()
        #expect(list.hosts.count == 1)
        #expect(list.hosts.first?.id == hostId)
        #expect(list.hosts.first?.name == "Linux Box")
        #expect(list.selected == hostId)

        try session.forgetHost(hostId)
        #expect(store.secret(for: PairingAccounts.mac(hostId)) == nil)
        #expect(session.hostList().hosts.isEmpty)
        #expect(session.hostList().selected == nil)
    }

    @Test func macControlPanelOmitsTouchModeAndUsesMacCopy() {
        let panel = ControlPanel(includeTouchMode: false, isMac: true)
        let rows = ControlPanel.rows(hosts: ClientSession.HostList(), includeTouchMode: false)
        #expect(!rows.contains(.touchMode))
        let lines = panel.lines(info: nil, video: VideoStats(), host: nil, hosts: ClientSession.HostList(),
                                preferences: ClientPreferences())
        #expect(lines.contains { $0.text.contains("Pair Host") })
        #expect(lines.contains { $0.text.contains("⌃⌥ Esc") })
    }
}
