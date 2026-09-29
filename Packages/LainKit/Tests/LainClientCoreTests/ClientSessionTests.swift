import Dispatch
import Foundation
import LainClientCore
import LainInput
import LainProtocol
import LainTelemetry
import LainTransport
import Synchronization
import Testing

/// Thread-safe message recorder.
final class SentBox: Sendable {
    private let state = Mutex<[Message]>([])
    func append(_ m: Message) { state.withLock { $0.append(m) } }
    var messages: [Message] { state.withLock { $0 } }
}

/// Collects values from callbacks and lets tests await them.
final class Inbox<T: Sendable>: Sendable {
    private let state = Mutex<(items: [T], waiters: [(id: Int, c: CheckedContinuation<T?, Never>)], nextID: Int)>(([], [], 0))

    func put(_ v: T) {
        let waiter = state.withLock { s -> CheckedContinuation<T?, Never>? in
            if s.waiters.isEmpty { s.items.append(v); return nil }
            return s.waiters.removeFirst().c
        }
        waiter?.resume(returning: v)
    }

    /// The next value, or nil after `seconds`.
    func next(within seconds: Double = 5) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let (ready, id) = state.withLock { s -> (T?, Int) in
                if !s.items.isEmpty { return (s.items.removeFirst(), -1) }
                s.nextID += 1
                s.waiters.append((s.nextID, c))
                return (nil, s.nextID)
            }
            if let ready { c.resume(returning: ready); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                let timedOut = state.withLock { s -> CheckedContinuation<T?, Never>? in
                    guard let i = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return s.waiters.remove(at: i).c
                }
                timedOut?.resume(returning: nil)
            }
        }
    }

    /// The first value matching `predicate` within `seconds`, skipping others.
    func first(within seconds: Double = 5, where predicate: (T) -> Bool) async -> T? {
        let deadline = MonotonicClock.now() + UInt64(seconds * 1e9)
        while true {
            let now = MonotonicClock.now()   // read once: a second read could pass the deadline and trap
            guard now < deadline else { return nil }
            guard let v = await next(within: Double(deadline - now) / 1e9) else { return nil }
            if predicate(v) { return v }
        }
    }
}

let hello = Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                  decodeCapabilities: [.hevcMain], keyboardType: .ansi)

/// The host side over loopback TCP: HostLink against ClientSession's listener, as over USB.
@Suite(.serialized) struct ClientSessionTests {
    @Test func helloAckConfiguresInputAndInputReachesTheHost() async throws {
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: InMemorySecretStore(), hello: hello) { statuses.put($0) }
        defer { session.stop() }
        #expect(await statuses.next() == .listening(port: session.port))

        let (link, gotHello, paired) = try await HostLink.open(dialer: LoopbackDialer(port: session.port),
                                                               secrets: InMemorySecretStore(), peerID: "IPAD",
                                                               allowPairing: true)
        defer { link.close() }
        #expect(gotHello == hello && paired)
        let received = Inbox<Message>()
        link.realtime.setHandler { received.put($0.message) }

        link.realtime.send(.helloAck(ack))
        let configured = await statuses.first { if case .connected(let i) = $0 { i.isConfigured } else { false } }
        guard case .connected(let info) = configured else { Issue.record("no configured status"); return }
        #expect(info.displayPointWidth == 1376 && info.displayPointHeight == 1032)
        #expect(info.macInputSource == "com.apple.keylayout.Colemak")
        session.input.sync { _ in }   // configure was queued on the input queue before the status went out
        #expect(session.input.cursor.displayPointWidth == 1376)

