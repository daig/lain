#if os(macOS)
import CoreGraphics
import LainProtocol
import LainTestSupport
import LainTransport
import LainUSBMux
import Synchronization
import Testing
@testable import LainHostCore
@testable import LainTransport

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

        init(cursor: CGPoint? = nil, devices: [FakeUSBMuxd.Device] = [.init(deviceID: 7, serialNumber: "IPAD-7")],
             tuning: HostSession.Tuning = HostSession.Tuning()) throws {
            client = try FakeClient()
            mux = try FakeUSBMuxd(devices: devices, targetPort: client.listener.port)
            self.cursor = FakeDisplay(display: HostSessionTests.display, cursor: cursor)
            let deps = HostSession.Dependencies(
                usbmux: USBMuxClient(socketPath: mux.socketPath), secrets: InMemorySecretStore(), sink: sink,
                display: self.cursor, power: power, settings: { HostSessionTests.settings })
            let statuses = statuses
            session = HostSession(dependencies: deps, tuning: tuning) { statuses.put($0) }
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
        #expect(rig.sink.calls.first == .keyboardType(.iso))

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
        // The scroll the client began is ended by the host: the client can't once the link is gone.
        #expect(rig.sink.inputCalls == expected + [.scroll(Scroll(dx: 0, dy: 0, phase: .cancelled, momentumPhase: .none)),
                                                   .releaseAll])
        // (The session redials the still-attached fake iPad right away, so check the release count.)
        #expect(await eventually { rig.power.ends >= 1 })
        // Declared off the realtime queue (a utility queue), so it may land after everything above.
        #expect(await eventually { rig.power.activityCount >= 1 })
        // The iPad is still attached, so the session goes back to dialing it.
        #expect(await rig.statuses.first { $0 == .connecting } != nil)
    }

    @Test func realCursorIsReflectedAsGlobalWarp() async throws {
        // Warps are global points: the client's cursor roams the whole desktop.
        let rig = try Rig(cursor: CGPoint(x: 300, y: 250))
        defer { rig.tearDown() }
        _ = try await rig.connect()
        let warp = await rig.client.received.first { if case .cursorWarp = $0 { true } else { false } }
        #expect(warp == .cursorWarp(CursorWarp(x: 300, y: 250)))

        // The Mac's own mouse moves it later, onto another display: reflected as is (no clamping).
        rig.cursor.cursor.withLock { $0 = CGPoint(x: -1500, y: 700) }
        let second = await rig.client.received.first { if case .cursorWarp = $0 { true } else { false } }
        #expect(second == .cursorWarp(CursorWarp(x: -1500, y: 700)))
    }

    static let desktop = DisplayLayout(displays: [
        .init(displayID: 1, x: 0, y: 0, width: 1680, height: 1050, isStreamed: false),
        .init(displayID: 9, x: 0, y: 1050, width: 1376, height: 1032, isStreamed: true),
        .init(displayID: 4, x: -1920, y: 0, width: 1920, height: 1080, isStreamed: false),
    ])

    @Test func displayLayoutFollowsHelloAck() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.cursor.layout.withLock { $0 = Self.desktop }
        _ = try await rig.connect()
        // The very next realtime message after HelloAck is the layout (before any warp).
        let next = await rig.client.received.next(within: 5)
        #expect(next == .displayLayout(Self.desktop))
    }

    @Test func displayChangeSendsANewLayoutWithoutReconnecting() async throws {
        var tuning = HostSession.Tuning()
        tuning.displayCheckIntervalNs = 20_000_000
        let rig = try Rig(tuning: tuning)
        defer { rig.tearDown() }
        rig.cursor.layout.withLock { $0 = Self.desktop }
        let (link, _) = try await rig.connect()
        #expect(await rig.client.received.first { $0 == .displayLayout(Self.desktop) } != nil)
        link.realtime.send(.keyEvent(KeyEvent(usage: 0x04, isDown: true, modifiers: [])))
        #expect(await eventually { rig.sink.inputCalls.count == 1 })

        // "More Space" on the iPad display and the side monitor unplugged, while connected.
        let changed = DisplayLayout(displays: [
            .init(displayID: 1, x: 0, y: 0, width: 1680, height: 1050, isStreamed: false),
            .init(displayID: 9, x: 0, y: 1050, width: 1600, height: 1200, isStreamed: true),
        ])
        rig.cursor.layout.withLock { $0 = changed }
        #expect(await rig.client.received.first { $0 == .displayLayout(changed) } != nil)
        // Sent once per change, and the session goes on: no new link, nothing released, input still flows.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await rig.client.received.first(within: 0.1) { if case .displayLayout = $0 { true } else { false } } == nil)
        #expect(await rig.client.links.next(within: 0.1) == nil)
        #expect(!rig.sink.inputCalls.contains(.releaseAll))
        #expect(rig.session.status == .connected(deviceModel: "iPad16,6"))
        link.realtime.send(.keyEvent(KeyEvent(usage: 0x04, isDown: false, modifiers: [])))
        #expect(await eventually { rig.sink.inputCalls.count == 2 })
    }

    @Test func aWarpIsResentAfterANewLayout() async throws {
        var tuning = HostSession.Tuning()
        tuning.displayCheckIntervalNs = 20_000_000
        let rig = try Rig(cursor: CGPoint(x: 300, y: 250), tuning: tuning)
        defer { rig.tearDown() }
        rig.cursor.layout.withLock { $0 = Self.desktop }
        _ = try await rig.connect()
        #expect(await rig.client.received.first { $0 == .cursorWarp(CursorWarp(x: 300, y: 250)) } != nil)
        // The owner drags the streamed display left of main with the cursor on it: the cursor's new
        // position is reported before the layout that contains it reaches the client.
        rig.cursor.cursor.withLock { $0 = CGPoint(x: -1000, y: 500) }
        #expect(await rig.client.received.first { $0 == .cursorWarp(CursorWarp(x: -1000, y: 500)) } != nil)
        let moved = DisplayLayout(displays: [
            .init(displayID: 1, x: 0, y: 0, width: 1680, height: 1050, isStreamed: false),
            .init(displayID: 9, x: -1376, y: 0, width: 1376, height: 1032, isStreamed: true),
        ])
        rig.cursor.layout.withLock { $0 = moved }
        #expect(await rig.client.received.first { $0 == .displayLayout(moved) } != nil)
        // So it is sent again after the layout (the client may have clamped the first one).
        let again = await rig.client.received.first(within: 2) { if case .cursorWarp = $0 { true } else { false } }
        #expect(again == .cursorWarp(CursorWarp(x: -1000, y: 500)))
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

    @Test func detachDuringMomentumEndsItOnTheMac() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let (link, _) = try await rig.connect()
        link.realtime.send(.scroll(Scroll(dx: 0, dy: -8, phase: .began, momentumPhase: .none)))
        link.realtime.send(.scroll(Scroll(dx: 0, dy: 0, phase: .ended, momentumPhase: .none)))
        link.realtime.send(.scroll(Scroll(dx: 0, dy: -30, phase: .none, momentumPhase: .began)))
        #expect(await eventually { rig.sink.inputCalls.count == 3 })
        rig.mux.detach(deviceID: 7)   // the fling's momentum-ended will never arrive from the client
        #expect(await eventually { rig.sink.inputCalls.last == .releaseAll })
        #expect(Array(rig.sink.inputCalls.dropFirst(3)) == [.scroll(Scroll(dx: 0, dy: 0, phase: .none, momentumPhase: .ended)),
                                                            .releaseAll])
    }

    /// Lets a test's hook reach the session it is built into.
    final class SessionRef: Sendable {
        let session = Mutex<HostSession?>(nil)
        var status: HostStatus? { session.withLock { $0?.status } }
    }

    @Test func detachRightAfterRegistrationLeavesNoAssertionAndNoConnectedStatus() async throws {
        let ref = SessionRef()
        let once = Mutex(false)
        let muxRef = Mutex<FakeUSBMuxd?>(nil)
        var tuning = HostSession.Tuning()
        // The iPad goes away between registering the connection and taking the power assertion.
        tuning.afterRegistering = {
            guard once.withLock({ o in defer { o = true }; return !o }) else { return }
            muxRef.withLock { $0 }?.detach(deviceID: 7)
            let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
            while ref.status != .waitingForIPad, DispatchTime.now().uptimeNanoseconds < deadline { usleep(1000) }
        }
        let rig = try Rig(tuning: tuning)
        defer { rig.tearDown() }
        ref.session.withLock { $0 = rig.session }
        muxRef.withLock { $0 = rig.mux }
        rig.session.start()
        #expect(await eventually { once.withLock { $0 } && rig.session.status == .waitingForIPad })
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.session.status == .waitingForIPad)
        #expect(!rig.power.holding)
        #expect(rig.power.begins == rig.power.ends)
        #expect(rig.sink.inputCalls == [.releaseAll])
    }

    @Test func aDeviceWithoutLainDoesNotBlockTheIPad() async throws {
        var tuning = HostSession.Tuning()
        tuning.fastRetries = 2
        tuning.fastRetryInterval = .milliseconds(10)
        tuning.slowRetryInterval = .milliseconds(50)
        // usbmuxd lists an iPhone (charging, no lain) before the iPad.
        let rig = try Rig(devices: [.init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false),
                                    .init(deviceID: 7, serialNumber: "IPAD-7")], tuning: tuning)
        defer { rig.tearDown() }
        _ = try await rig.connect()
        #expect(await rig.statuses.first { $0 == .connected(deviceModel: "iPad16,6") } != nil)
    }

    @Test func theIPadIsDialedWhenTheActiveDeviceDetaches() async throws {
        var tuning = HostSession.Tuning()
        tuning.fastRetries = 1_000   // never hands off on its own
        tuning.fastRetryInterval = .milliseconds(10)
        let rig = try Rig(devices: [.init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false),
                                    .init(deviceID: 7, serialNumber: "IPAD-7")], tuning: tuning)
        defer { rig.tearDown() }
        rig.session.start()
        #expect(await eventually { rig.mux.connectCount == 0 && rig.session.status == .connecting })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await rig.client.links.next(within: 0.1) == nil)   // only the iPhone is being dialed
        rig.mux.detach(deviceID: 3)
        #expect(await rig.client.links.next(within: 5) != nil)
        #expect(await rig.statuses.first { $0 == .connected(deviceModel: "iPad16,6") } != nil)
    }

    /// lain on the iPad speaking another protocol, behind the fake usbmuxd (§7.7 D29 decision 4): a v1
    /// app can't parse our frames and closes each connection without a word (`answer` nil); a newer one
    /// answers in its own framing, then closes.
    final class OtherProtocolIPad: Sendable {
        final class Sockets: Sendable { let all = Mutex<[SocketStream]>([]) }
        let listener: TCPListener
        private let sockets = Sockets()

        init(answer: [UInt8]?) throws {
            let sockets = sockets, queue = DispatchQueue(label: "test.other-protocol")
            listener = try TCPListener(port: 0, queue: queue) { socket in
                sockets.all.withLock { $0.append(socket) }
                socket.start(queue: queue, onBytes: { [weak socket] _ in
                    if let answer { socket?.write(answer) }
                    socket?.close()
                }, onClose: { _ in })
            }
        }

        func cancel() {
            listener.cancel()
            sockets.all.withLock { $0.forEach { $0.close() } }
        }

        /// A host session dialing it, with the statuses it publishes.
        func session(retryEvery interval: Duration) throws -> (HostSession, FakeUSBMuxd, Inbox<HostStatus>) {
            let mux = try FakeUSBMuxd(devices: [.init(deviceID: 7, serialNumber: "IPAD-7")], targetPort: listener.port)
            var tuning = HostSession.Tuning()
            tuning.fastRetryInterval = interval
            let statuses = Inbox<HostStatus>()
            let deps = HostSession.Dependencies(
                usbmux: USBMuxClient(socketPath: mux.socketPath), secrets: InMemorySecretStore(), sink: RecordingSink(),
                display: FakeDisplay(display: HostSessionTests.display, cursor: nil), power: RecordingPower(),
                settings: { HostSessionTests.settings })
            return (HostSession(dependencies: deps, tuning: tuning) { statuses.put($0) }, mux, statuses)
        }
    }

    @Test func aV1AppClosingRightAfterChannelHelloIsAskedToUpdate() async throws {
        let ipad = try OtherProtocolIPad(answer: nil)
        defer { ipad.cancel() }
        let (session, mux, statuses) = try ipad.session(retryEvery: .milliseconds(250))
        defer { session.stop(); mux.stop() }
        session.start()
        // Dialing as usual until it has closed on us three times in a row: three link attempts of three
        // connections each (the fourth is 250 ms away).
        #expect(await statuses.first { $0 == .connecting } != nil)
        #expect(await statuses.next() == HostStatus.iPadNeedsUpdate)
        #expect(mux.connectCount == 9)
        #expect(session.status.title == "Error: lain on the iPad speaks another protocol: update it")
        // Unplugged, it is just waiting again.
        mux.detach(deviceID: 7)
        #expect(await statuses.first { $0 == .waitingForIPad } != nil)
    }

    @Test func aNewerAppAnsweringVersionMismatchIsAskedToUpdate() async throws {
        let answer = MessageCodec.encode(.error(ErrorMessage(code: .versionMismatch, message: "lain here speaks protocol v3")),
                                         sequence: 0, timestampNs: 0, version: 3)
        let ipad = try OtherProtocolIPad(answer: answer)
        defer { ipad.cancel() }
        let (session, mux, statuses) = try ipad.session(retryEvery: .seconds(1))
        defer { session.stop(); mux.stop() }
        session.start()
        #expect(await statuses.first { $0 == HostStatus.iPadNeedsUpdate } != nil)
        #expect(mux.connectCount == 3)   // the first link attempt said so
    }

    @Test func sameDeviceReattachFinishesTheOldConnectionFirst() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let (link, _) = try await rig.connect()
        link.realtime.send(.keyEvent(KeyEvent(usage: 0x04, isDown: true, modifiers: [])))
        #expect(await eventually { rig.sink.inputCalls.count == 1 })
        rig.mux.attach(.init(deviceID: 7, serialNumber: "IPAD-7"))
        #expect(await rig.client.links.next(within: 5) != nil)
        #expect(await eventually { rig.power.holding && rig.power.begins == 2 })
        #expect(rig.power.ends == 1)
        let calls = rig.sink.calls
        let release = try #require(calls.firstIndex(of: .releaseAll))
        let secondSetup = try #require(calls.indices.filter { calls[$0] == .keyboardType(.iso) }.dropFirst().first)
        #expect(release < secondSetup)
        #expect(calls.filter { $0 == .releaseAll }.count == 1)
    }
}

