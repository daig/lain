import Foundation
import Dispatch
import LainProtocol
import LainTelemetry
import Testing
@testable import LainTransport

/// A client listener whose links answer `Hello` automatically (as ClientSession will).
struct ClientHarness {
    let listener: ClientLinkListener
    let links: Inbox<Link>
    let secrets: InMemorySecretStore

    init(secrets: InMemorySecretStore = InMemorySecretStore(), acceptsPairing: Bool = true) throws {
        let links = Inbox<Link>()
        self.links = links
        self.secrets = secrets
        listener = try ClientLinkListener(port: 0, secrets: secrets, acceptsPairing: acceptsPairing) { link in
            link.realtime.send(.hello(sampleHello))
            links.put(link)
        }
    }
}

@Suite(.serialized) struct LinkEstablishment {
    @Test func firstConnectionPairsThenReusesTheSecret() async throws {
        let client = try ClientHarness()
        defer { client.listener.cancel() }
        let hostSecrets = InMemorySecretStore()
        let dialer = LoopbackDialer(port: client.listener.port)

        let (link, hello, paired) = try await HostLink.open(dialer: dialer, secrets: hostSecrets, peerID: "IPAD", allowPairing: true)
        #expect(hello == sampleHello)
        #expect(paired)
        let clientLink = try #require(await client.links.next())
        #expect(clientLink.sessionToken == link.sessionToken)
        let secret = try #require(hostSecrets.secret(for: "IPAD"))
        #expect(client.secrets.secret(for: "host") == secret)
        link.close()

        // Second session: authenticated with the stored secret, no pairing.
        let (link2, _, paired2) = try await HostLink.open(dialer: dialer, secrets: hostSecrets, peerID: "IPAD", allowPairing: false)
        #expect(!paired2)
        #expect(try #require(await client.links.next()).sessionToken == link2.sessionToken)
        #expect(hostSecrets.secret(for: "IPAD") == secret)
        link2.close()
    }

    @Test func staleSecretRepairsOverUSBOnly() async throws {
        let client = try ClientHarness(secrets: InMemorySecretStore(["host": ChannelAuth.randomBytes(32)]))
        defer { client.listener.cancel() }
        let stale = ChannelAuth.randomBytes(32)
        let dialer = LoopbackDialer(port: client.listener.port)

        await #expect(throws: TransportError.authenticationFailed) {
            _ = try await HostLink.open(dialer: dialer, secrets: InMemorySecretStore(["IPAD": stale]), peerID: "IPAD",
                                        allowPairing: false)
        }
        let hostSecrets = InMemorySecretStore(["IPAD": stale])
        let (link, _, repaired) = try await HostLink.open(dialer: dialer, secrets: hostSecrets, peerID: "IPAD", allowPairing: true)
        #expect(repaired)
        #expect(hostSecrets.secret(for: "IPAD") != stale)
        #expect(hostSecrets.secret(for: "IPAD") == client.secrets.secret(for: "host"))
        link.close()
    }

    @Test func listenerWithoutPairingRejectsPairingRequests() async throws {
        let client = try ClientHarness(acceptsPairing: false)
        defer { client.listener.cancel() }
        await #expect(throws: TransportError.authenticationFailed) {
            _ = try await HostLink.open(dialer: LoopbackDialer(port: client.listener.port), secrets: InMemorySecretStore(),
                                        peerID: "IPAD", allowPairing: true)
        }
        #expect(client.secrets.secret(for: "host") == nil)
    }

    @Test func connectionsThatDoNotOpenWithChannelHelloAreClosed() async throws {
        let client = try ClientHarness()
        defer { client.listener.cancel() }
        // Wrong first message: rejected with an Error.
        let wrong = MessageChannel(stream: try TCP.connectLoopback(port: client.listener.port), label: "wrong")
        wrong.start()
        wrong.send(.ping(Ping(id: 1, sentAtNs: 1)))
        let reply = try await wrong.next(timeoutSeconds: 2)
        #expect(reply.message.type == .error)
        // Silence: closed after the hello timeout.
        let silent = MessageChannel(stream: try TCP.connectLoopback(port: client.listener.port), label: "silent")
        let closed = Inbox<Bool>()
        silent.setCloseHandler { _ in closed.put(true) }
        silent.start()
        #expect(await closed.next(within: ClientLinkListener.helloTimeout + 2) == true)
    }

    @Test func forgedVideoConnectionIsRejected() async throws {
        let client = try ClientHarness(secrets: InMemorySecretStore(["host": Array(repeating: 1, count: 32)]))
        defer { client.listener.cancel() }
        let token = ChannelAuth.randomBytes(16)
        let realtime = MessageChannel(stream: try TCP.connectLoopback(port: client.listener.port), label: "rt")
        realtime.start()
        realtime.send(.channelHello(ChannelAuth.hello(kind: .realtime, token: token, secret: Array(repeating: 1, count: 32))))
        let forged = MessageChannel(stream: try TCP.connectLoopback(port: client.listener.port), label: "forged")
        let closed = Inbox<Bool>()
        forged.setCloseHandler { _ in closed.put(true) }
        forged.start()
        forged.send(.channelHello(ChannelAuth.hello(kind: .video, token: token, secret: Array(repeating: 2, count: 32))))
        #expect(await closed.next() == true)
        #expect(await client.links.next(within: 0.3) == nil)
        realtime.close()
    }
}

#if os(macOS)
import LainTestSupport
import LainUSBMux

