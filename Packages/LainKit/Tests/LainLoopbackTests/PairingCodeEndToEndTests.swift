#if os(macOS)
import CoreGraphics
import Dispatch
import Foundation
import LainInput
import LainProtocol
import LainTelemetry
import LainTestSupport
import LainTransport
import LainUSBMux
import Network
import Synchronization
import Testing
@testable import LainClientCore
@testable import LainHostCore

/// End-to-end verification of the macOS client pairing workflow over loopback TLS-PSK Wi-Fi:
/// `HostSession.createPairingCode()` stores a fresh secret and starts/refreshes its TLS-PSK listener;
/// `ClientSession(listenForUSB: false)` decodes the `lain1:...` code via `pair(code:)`, dials the
/// loopback listener with TLS-PSK, exchanges `Hello` / `HelloAck`, and flows Mac-native input
/// (`pointerMovedAbsolute`, `mouseMovedDirect`, `scrollDirect`, `keyChanged`) into the host.
@Suite(.serialized) struct PairingCodeEndToEndTests {
    final class RecordingSink: InputSink, @unchecked Sendable {
        private let events = Mutex<[String]>([])
        var recorded: [String] { events.withLock { $0 } }
        func key(_ e: KeyEvent) { events.withLock { $0.append("key:\(e.usage):\(e.isDown)") } }
        func move(_ m: PointerMove) { events.withLock { $0.append("move:\(Int(m.x.rounded())),\(Int(m.y.rounded()))") } }
        func button(_ b: PointerButton) { events.withLock { $0.append("btn:\(b.button.rawValue):\(b.isDown)") } }
        func scroll(_ s: Scroll) { events.withLock { $0.append("scroll:\(Int(s.dy.rounded())):\(s.phase.rawValue):\(s.momentumPhase.rawValue)") } }
        func releaseAll() { events.withLock { $0.append("releaseAll") } }
    }

    struct StubPower: PowerAssertions {
        func beginPreventingDisplaySleep() {}
        func endPreventingDisplaySleep() {}
        func declareUserActivity() {}
    }

    struct StubDisplay: DisplayProvider {
        func targetDisplay() -> HostDisplay {
            HostDisplay(displayID: 1, origin: .zero, pointSize: CGSize(width: 1280, height: 800))
        }
        func currentLayout(streamedID: UInt32?) -> DisplayLayout {
            DisplayLayout(displays: [
                DisplayLayout.Display(displayID: 1, x: 0, y: 0, width: 1280, height: 800, isStreamed: true),
            ])
        }
        func cursorLocation() -> CGPoint? { CGPoint(x: 640, y: 400) }
    }

    @Test func hostPairingCodeAuthenticatesMacClientOverLoopbackWiFi() async throws {
        let identity = HostIdentity(id: "A1B2C3D4-E5F6-4789-ABCD-0123456789AB", name: "Studio Mac")
        let hostSecrets = InMemorySecretStore()
        let sink = RecordingSink()
        let fakeMux = try FakeUSBMuxd(devices: [], targetPort: 0)
        defer { fakeMux.stop() }

        let host = HostSession(
            dependencies: .init(
                usbmux: USBMuxClient(socketPath: fakeMux.socketPath),
                secrets: hostSecrets,
                sink: sink,
                display: StubDisplay(),
                power: StubPower(),
                settings: { HostInputSettings(doubleClickIntervalMs: 500, keyRepeatDelayMs: 400, keyRepeatIntervalMs: 30, inputSourceID: "com.apple.keylayout.US") },
                identity: identity,
                wifi: HostWiFiConfig(options: .loopback, advertise: false)
            ),
            onStatus: { _ in }
        )
        host.start()
        defer { host.stop() }

        // Create out-of-band pairing code on the host: stores secret and starts the loopback Wi-Fi listener.
        let encoded = try host.createPairingCode()
        #expect(encoded.hasPrefix("lain1:"))

        // Wait briefly for HostWiFiListener to come up on a loopback port.
        var port: UInt16?
        for _ in 0..<60 {
            if let p = host.wifiPort { port = p; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let wifiPort = try #require(port)

        // Start a Wi-Fi-only Mac ClientSession (listenForUSB: false), unpaired at first.
        let clientSecrets = InMemorySecretStore()
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: wifiPort)!)
        let discovered = DiscoveredHost(hostId: identity.id, name: identity.name,
                                        versions: VersionList.offered.versions, endpoint: endpoint)
        let discovery = FixedHostDiscovery(hosts: [discovered], state: .searching)
        var wifi = ClientWiFiConfig(discovery: { discovery }, options: .loopback, lastHost: .memory())
        wifi.grace = 0.05

        let configured = Mutex<ClientSession.ConnectionInfo?>(nil)
        let macHello = Hello(deviceModel: "Mac16,1", pixelWidth: 2560, pixelHeight: 1600, scale: 2,
                             maxRefreshRate: 120, decodeCapabilities: [.hevcMain], keyboardType: .ansi,
                             desiredScale: 200, desiredDisplayMode: .primary)
        let client = try ClientSession(listenForUSB: false, secrets: clientSecrets, hello: macHello, wifi: wifi) { status in
            if case .connected(let info) = status, info.isConfigured {
                configured.withLock { $0 = info }
            }
        }
        defer { client.stop() }
        #expect(client.port == 0)

        // Pair using the decoded pairing code: should authenticate over TLS-PSK and reach configured state.
        let decoded = try PairingCode.decode(encoded)
        try client.pair(code: decoded)

        var info: ClientSession.ConnectionInfo?
        for _ in 0..<120 {
            if let got = configured.withLock({ $0 }) { info = got; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let connectedInfo = try #require(info)
        #expect(connectedInfo.hostName == "Studio Mac")
        #expect(connectedInfo.displayPointWidth == 1280)
        #expect(connectedInfo.displayPointHeight == 800)

        // Verify macOS-native input paths flow through to the host sink.
        client.input.setTouchSurface(width: 1280, height: 800)
        client.input.pointerMovedAbsolute(surfaceX: 300, surfaceY: 200)
        client.input.scrollDirect(dx: 0, dy: -15, phase: .began, momentumPhase: .none)
        client.input.keyChanged(.key(0x04), isDown: true)
        client.input.keyChanged(.key(0x04), isDown: false)

        for _ in 0..<60 {
            let rec = sink.recorded
            if rec.contains("move:300,200") && rec.contains("scroll:-15:2:0") && rec.contains("key:4:true") {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let rec = sink.recorded
        #expect(rec.contains("move:300,200"))
        #expect(rec.contains("scroll:-15:2:0"))
        #expect(rec.contains("key:4:true"))
        #expect(rec.contains("key:4:false"))
    }
}
#endif
