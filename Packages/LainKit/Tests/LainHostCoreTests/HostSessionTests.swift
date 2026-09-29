#if os(macOS)
import CoreGraphics
import LainProtocol
import LainTestSupport
import LainTransport
import LainUSBMux
import Testing
@testable import LainHostCore

/// HostSession end to end: fake usbmuxd → a minimal fake client built from `ClientLinkListener`.
@Suite(.serialized) struct HostSessionTests {
    static let hello = Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                             decodeCapabilities: [.hevcMain, .hevcMain44410Hardware], keyboardType: .iso)
    static let display = HostDisplay(displayID: 1, origin: CGPoint(x: 100, y: 50), pointSize: CGSize(width: 1512, height: 982))
    static let settings = HostInputSettings(doubleClickIntervalMs: 500, keyRepeatDelayMs: 225, keyRepeatIntervalMs: 30,
                                            inputSourceID: "com.apple.keylayout.Colemak")

    /// The fake iPad: sends `Hello` on every link and records what the host sends on realtime.
    final class FakeClient: Sendable {
        let received = Inbox<Message>()
        let links = Inbox<Link>()
        let listener: ClientLinkListener

        init() throws {
            let received = received, links = links
            listener = try ClientLinkListener(port: 0, secrets: InMemorySecretStore(), acceptsPairing: true) { link in
                link.realtime.setHandler { env in received.put(env.message) }
                link.video.setHandler { _ in }
                link.audio.setHandler { _ in }
                link.realtime.send(.hello(HostSessionTests.hello))
                links.put(link)
            }
        }
    }

    struct Rig {
        let client: FakeClient
        let mux: FakeUSBMuxd
        let sink = RecordingSink()
        let power = RecordingPower()
        let cursor: FakeDisplay
        let statuses = Inbox<HostStatus>()
        let session: HostSession

        init(cursor: CGPoint? = nil) throws {
            client = try FakeClient()
            mux = try FakeUSBMuxd(devices: [.init(deviceID: 7, serialNumber: "IPAD-7")], targetPort: client.listener.port)
            self.cursor = FakeDisplay(display: HostSessionTests.display, cursor: cursor)
            let deps = HostSession.Dependencies(
                usbmux: USBMuxClient(socketPath: mux.socketPath), secrets: InMemorySecretStore(), sink: sink,
                display: self.cursor, power: power, settings: { HostSessionTests.settings })
            let statuses = statuses
            session = HostSession(dependencies: deps) { statuses.put($0) }
        }

        func tearDown() {
            session.stop()
            mux.stop()
            client.listener.cancel()
        }

        func connect() async throws -> (Link, HelloAck) {
            session.start()
            let link = try #require(await client.links.next(within: 5))
            let ack = await client.received.first { if case .helloAck = $0 { true } else { false } }
            guard case .helloAck(let helloAck) = try #require(ack) else { throw CancellationError() }
            return (link, helloAck)
        }
    }

    @Test func handshakeInputAndReleaseOnClose() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let (link, ack) = try await rig.connect()

        #expect(ack == HelloAck.host(display: Self.display, settings: Self.settings))
        #expect(ack.displayPointWidth == 1512 && ack.displayPointHeight == 982)
        #expect(ack.doubleClickIntervalMs == 500 && ack.keyRepeatDelayMs == 225 && ack.keyRepeatIntervalMs == 30)
        #expect(ack.macInputSource == "com.apple.keylayout.Colemak")
        #expect(ack.chroma == .yuv444 && ack.bitDepth == 10 && ack.displayMode == .extend && ack.refreshRate == 120)
        #expect(await rig.statuses.first { $0 == .connected(deviceModel: "iPad16,6") } != nil)
        #expect(rig.power.holding)
        #expect(rig.sink.calls.prefix(2) == [.keyboardType(.iso), .displayOrigin(CGPoint(x: 100, y: 50))])

        let inputs: [Message] = [
            .keyEvent(KeyEvent(usage: 0xE3, isDown: true, modifiers: [.command])),
            .pointerMove(PointerMove(x: 10, y: 20, dx: 1, dy: 2, buttons: 0)),
            .pointerButton(PointerButton(button: .left, isDown: true, clickCount: 1, x: 10, y: 20, modifiers: [.command])),
            .pointerMove(PointerMove(x: 12, y: 24, dx: 2, dy: 4, buttons: 1)),
            .pointerButton(PointerButton(button: .left, isDown: false, clickCount: 1, x: 12, y: 24, modifiers: [.command])),
            .scroll(Scroll(dx: 0, dy: -8, phase: .began, momentumPhase: .none)),
            .keyEvent(KeyEvent(usage: 0xE3, isDown: false, modifiers: [])),
        ]
        for m in inputs { link.realtime.send(m) }
        let expected: [RecordingSink.Call] = inputs.compactMap {
            switch $0 {
            case .keyEvent(let e): .key(e)
            case .pointerMove(let m): .move(m)
            case .pointerButton(let b): .button(b)
            case .scroll(let s): .scroll(s)
            default: nil
            }
        }
        #expect(await eventually { rig.sink.inputCalls.count >= expected.count })
        #expect(rig.sink.inputCalls == expected)

        // Ping is answered with a Pong echoing t0.
        link.realtime.send(.ping(Ping(id: 9, sentAtNs: 1234)))
        let pong = await rig.client.received.first { if case .pong = $0 { true } else { false } }
        guard case .pong(let p) = try #require(pong) else { return }
        #expect(p.id == 9 && p.pingSentAtNs == 1234)

        link.close()
        #expect(await eventually { rig.sink.inputCalls.last == .releaseAll })
        #expect(rig.sink.inputCalls == expected + [.releaseAll])
        // (The session redials the still-attached fake iPad right away, so check the release count.)
        #expect(await eventually { rig.power.ends >= 1 })
        #expect(rig.power.activityCount >= 1)
        // The iPad is still attached, so the session goes back to dialing it.
        #expect(await rig.statuses.first { $0 == .connecting } != nil)
    }

    @Test func realCursorIsReflectedAsWarp() async throws {
        // Global (300, 250) on a display at (100, 50) → (200, 200) display-relative.
        let rig = try Rig(cursor: CGPoint(x: 300, y: 250))
        defer { rig.tearDown() }
        _ = try await rig.connect()
        let warp = await rig.client.received.first { if case .cursorWarp = $0 { true } else { false } }
        #expect(warp == .cursorWarp(CursorWarp(x: 200, y: 200)))

        // The Mac's own mouse moves it later: reflected again once no input is in flight.
        rig.cursor.cursor.withLock { $0 = CGPoint(x: 5000, y: -10) }   // clamped to the display
        let second = await rig.client.received.first { if case .cursorWarp = $0 { true } else { false } }
        #expect(second == .cursorWarp(CursorWarp(x: 1512, y: 0)))
    }

    @Test func detachReleasesEverything() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let (link, _) = try await rig.connect()
        link.realtime.send(.keyEvent(KeyEvent(usage: 0x04, isDown: true, modifiers: [])))
        #expect(await eventually { rig.sink.inputCalls.count == 1 })
        rig.mux.detach(deviceID: 7)
        #expect(await eventually { rig.sink.inputCalls.last == .releaseAll })
        #expect(await rig.statuses.first { $0 == .waitingForIPad } != nil)
        #expect(await eventually { !rig.power.holding })
        #expect(rig.sink.inputCalls.filter { $0 == .releaseAll }.count == 1)
    }

    @Test func stopReleasesEverything() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let (link, _) = try await rig.connect()
        link.realtime.send(.keyEvent(KeyEvent(usage: 0x04, isDown: true, modifiers: [])))
        #expect(await eventually { rig.sink.inputCalls.count == 1 })
        rig.session.stop()
        // Synchronous: released before stop() returns.
        #expect(rig.sink.inputCalls.last == .releaseAll)
        #expect(!rig.power.holding)
    }
}
#endif