/// Step 5's integration test: fake usbmuxd → the client listener code (running on macOS) → full
/// ChannelHello + Hello/HelloAck handshake, then ping/pong RTT and FrameAck backpressure.
@Suite(.serialized) struct USBPathIntegration {
    @Test func handshakePingAndBackpressureOverUSBMux() async throws {
        // Client side: answers pings, acks video frames after a delay (a slow client).
        let ackDelayMs = 5
        let client = try ClientHarness()
        defer { client.listener.cancel() }
        let mux = try FakeUSBMuxd(devices: [.init(deviceID: 5, serialNumber: "IPAD-SERIAL")], targetPort: client.listener.port)
        defer { mux.stop() }

        // Host side: discover the device, dial through usbmuxd, handshake.
        let usbmux = USBMuxClient(socketPath: mux.socketPath)
        var events = usbmux.events().makeAsyncIterator()
        guard case .attached(let device) = try await events.next() else { Issue.record("no device"); return }
        let t0 = MonotonicClock.now()
        let (link, hello, _) = try await HostLink.open(dialer: USBMuxDialer(client: usbmux, deviceID: device.deviceID),
                                                   secrets: InMemorySecretStore(), peerID: device.serialNumber,
                                                   allowPairing: true)
        let handshakeMs = Double(MonotonicClock.now() - t0) / 1e6
        #expect(hello == sampleHello)
        #expect(mux.connectCount == 3)
        let clientLink = try #require(await client.links.next())

        clientLink.realtime.setHandler { env in
            switch env.message {
            case .helloAck: break
            case .ping(let p):
                clientLink.realtime.send(.pong(Pong(id: p.id, pingSentAtNs: p.sentAtNs, receivedAtNs: MonotonicClock.now(),
                                                    sentAtNs: MonotonicClock.now())))
            default: break
            }
        }
        clientLink.video.setHandler { env in
            guard case .videoFrame(let f) = env.message else { return }
            let received = MonotonicClock.now()
            clientLink.video.queue.asyncAfter(deadline: .now() + .milliseconds(ackDelayMs)) {
                clientLink.video.send(.frameAck(FrameAck(frameId: f.frameId, receivedAtNs: received, bytes: UInt32(f.data.count))))
            }
        }
        link.realtime.send(.helloAck(sampleHelloAck))

        // Ping/pong: RTT and clock offset (same clock on both sides here, so the offset must be ~0).
        let pongs = Inbox<Pong>()
        link.realtime.setHandler { env in if case .pong(let p) = env.message { pongs.put(p) } }
        var estimator = ClockOffsetEstimator()
        var rtts = RollingPercentiles(capacity: 50)
        for i in 0..<50 {
            link.realtime.send(.ping(Ping(id: UInt32(i), sentAtNs: MonotonicClock.now())))
            let p = try #require(await pongs.next())
            let sample = estimator.add(t0: p.pingSentAtNs, t1: p.receivedAtNs, t2: p.sentAtNs, t3: MonotonicClock.now())
            let s = try #require(sample)
            rtts.record(Double(s.rttNs) / 1000)
        }
        let best = try #require(estimator.best)
        #expect(abs(best.offsetNs) <= best.rttNs / 2 + 1)

        // Backpressure: offer a frame every 1 ms for 300 ms with at most 2 unacknowledged.
        let window = WindowBox(maxInFlight: 2)
        let acksDone = Inbox<Int>()
        link.video.setHandler { env in
            guard case .frameAck(let a) = env.message else { return }
            if window.ack(a.frameId) { acksDone.put(1) }
        }
        let frame = [UInt8](repeating: 0xAB, count: 256 * 1024)
        var offered = 0, sent = 0
        let deadline = MonotonicClock.now() + 300_000_000
        while MonotonicClock.now() < deadline {
            offered += 1
            if let id = window.trySend(bytes: frame.count) {
                link.video.send(.videoFrame(VideoFrame(frameId: id, configId: 1, captureTimeNs: MonotonicClock.now(),
                                                       encodeDoneNs: MonotonicClock.now(), isKeyframe: false, data: frame)))
                sent += 1
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        for _ in 0..<sent { _ = await acksDone.next(within: 2) }
        #expect(window.maxObserved <= 2)
        #expect(window.inFlight == 0)
        #expect(sent > 10 && sent < offered)   // the slow client's acks, not the socket, set the pace
        let msPerFrame = 300.0 / Double(sent)
        print(String(format: "USB-path loopback (fake usbmuxd): handshake %.1f ms | ping RTT p50 %.0f µs p95 %.0f µs | "
                     + "backpressure: %d of %d frames sent at %.1f ms/frame (ack delay %d ms, N=2)",
                     handshakeMs, rtts.p50 ?? 0, rtts.p95 ?? 0, sent, offered, msPerFrame, ackDelayMs))
        link.close()
    }
}
#endif

import Synchronization

/// FrameAckWindow under a lock, recording the peak in-flight count.
final class WindowBox: Sendable {
    private let state: Mutex<(window: FrameAckWindow, nextId: UInt32, peak: Int)>
    init(maxInFlight: Int) { state = Mutex((FrameAckWindow(maxInFlight: maxInFlight), 1, 0)) }
    func trySend(bytes: Int) -> UInt32? {
        state.withLock { s in
            guard s.window.canSend else { return nil }
            let id = s.nextId
            s.nextId += 1
            s.window.sent(frameId: id, bytes: bytes, at: MonotonicClock.now())
            s.peak = max(s.peak, s.window.inFlightCount)
            return id
        }
    }
    func ack(_ id: UInt32) -> Bool { state.withLock { $0.window.acked(frameId: id, at: MonotonicClock.now()) != nil } }
    var maxObserved: Int { state.withLock { $0.peak } }
    var inFlight: Int { state.withLock { $0.window.inFlightCount } }
}