        // Input from the pipeline arrives on the host's realtime channel, in order.
        session.input.keyChanged(.leftOption, isDown: true)
        session.input.keyChanged(.tab, isDown: true)
        session.input.mouseMoved(dx: 4, dy: 0)
        session.input.mouseButton(.left, isDown: true)
        session.input.releaseAll(.focusLost)
        var got: [Message] = []
        for _ in 0..<7 { if let m = await received.next() { got.append(m) } }
        let keys = got.compactMap { if case .keyEvent(let e) = $0 { e.usage } else { nil } }
        #expect(keys == [0xE2, 0xE2, 0xE3, 0x2B])   // Opt-Tab → Cmd-Tab
        guard got.count == 7 else { Issue.record("got \(got)"); return }
        if case .pointerMove(let m) = got[4] { #expect(m.x > 688) } else { Issue.record("expected a move: \(got[4])") }
        if case .pointerButton(let b) = got[5] { #expect(b.isDown && b.clickCount == 1) } else { Issue.record("\(got[5])") }
        #expect(got[6] == .releaseAll(ReleaseAll(reason: .focusLost)))

        // Warps from the host move the client's cursor; pings are answered.
        link.realtime.send(.cursorWarp(CursorWarp(x: 12, y: 34)))
        link.realtime.send(.ping(Ping(id: 9, sentAtNs: 1)))
        let pong = await received.first { if case .pong = $0 { true } else { false } }
        #expect(pong.map { if case .pong(let p) = $0 { p.id == 9 } else { false } } == true)
        session.input.sync { _ in }   // the warp is queued on the input queue; the Pong isn't
        #expect(session.input.cursor.x == 12 && session.input.cursor.y == 34)

        // Video frames are acked (keeps --bench usbmux working).
        let acks = Inbox<Message>()
        link.video.setHandler { acks.put($0.message) }
        link.video.send(.videoFrame(VideoFrame(frameId: 7, configId: 1, captureTimeNs: 0, encodeDoneNs: 0, isKeyframe: true,
                                                   data: [1, 2, 3])))
        let frameAck = await acks.next()
        #expect(frameAck.map { if case .frameAck(let a) = $0 { a.frameId == 7 && a.bytes == 3 } else { false } } == true)
    }

    @Test func displayLayoutGivesTheCursorTheWholeDesktop() async throws {
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: InMemorySecretStore(), hello: hello) { statuses.put($0) }
        defer { session.stop() }
        _ = await statuses.next()
        let (link, _, _) = try await HostLink.open(dialer: LoopbackDialer(port: session.port),
                                                   secrets: InMemorySecretStore(), peerID: "IPAD", allowPairing: true)
        defer { link.close() }
        let received = Inbox<Message>()
        link.realtime.setHandler { received.put($0.message) }
        link.realtime.send(.helloAck(ack))
        let layout = DisplayLayout(displays: [
            .init(displayID: 1, x: 0, y: 0, width: 1680, height: 1050, isStreamed: false),
            .init(displayID: 9, x: 0, y: 1050, width: 1376, height: 1032, isStreamed: true),
        ])
        link.realtime.send(.displayLayout(layout))
        let applied = await statuses.first { if case .connected(let i) = $0 { i.displayCount == 2 } else { false } }
        guard case .connected(let info) = applied else { Issue.record("layout not applied"); return }
        #expect(info.displayPointWidth == 1376 && info.displayPointHeight == 1032)
        session.input.sync { _ in }
        // Recentred on the streamed display, in global points.
        let c = session.input.cursor
        #expect(c.globalX == 688 && c.globalY == 1050 + 516 && c.x == 688 && c.y == 516 && c.onStream)

        // A warp onto main: off the stream, and the next move goes out in global points.
        link.realtime.send(.cursorWarp(CursorWarp(x: 500, y: 300)))
        link.realtime.send(.ping(Ping(id: 1, sentAtNs: 1)))   // handled after the warp was queued
        _ = await received.first { if case .pong = $0 { true } else { false } }
        session.input.sync { _ in }
        #expect(session.input.cursor.globalX == 500 && session.input.cursor.globalY == 300)
        #expect(!session.input.cursor.onStream && session.input.cursor.y == 300 - 1050)
        session.input.mouseMoved(dx: 0, dy: -5)
        let move = await received.first { if case .pointerMove = $0 { true } else { false } }
        guard case .pointerMove(let m) = move else { Issue.record("no move"); return }
        #expect(m.x == 500 && m.y > 300)
    }

    @Test func disconnectReleasesLocallyAndStopsSending() async throws {
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: InMemorySecretStore(), hello: hello) { statuses.put($0) }
        defer { session.stop() }
        _ = await statuses.next()
        let (link, _, _) = try await HostLink.open(dialer: LoopbackDialer(port: session.port),
                                                   secrets: InMemorySecretStore(), peerID: "IPAD", allowPairing: true)
        link.realtime.send(.helloAck(ack))
        _ = await statuses.first { if case .connected(let i) = $0 { i.isConfigured } else { false } }
        session.input.keyChanged(.leftCommand, isDown: true)
        session.input.mouseButton(.left, isDown: true)
        #expect(session.input.sync { $0.keyboard.macHeldKeys.count } == 1)