/// `HostConnection` teardown ordering, without a socket.
@Suite struct HostConnectionTests {
    func makeConnection() -> (HostConnection, RecordingSink, RecordingPower) {
        let sink = RecordingSink(), power = RecordingPower()
        func channel() -> MessageChannel { MessageChannel(stream: MemoryStream.pair().0, label: "test") }
        let link = Link(sessionToken: [], realtime: channel(), video: channel(), audio: channel())
        let deps = HostSession.Dependencies(secrets: InMemorySecretStore(), sink: sink,
                                            display: FakeDisplay(display: HostSessionTests.display, cursor: nil),
                                            power: power, settings: { HostSessionTests.settings })
        return (HostConnection(link: link, display: HostSessionTests.display, deps: deps, tuning: .init()), sink, power)
    }

    @Test func inputHandledAfterFinishIsDropped() {
        let (connection, sink, power) = makeConnection()
        #expect(connection.start())
        let a = KeyEvent(usage: 0x04, isDown: true, modifiers: [])
        connection.handle(.keyEvent(a))
        connection.finish()
        // Buffered input drained after the release must not press anything again (invariant 4).
        connection.handle(.keyEvent(KeyEvent(usage: 0x05, isDown: true, modifiers: [])))
        connection.handle(.pointerButton(PointerButton(button: .left, isDown: true, clickCount: 1, x: 1, y: 1, modifiers: [])))
        #expect(sink.inputCalls == [.key(a), .releaseAll])
        #expect(power.begins == 1 && power.ends == 1 && !power.holding)
    }

    @Test func startAfterFinishTakesNoAssertion() {
        let (connection, _, power) = makeConnection()
        connection.finish()   // a detach or stop raced the handshake
        #expect(!connection.start())
        #expect(power.begins == 0 && !power.holding)
    }
}

@Suite struct InboxTests {
    @Test func aStaleTimerDoesNotEndALaterWait() async {
        let inbox = Inbox<Int>()
        Task { try? await Task.sleep(for: .milliseconds(20)); inbox.put(1) }
        #expect(await inbox.next(within: 0.2) == 1)   // answered; its 0.2 s timer is still pending
        Task { try? await Task.sleep(for: .milliseconds(500)); inbox.put(2) }
        #expect(await inbox.next(within: 5) == 2)     // must not get nil from the old timer at 0.2 s
    }
}
#endif
