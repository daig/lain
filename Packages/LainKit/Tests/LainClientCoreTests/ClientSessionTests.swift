import Dispatch
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
        while MonotonicClock.now() < deadline {
            guard let v = await next(within: Double(deadline - MonotonicClock.now()) / 1e9) else { return nil }
            if predicate(v) { return v }
        }
        return nil
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
        #expect(session.input.cursor.x == 12 && session.input.cursor.y == 34)

        // Video frames are acked (keeps --bench usbmux working).
        let acks = Inbox<Message>()
        link.video.setHandler { acks.put($0.message) }
        link.video.send(.videoFrame(VideoFrame(frameId: 7, configId: 1, captureTimeNs: 0, encodeDoneNs: 0, isKeyframe: true,
                                                   data: [1, 2, 3])))
        let frameAck = await acks.next()
        #expect(frameAck.map { if case .frameAck(let a) = $0 { a.frameId == 7 && a.bytes == 3 } else { false } } == true)
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
}