        link.close()
        let back = await statuses.first { if case .listening = $0 { true } else { false } }
        #expect(back == .listening(port: session.port))
        session.input.sync { p in
            #expect(p.keyboard.macHeldKeys.isEmpty)
            #expect(p.heldButtons.mask == 0)
        }
    }

    /// §7.7 D29: a USB `HelloAck`'s host id is recorded as `mac:<id>` (usable over Wi-Fi) only if the
    /// link authenticated with the USB account or that Mac's own: the id is public and self-asserted.
    @Test func aUSBHelloAckRecordsTheMacForWiFiOnlyUnderItsOwnAccount() async throws {
        let x = UUID().uuidString, y = UUID().uuidString
        let yours = ChannelAuth.randomBytes(32)
        let store = RecordingSecrets([PairingAccounts.mac(y): yours])
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: store, hello: hello) { statuses.put($0) }
        defer { session.stop() }
        func usbSession(claiming id: String) async throws {
            let (link, _, paired) = try await HostLink.open(dialer: LoopbackDialer(port: session.port),
                                                            secrets: InMemorySecretStore(["IPAD": yours]), peerID: "IPAD",
                                                            allowPairing: false)
            defer { link.close() }
            #expect(!paired)
            link.realtime.send(.helloAck(helloAck(hostId: id)))
            #expect(await statuses.first { isConfigured($0) } != nil)
        }
        // Authenticated as Mac Y (its Wi-Fi account), claiming X: not recorded.
        try await usbSession(claiming: x)
        #expect(store.writeCount == 0 && store.secret(for: PairingAccounts.mac(x)) == nil)
        // A malformed id isn't an account.
        try await usbSession(claiming: y.lowercased())
        #expect(store.writeCount == 0)
        // Claiming Y itself: recorded (again).
        try await usbSession(claiming: y)
        #expect(store.writeCount == 1 && store.secret(for: PairingAccounts.mac(y)) == yours)
        #expect(store.secret(for: PairingAccounts.usbHost) == nil)

        // The USB account ("host", the Mac last paired by cable) may name any id.
        store.setSecret(yours, for: PairingAccounts.usbHost)
        store.removeSecret(for: PairingAccounts.mac(y))
        try await usbSession(claiming: x)
        #expect(store.secret(for: PairingAccounts.mac(x)) == yours)
    }

    @Test func aPairedUSBLinkRecordsTheMacForWiFi() async throws {
        let x = UUID().uuidString
        let store = RecordingSecrets()
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: store, hello: hello) { statuses.put($0) }
        defer { session.stop() }
        // A pairing whose Pair carries no host id stores "host" only; its HelloAck adds mac:<id>.
        let hostStore = InMemorySecretStore()
        let (link, _, paired) = try await HostLink.open(dialer: LoopbackDialer(port: session.port), secrets: hostStore,
                                                        peerID: "IPAD", allowPairing: true)
        defer { link.close() }
        #expect(paired && store.allSecrets().keys.sorted() == [PairingAccounts.usbHost])
        link.realtime.send(.helloAck(helloAck(hostId: x)))
        #expect(await statuses.first { isConfigured($0) } != nil)
        #expect(store.secret(for: PairingAccounts.mac(x)) == hostStore.secret(for: "IPAD"))
    }

    /// §7.7 D29: a Mac on the cable that speaks another protocol version is reported, not just dropped.
    @Test func aMacOnTheCableOnAnotherProtocolVersionIsReported() async throws {
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: InMemorySecretStore(), hello: hello) { statuses.put($0) }
        defer { session.stop() }
        #expect(await statuses.next() == .listening(port: session.port))
        // A v1 host's first frame: its pairing ChannelHello, framed in v1.
        let v1 = try await LoopbackDialer(port: session.port).dial()
        defer { v1.close() }
        v1.start(queue: DispatchQueue(label: "test.v1"), onBytes: { _ in }, onClose: { _ in })
        let token = ChannelAuth.randomBytes(ChannelHello.tokenSize)
        v1.write(MessageCodec.encode(.channelHello(ChannelHello(protocolVersion: 1, connectionKind: .realtime, sessionToken: token,
                                                                hmac: ChannelAuth.pairingMAC)),
                                     sequence: 0, timestampNs: 0, version: 1))
        let status = try #require(await statuses.next())
        #expect(status == .versionMismatch(hostName: nil, remote: 1))
        #expect(ClientStatus(status).title == "The Mac runs another lain")
        #expect(ClientStatus(status).detail.contains("update lain on the Mac"))

        // The next link (the Mac updated) clears it.
        let (link, _, _) = try await HostLink.open(dialer: LoopbackDialer(port: session.port), secrets: InMemorySecretStore(),
                                                   peerID: "IPAD", allowPairing: true)
        #expect(await statuses.first { if case .connected = $0 { true } else { false } } != nil)
        link.close()
        #expect(await statuses.first { if case .listening = $0 { true } else { false } } == .listening(port: session.port))
    }
}
