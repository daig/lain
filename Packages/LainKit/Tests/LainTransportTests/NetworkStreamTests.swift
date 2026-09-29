import Darwin
import Dispatch
import Foundation
import LainProtocol
import LainTelemetry
import Network
import Synchronization
import Testing
@testable import LainTransport

// Loopback only (D29 test rules): listeners bind 127.0.0.1 and are never advertised, nothing browses,
// every dial goes to 127.0.0.1. These also run on the iOS simulator, where the iPad's TLS client is.

let wifiPSKA = WiFiPSK(secret: Array(0..<32))
let wifiPSKB = WiFiPSK(secret: [UInt8](repeating: 0xA5, count: 32))

/// A loopback TLS-PSK listener and what it hands over or rejects.
struct LoopbackTLSServer {
    let listener: NetworkStreamListener
    let port: UInt16
    let accepted: Inbox<NetworkStream>
    let rejected: Inbox<NetworkStreamError>

    init(psks: [WiFiPSK], handshakeTimeout: Double = NetworkStreamListener.handshakeTimeout) async throws {
        let accepted = Inbox<NetworkStream>(), rejected = Inbox<NetworkStreamError>(), ready = Inbox<UInt16>()
        listener = try NetworkStreamListener(psks: psks, options: .loopback, handshakeTimeout: handshakeTimeout,
                                             onEvent: { event in
                                                 switch event {
                                                 case .state(.ready(let port)): ready.put(port)
                                                 case .rejected(let error): rejected.put(error)
                                                 default: break
                                                 }
                                             }, onAccept: { accepted.put($0) })
        guard let port = await ready.next() else {
            listener.cancel()
            throw TransportError.timeout
        }
        self.port = port
        self.accepted = accepted
        self.rejected = rejected
    }

    var endpoint: NWEndpoint { .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!) }

    func dialer(_ psk: WiFiPSK, timeout: Double = NetworkStreamDialer.defaultTimeout) -> NetworkStreamDialer {
        NetworkStreamDialer(endpoint: endpoint, psk: psk, options: .loopback, timeout: timeout)
    }

    /// Dials with `psk` and returns both ends.
    func pair(_ psk: WiFiPSK = wifiPSKA) async throws -> (client: NetworkStream, server: NetworkStream) {
        let client = try await dialer(psk).connect(kind: nil)
        guard let server = await accepted.next() else { throw TransportError.timeout }
        return (client, server)
    }
}

/// Records what a stream delivers, in delivery order: bytes, then how it closed.
final class StreamSink: Sendable {
    enum Closed: Equatable, Sendable { case clean, error(String) }

    private struct State {
        var bytes: [UInt8] = []
        var count = 0
        var closes = 0
        var bytesAfterClose = 0
    }
    private let state = Mutex(State())
    private let target: Int
    private let keep: Bool
    /// Fires once `target` bytes have arrived.
    let reached = Inbox<Int>()
    let closed = Inbox<Closed>()

    init(expecting target: Int = .max, keep: Bool = true) {
        self.target = target
        self.keep = keep
    }

    func attach(_ stream: some ByteStream) {
        stream.start(queue: DispatchQueue(label: "sink"), onBytes: { [self] in received($0) },
                     onClose: { [self] in closedWith($0) })
    }

    var bytes: [UInt8] { state.withLock { $0.bytes } }
    var count: Int { state.withLock { $0.count } }
    var closeCount: Int { state.withLock { $0.closes } }
    var bytesAfterClose: Int { state.withLock { $0.bytesAfterClose } }

    private func received(_ b: [UInt8]) {
        let hit = state.withLock { s -> Bool in
            if s.closes > 0 { s.bytesAfterClose += b.count }
            if keep { s.bytes += b }
            let before = s.count
            s.count += b.count
            return before < target && s.count >= target
        }
        if hit { reached.put(target) }
    }

    private func closedWith(_ error: (any Error)?) {
        state.withLock { $0.closes += 1 }
        closed.put(error.map { .error(String(describing: $0)) } ?? .clean)
    }
}

func patternBytes(_ count: Int, seed: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: $0 &* seed &+ $0 >> 13) } }

func writeInChunks(_ stream: NetworkStream, _ bytes: [UInt8], chunk: Int = 700_000) {
    for start in stride(from: 0, to: bytes.count, by: chunk) { stream.write(Array(bytes[start..<min(start + chunk, bytes.count)])) }
}

func secondsSince(_ t0: UInt64) -> Double { Double(MonotonicClock.now() - t0) / 1e9 }

/// Polls `condition` every 10 ms for up to `timeout` seconds.
func pollUntil(within timeout: Double = 3, _ condition: () -> Bool) async throws -> Bool {
    let deadline = MonotonicClock.now() + UInt64(timeout * 1e9)
    while !condition() {
        if MonotonicClock.now() > deadline { return false }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// A TLS peer lain didn't build, for the suite checks (D29): TLS 1.2 with `psk`, appending `suites`
/// (none: Network.framework's own choice). Loopback only; a listener's binds 127.0.0.1.
func handBuiltTLSParameters(_ psk: WiFiPSK, appending suites: [UInt16], listener: Bool = false) -> NWParameters {
    let data = { (bytes: [UInt8]) in bytes.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData }
    let tls = NWProtocolTLS.Options()
    let sec = tls.securityProtocolOptions
    sec_protocol_options_add_pre_shared_key(sec, data(psk.key), data(Array(psk.identity.utf8)))
    sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
    for suite in suites { sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: suite)!) }
    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    parameters.includePeerToPeer = false
    parameters.requiredInterfaceType = .loopback
    if listener { parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any) }
    return parameters
}

/// A closed loopback port: one the kernel just handed out, released again. (A socket kept bound but
/// not listening would be a black hole on this TCP stack, which drops the SYN instead of refusing.)
func closedLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TransportError.posix("socket", errno) }
    defer { Darwin.close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
    }
    guard ok else { throw TransportError.posix("bind", errno) }
    return UInt16(bigEndian: addr.sin_port)
}

@Suite(.serialized) struct NetworkStreams {
    @Test func echoRunsTLS12ECDHEPSKOverLoopback() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let t0 = MonotonicClock.now()
        let (client, accepted) = try await server.pair()
        let dialMs = secondsSince(t0) * 1000
        for stream in [client, accepted] {
            #expect(stream.tls == NegotiatedTLS(version: WiFiTLS.version, cipherSuite: WiFiTLS.cipherSuite))
            #expect(stream.path.kind == .loopback)
            #expect(!stream.path.interfaceName.isEmpty)
            #expect(stream.path.linkTransport == .network(interface: stream.path.interfaceName, peerToPeer: false))
            #expect(stream.pskIdentity == wifiPSKA.identity)
            #expect(stream.handshakeNs > 0 && Double(stream.handshakeNs) / 1e6 <= dialMs)
        }
        #expect(client.path.interfaceName == accepted.path.interfaceName)
        guard case .hostPort(_, let port)? = client.path.remoteEndpoint else { Issue.record("no remote endpoint"); return }
        #expect(port.rawValue == server.port)

        accepted.start(queue: DispatchQueue(label: "echo"), onBytes: { accepted.write($0) }, onClose: { _ in })
        let sink = StreamSink(expecting: 5)
        sink.attach(client)
        client.write(Array("hello".utf8))
        #expect(await sink.reached.next() == 5)
        #expect(sink.bytes == Array("hello".utf8))
        print(String(format: "NetworkStream loopback: dial %.1f ms (client start→ready %.1f ms, server TLS %.1f ms), %@ on %@",
                     dialMs, Double(client.handshakeNs) / 1e6, Double(accepted.handshakeNs) / 1e6,
                     client.tls?.description ?? "no TLS", client.path.interfaceName))
        client.close()
        #expect(await sink.closed.next() == .clean)
    }

    @Test func aWrongKeyFailsTheDialAndIsNeverHandedOver() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let forged = WiFiPSK(identity: wifiPSKA.identity, key: wifiPSKB.key)
        await #expect(throws: NetworkStreamError.wrongKey) { _ = try await server.dialer(forged).connect(kind: nil) }
        #expect(await server.rejected.next() == .wrongKey)
        #expect(await server.accepted.next(within: 0.3) == nil)
    }

    @Test func anUnknownIdentityFailsTheDialAndIsNeverHandedOver() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        await #expect(throws: NetworkStreamError.unknownIdentity) { _ = try await server.dialer(wifiPSKB).connect(kind: nil) }
        #expect(await server.rejected.next() == .unknownIdentity)
        #expect(await server.accepted.next(within: 0.3) == nil)
    }

    @Test func aConnectionThatNeverFinishesTLSIsDroppedAtTheHandshakeDeadline() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA], handshakeTimeout: 0.5)
        defer { server.listener.cancel() }
        let raw = try TCP.connectLoopback(port: server.port)   // plain TCP: never sends a ClientHello
        let rawClosed = Inbox<Bool>()
        raw.start(queue: DispatchQueue(label: "raw"), onBytes: { _ in }, onClose: { _ in rawClosed.put(true) })
        #expect(await server.rejected.next(within: 3) == .timeout)
        #expect(await rawClosed.next(within: 2) == true)
        #expect(await server.accepted.next(within: 0.2) == nil)
        raw.close()
    }

    @Test func aFloodOfIdleConnectionsStaysCappedAndARealClientStillGetsIn() async throws {
        // Every loopback connection comes from 127.0.0.1, so the per-address cap is the one that binds.
        // The handshake deadline is far off: only the cap lets go of anything here.
        let server = try await LoopbackTLSServer(psks: [wifiPSKA], handshakeTimeout: 60)
        defer { server.listener.cancel() }
        let cap = NetworkStreamListener.maxPendingHandshakesPerHost
        let dropped = Mutex<Set<Int>>([])
        let queue = DispatchQueue(label: "flood")
        var flood: [SocketStream] = []
        defer { flood.forEach { $0.close() } }
        var peak = 0
        for i in 1...200 {
            let raw = try TCP.connectLoopback(port: server.port)   // plain TCP: never sends a ClientHello
            raw.start(queue: queue, onBytes: { _ in }, onClose: { _ in dropped.withLock { _ = $0.insert(i) } })
            flood.append(raw)
            peak = max(peak, server.listener.pendingHandshakes)
            guard i.isMultiple(of: 25) else { continue }
            // A real client in the middle of it, with the cap full of idle connections: it evicts the
            // oldest and is done long before the flood could evict it.
            let (client, accepted) = try await server.pair()
            #expect(client.tls == WiFiTLS.required && accepted.tls == WiFiTLS.required)
            client.close()
            accepted.close()
        }
        #expect(peak <= cap)
        // The listener let go of every idle connection beyond the cap, oldest first, and their sockets
        // closed: the flood holds a few descriptors, not one per connection.
        let waiting = server.listener.pendingHandshakes
        #expect(waiting <= cap)
        #expect(try await pollUntil { dropped.withLock { $0.count } == flood.count - waiting })
        #expect(dropped.withLock { $0 } == Set(1...(flood.count - waiting)))   // the newest are the ones left
        #expect(await server.rejected.next(within: 0.3) == nil)   // evictions are silent
        print("NetworkStream handshake flood: \(flood.count) idle connections, \(dropped.withLock { $0.count }) evicted, "
              + "at most \(peak) pending, 8 real clients admitted")
    }

    @Test func cancellingTheListenerDropsPendingHandshakesAtOnce() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA], handshakeTimeout: 30)
        let raw = try TCP.connectLoopback(port: server.port)   // plain TCP: never sends a ClientHello
        let rawClosed = Inbox<Bool>()
        raw.start(queue: DispatchQueue(label: "raw"), onBytes: { _ in }, onClose: { _ in rawClosed.put(true) })
        #expect(try await pollUntil { server.listener.pendingHandshakes == 1 })
        let t0 = MonotonicClock.now()
        server.listener.cancel()
        // At once, not at the handshake deadline.
        #expect(await rawClosed.next(within: 2) == true)
        #expect(secondsSince(t0) < 2)
        #expect(server.listener.pendingHandshakes == 0)
        #expect(await server.rejected.next(within: 0.2) == nil)   // a cancel isn't a rejection
        #expect(await server.accepted.next(within: 0.1) == nil)
        raw.close()
    }

    @Test func streamsHandedOverOutliveTheListenerAndItsRestart() async throws {
        var first: LoopbackTLSServer? = try await LoopbackTLSServer(psks: [wifiPSKA])
        let (client, accepted) = try await first!.pair()
        let atServer = StreamSink(expecting: 6), atClient = StreamSink(expecting: 6)
        atServer.attach(accepted)
        atClient.attach(client)
        client.write([1, 2, 3])
        accepted.write([4, 5, 6])
        // A restart, as the host does when its keys change: the old listener cancelled and released,
        // a new one with another key set.
        first?.listener.cancel()
        first = nil
        let second = try await LoopbackTLSServer(psks: [wifiPSKA, wifiPSKB])
        defer { second.listener.cancel() }
        let (client2, accepted2) = try await second.pair(wifiPSKB)
        try await Task.sleep(for: .milliseconds(200))   // time for any teardown the cancel could cause
        client.write([7, 8, 9])
        accepted.write([10, 11, 12])
        #expect(await atServer.reached.next() == 6)
        #expect(await atClient.reached.next() == 6)
        #expect(atServer.bytes == [1, 2, 3, 7, 8, 9] && atClient.bytes == [4, 5, 6, 10, 11, 12])
        #expect(atServer.closeCount == 0 && atClient.closeCount == 0)
        client.close()
        #expect(await atServer.closed.next() == .clean)
        [client2, accepted2].forEach { $0.close() }
    }

    @Test func theListenerRefusesAClientThatSettlesOnAPlainPSKSuite() async throws {
        // The right PSK and no suite appended: Network.framework offers only its plain-PSK suites, and
        // TLS completes on 0xA8, which has no forward secrecy (measured 2026-09-29). Refused at ready.
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let client = NWConnection(to: server.endpoint, using: handBuiltTLSParameters(wifiPSKA, appending: []))
        let clientEnded = Inbox<Bool>()
        client.stateUpdateHandler = { state in
            switch state {
            case .failed, .waiting: clientEnded.put(true)
            default: break
            }
        }
        client.start(queue: DispatchQueue(label: "plain-psk.client"))
        defer { client.cancel() }
        let rejected = try #require(await server.rejected.next())
        guard case .unexpectedTLS(let tls?) = rejected else { Issue.record("rejected with \(rejected)"); return }
        #expect(tls.version == WiFiTLS.version && tls.cipherSuite != WiFiTLS.cipherSuite)
        #expect(await server.accepted.next(within: 0.3) == nil)
        #expect(await clientEnded.next(within: 2) == true)   // the listener dropped it
    }

    @Test func aDialerRefusesAListenerThatSettlesOnAPlainPSKSuite() async throws {
        // A listener holding our PSK that appends only 0xA8: our offer has it too (see `WiFiTLS`), so
        // TLS completes on it.
        let listener = try NWListener(using: handBuiltTLSParameters(wifiPSKA, appending: [0x00A8], listener: true))
        let queue = DispatchQueue(label: "plain-psk.listener")
        let ready = Inbox<UInt16>(), connections = Inbox<NWConnection>(), serverEnded = Inbox<Bool>()
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state { ready.put(listener?.port?.rawValue ?? 0) }
        }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled: serverEnded.put(true)
                default: break
                }
            }
            connection.start(queue: queue)
            connections.put(connection)
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        let port = try #require(await ready.next())
        let dialer = NetworkStreamDialer(endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!),
                                         psk: wifiPSKA, options: .loopback)
        let error = await #expect(throws: NetworkStreamError.self) { _ = try await dialer.connect(kind: .realtime) }
        let server = await connections.next()
        defer { server?.cancel() }
        guard case .unexpectedTLS(let tls?)? = error else { Issue.record("threw \(String(describing: error))"); return }
        #expect(tls.version == WiFiTLS.version && tls.cipherSuite != WiFiTLS.cipherSuite)
        #expect(await serverEnded.next(within: 2) == true)   // the dialer dropped its connection
    }

    @Test func aListenerHoldingThreePSKsAcceptsEachIdentity() async throws {
        let secrets = (1...3).map { [UInt8](repeating: UInt8($0), count: 32) }
        let psks = secrets.map(WiFiPSK.init(secret:))
        let server = try await LoopbackTLSServer(psks: psks)
        defer { server.listener.cancel() }
        for (secret, psk) in zip(secrets, psks) {
            let (client, accepted) = try await server.pair(psk)
            #expect(client.tls?.cipherSuite == WiFiTLS.cipherSuite)
            #expect(accepted.tls?.cipherSuite == WiFiTLS.cipherSuite)
            // The listener learns which of its PSKs this client used (the TLS selection block).
            #expect(accepted.pskIdentity == psk.identity && client.pskIdentity == psk.identity)
            #expect(secrets.filter { accepted.isBound(toSecret: $0) } == [secret])
            let sink = StreamSink(expecting: 1)
            sink.attach(accepted)
            client.write([7])
            #expect(await sink.reached.next() == 1)
            client.close()
            accepted.close()
        }
    }

    @Test func fiveMegabytesArriveIntactBothWays() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let (client, accepted) = try await server.pair()
        let total = 5 * 1024 * 1024
        let up = patternBytes(total, seed: 31), down = patternBytes(total, seed: 17)
        let atServer = StreamSink(expecting: total), atClient = StreamSink(expecting: total)
        atServer.attach(accepted)
        atClient.attach(client)
        writeInChunks(client, up)
        writeInChunks(accepted, down)
        #expect(await atServer.reached.next(within: 10) == total)
        #expect(await atClient.reached.next(within: 10) == total)
        #expect(atServer.bytes == up)
        #expect(atClient.bytes == down)
        client.close()
        accepted.close()
    }

    @Test func dataThenEOFDeliversEveryByteThenOneCleanClose() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let (client, accepted) = try await server.pair()
        let payload = patternBytes(1_000_000, seed: 7)
        let sink = StreamSink()
        sink.attach(client)
        accepted.start(queue: DispatchQueue(label: "peer"), onBytes: { _ in }, onClose: { _ in })
        writeInChunks(accepted, payload, chunk: 100_000)
        accepted.close()
        #expect(await sink.closed.next() == .clean)
        #expect(sink.bytes == payload)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.closeCount == 1)
        #expect(sink.bytesAfterClose == 0)
    }

    @Test func aRemoteCloseIsReportedExactlyOnce() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        // Graceful: EOF.
        let (c1, s1) = try await server.pair()
        let graceful = StreamSink()
        graceful.attach(c1)
        s1.start(queue: DispatchQueue(label: "s1"), onBytes: { _ in }, onClose: { _ in })
        s1.close()
        #expect(await graceful.closed.next() == .clean)
        // Reset: the receive path and the state path both see ECONNRESET.
        let (c2, s2) = try await server.pair()
        let reset = StreamSink()
        reset.attach(c2)
        s2.core.connection.forceCancel()
        let closed = await reset.closed.next()
        #expect(closed != nil && closed != .clean)
        try await Task.sleep(for: .milliseconds(300))
        #expect(graceful.closeCount == 1)
        #expect(reset.closeCount == 1)
        c1.close()
        c2.close()
    }

    @Test func aCloseBeforeStartIsReportedAtStart() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        // The peer resets before this end has started.
        let (c1, s1) = try await server.pair()
        s1.core.connection.forceCancel()
        #expect(try await pollUntil { c1.core.phase == .closed })
        let failed = StreamSink()
        failed.attach(c1)
        let closed = await failed.closed.next()
        #expect(closed != nil && closed != .clean)
        // A local close before start: clean.
        let (c2, s2) = try await server.pair()
        c2.close()
        #expect(try await pollUntil { c2.core.phase == .closed })
        let local = StreamSink()
        local.attach(c2)
        #expect(await local.closed.next() == .clean)
        try await Task.sleep(for: .milliseconds(100))
        #expect(failed.closeCount == 1 && local.closeCount == 1)
        s2.close()
    }

    @Test func closeSendsQueuedWritesFirst() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let (client, accepted) = try await server.pair()
        let payload = patternBytes(5 * 1024 * 1024, seed: 3)
        let atServer = StreamSink(), atClient = StreamSink()
        atServer.attach(accepted)
        atClient.attach(client)
        writeInChunks(client, payload)
        client.close()
        client.write([1, 2, 3])   // after close(): dropped
        #expect(await atServer.closed.next(within: 10) == .clean)
        #expect(atServer.count == payload.count)
        #expect(atServer.bytes == payload)
        #expect(await atClient.closed.next() == .clean)
        #expect(atClient.closeCount == 1)
    }

    @Test func closeNeverDropsTheTailOfABurst() async throws {
        // Cancelling once every write was processed lost 96–128 KB in about 5% of such closes.
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let payload = [UInt8](repeating: 0x3C, count: 2 << 20)
        var short = 0
        for _ in 0..<80 {
            let (client, accepted) = try await server.pair()
            let atServer = StreamSink(keep: false), atClient = StreamSink(keep: false)
            atServer.attach(accepted)
            atClient.attach(client)
            writeInChunks(client, payload, chunk: 256 * 1024)
            client.close()
            #expect(await atServer.closed.next(within: 5) == .clean)
            if atServer.count != payload.count { short += 1 }
            #expect(await atClient.closed.next(within: 5) == .clean)
            withExtendedLifetime(accepted) {}
        }
        #expect(short == 0)
    }

    @Test func closeWithAPeerThatIsNotReadingEndsWithinTheDeadline() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let (client, accepted) = try await server.pair()   // `accepted` never starts: it reads nothing
        let sink = StreamSink(keep: false)
        sink.attach(client)
        let chunk = [UInt8](repeating: 0xA5, count: 1 << 20)
        for _ in 0..<64 { client.write(chunk) }
        let t0 = MonotonicClock.now()
        client.close()
        #expect(await sink.closed.next(within: NetworkStream.closeDeadline + 3) == .clean)
        let took = secondsSince(t0)
        #expect(took < NetworkStream.closeDeadline + 1)
        #expect(took > NetworkStream.closeDeadline - 0.2)   // it waited for the deadline, then force-cancelled
        #expect(client.core.phase == .closed)
        print(String(format: "NetworkStream close with a stalled peer: reported after %.2f s (deadline %.1f s)",
                     took, NetworkStream.closeDeadline))
        accepted.close()
    }

    @Test func aDialCancelledMidHandshakeThrowsAndLeavesNoConnection() async throws {
        // A plain TCP server: the dial's TCP connect succeeds, then TLS waits for a ServerHello forever.
        let raw = Inbox<SocketStream>()
        let tcp = try TCPListener(port: 0, queue: DispatchQueue(label: "tcp")) { raw.put($0) }
        defer { tcp.cancel() }
        let dialer = NetworkStreamDialer(endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: tcp.port)!),
                                         psk: wifiPSKA, options: .loopback, timeout: 20)
        let dial = Task { try await dialer.connect(kind: .realtime) }
        let peer = try #require(await raw.next())
        let peerClosed = Inbox<Bool>()
        peer.start(queue: DispatchQueue(label: "peer"), onBytes: { _ in }, onClose: { _ in peerClosed.put(true) })
        try await Task.sleep(for: .milliseconds(100))
        let t0 = MonotonicClock.now()
        dial.cancel()
        await #expect(throws: CancellationError.self) { _ = try await dial.value }
        #expect(secondsSince(t0) < 1)
        #expect(await peerClosed.next(within: 2) == true)   // the dialed connection is gone
        peer.close()
    }

    @Test func aDialToAClosedPortFailsWithinTheTimeout() async throws {
        let port = try closedLoopbackPort()
        let dialer = NetworkStreamDialer(endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!),
                                         psk: wifiPSKA, options: .loopback)
        let t0 = MonotonicClock.now()
        await #expect(throws: NetworkStreamError.refused) { _ = try await dialer.connect(kind: nil) }
        #expect(secondsSince(t0) < NetworkStreamDialer.defaultTimeout)
    }

    @Test func aDialThatIsNeverAnsweredTimesOut() async throws {
        let raw = Inbox<SocketStream>()
        let tcp = try TCPListener(port: 0, queue: DispatchQueue(label: "tcp")) { raw.put($0) }
        defer { tcp.cancel() }
        let dialer = NetworkStreamDialer(endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: tcp.port)!),
                                         psk: wifiPSKA, options: .loopback, timeout: 0.5)
        let t0 = MonotonicClock.now()
        await #expect(throws: NetworkStreamError.timeout) { _ = try await dialer.connect(kind: nil) }
        #expect(secondsSince(t0) < 2)
        _ = await raw.next(within: 1)   // released unstarted: its descriptor closes
    }

    @Test func messageChannelRoundTripOverTLS() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let (clientStream, serverStream) = try await server.pair()
        let client = MessageChannel(stream: clientStream, label: "client"), host = MessageChannel(stream: serverStream, label: "host")
        host.setHandler { env in
            switch env.message {
            case .hello: host.send(.helloAck(sampleHelloAck))
            case .videoFrame(let f): host.send(.frameAck(FrameAck(frameId: f.frameId, receivedAtNs: 1, bytes: UInt32(f.data.count))))
            default: break
            }
        }
        host.start()
        client.start()
        client.send(.hello(sampleHello))
        #expect(try await client.next(timeoutSeconds: 2).message == .helloAck(sampleHelloAck))
        let keyframe = VideoFrame(frameId: 9, configId: 1, captureTimeNs: 1, encodeDoneNs: 2, isKeyframe: true,
                                  data: patternBytes(1_300_000, seed: 11))
        client.send(.videoFrame(keyframe))
        #expect(try await client.next(timeoutSeconds: 5).message == .frameAck(FrameAck(frameId: 9, receivedAtNs: 1, bytes: 1_300_000)))
        client.close()
        host.close()
    }

    @Test func theWiFiLinkDialerPinsVideoAndAudioToRealtimesPath() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let dialer = WiFiLinkDialer(endpoint: server.endpoint, psk: wifiPSKA, options: .loopback)
        let realtime = try #require(try await dialer.dial(kind: .realtime) as? NetworkStream)
        let pin = try #require(dialer.pinned)
        #expect(pin.endpoint == realtime.path.remoteEndpoint)
        #expect(pin.interface != nil && pin.interface == realtime.path.interface)
        let video = try #require(try await dialer.dial(kind: .video) as? NetworkStream)
        let audio = try #require(try await dialer.dial(kind: .audio) as? NetworkStream)
        for stream in [realtime, video, audio] {
            #expect(stream.path.kind == .loopback)
            #expect(stream.path.interfaceName == realtime.path.interfaceName)
            #expect(stream.tls == NegotiatedTLS(version: WiFiTLS.version, cipherSuite: WiFiTLS.cipherSuite))
        }
        for stream in [video, audio] {
            // Dialed the resolved address on the realtime connection's interface, not the discovered endpoint.
            #expect(stream.core.connection.endpoint == pin.endpoint)
            #expect(stream.core.connection.parameters.requiredInterface == pin.interface)
            #expect(stream.core.connection.parameters.serviceClass == .bestEffort)
        }
        #expect(realtime.core.connection.parameters.requiredInterface == nil)
        #expect(realtime.core.connection.parameters.serviceClass == .interactiveVoice)
        for _ in 0..<3 { #expect(await server.accepted.next() != nil) }
        [realtime, video, audio].forEach { $0.close() }
    }

    @Test func loopbackThroughput() async throws {
        let server = try await LoopbackTLSServer(psks: [wifiPSKA])
        defer { server.listener.cancel() }
        let (client, accepted) = try await server.pair()
        let total = 64 << 20
        let sink = StreamSink(expecting: total, keep: false)
        sink.attach(accepted)
        let chunk = [UInt8](repeating: 0x5A, count: 1 << 20)
        let t0 = MonotonicClock.now()
        for _ in 0..<(total / chunk.count) { client.write(chunk) }
        #expect(await sink.reached.next(within: 60) == total)
        let took = secondsSince(t0)
        print(String(format: "NetworkStream loopback throughput, TLS 1.2 ECDHE-PSK CHACHA20-POLY1305: %.0f MB/s (%d MB in %.2f s)",
                     Double(total) / took / 1e6, total >> 20, took))
        client.close()
        accepted.close()
    }
}

@Suite struct NetworkStreamPolicy {
    @Test func pskDerivationMatchesRFC5869KnownAnswers() {
        // Vectors from an independent HKDF-SHA256 (Python hmac/hashlib, checked against RFC 5869 case 1).
        #expect(wifiPSKA.identity == "lain1-f5e4a0d2d0bc6c77")
        #expect(wifiPSKA.key == [0xAF, 0x59, 0xFF, 0x3F, 0x0C, 0x68, 0x06, 0x31, 0x5B, 0x77, 0xB1, 0x7B, 0x6E, 0xF3, 0x40, 0x5F,
                             0xCE, 0x97, 0x65, 0xED, 0xC8, 0xDD, 0x0A, 0xAE, 0xA5, 0x9B, 0x34, 0x70, 0x53, 0xC3, 0x04, 0x1C])
        #expect(wifiPSKB.identity == "lain1-21c490049bb2a2e9")
        #expect(wifiPSKB.key == [0xC4, 0x76, 0x25, 0xDA, 0x67, 0x30, 0x1D, 0xCE, 0x17, 0xD1, 0x48, 0x2C, 0xE6, 0xA0, 0xF8, 0x34,
                             0xDB, 0xFC, 0xAD, 0xAD, 0xCD, 0x87, 0x9D, 0xD8, 0x71, 0xB4, 0xBA, 0x79, 0x3B, 0x1F, 0xDC, 0x6F])
    }

    @Test func thePSKPrintsOnlyItsIdentity() {
        var g = SystemRandomNumberGenerator()
        let psk = WiFiPSK(secret: (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) })
        #expect(psk.identity.hasPrefix("lain1-") && psk.identity.count == 22)
        #expect(psk.key.count == 32)
        #expect(String(describing: psk) == psk.identity)
        #expect(String(reflecting: psk) == psk.identity)
        var dumped = ""
        dump(psk, to: &dumped)
        #expect(dumped.contains(psk.identity) && !dumped.contains("key"))
    }

    @Test func parametersCarryTheTCPAndPathPolicy() throws {
        let options = NetworkStreamOptions()
        let realtime = options.dialParameters(psk: wifiPSKA, kind: .realtime)
        #expect(realtime.serviceClass == .interactiveVoice)
        #expect(realtime.includePeerToPeer)
        #expect(realtime.requiredLocalEndpoint == nil)
        let tcp = try #require(realtime.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        #expect(tcp.noDelay && tcp.enableKeepalive)
        #expect(tcp.keepaliveIdle == 2 && tcp.keepaliveInterval == 1 && tcp.keepaliveCount == 4)
        #expect(tcp.connectionDropTime == NetworkStreamOptions.connectionDropTime)
        #expect(realtime.defaultProtocolStack.applicationProtocols.first is NWProtocolTLS.Options)
        #expect(options.dialParameters(psk: wifiPSKA, kind: .video).serviceClass == .bestEffort)
        #expect(options.dialParameters(psk: wifiPSKA, kind: nil).serviceClass == .bestEffort)
        var plain = options
        plain.interactiveRealtime = false
        #expect(plain.dialParameters(psk: wifiPSKA, kind: .realtime).serviceClass == .bestEffort)

        let listener = options.listenerParameters(psks: [wifiPSKA, wifiPSKB])
        #expect(listener.includePeerToPeer && listener.requiredLocalEndpoint == nil)   // wildcard dual-stack bind
        let loopback = NetworkStreamOptions.loopback.listenerParameters(psks: [wifiPSKA])
        #expect(loopback.requiredInterfaceType == .loopback && !loopback.includePeerToPeer)
        #expect(loopback.requiredLocalEndpoint == .hostPort(host: .ipv4(.loopback), port: .any))
        let loopbackDial = NetworkStreamOptions.loopback.dialParameters(psk: wifiPSKA, kind: .realtime)
        #expect(loopbackDial.requiredInterfaceType == .loopback && !loopbackDial.includePeerToPeer)

        // A Wi-Fi link always includes peer-to-peer interfaces (awdl0 is excluded otherwise).
        let service = NWEndpoint.service(name: "Mac mini", type: "_lain._tcp", domain: "local.", interface: nil)
        let link = WiFiLinkDialer(endpoint: service, psk: wifiPSKA, options: NetworkStreamOptions(includePeerToPeer: false))
        #expect(link.options.includePeerToPeer)
        #expect(link.options.dialParameters(psk: wifiPSKA, kind: .video).includePeerToPeer)
        #expect(link.pinned == nil)
    }

    @Test func networkErrorsAreClassified() {
        #expect(NetworkStreamError.classify(.tls(errSSLUnknownPSKIdentity)) == .unknownIdentity)
        #expect(NetworkStreamError.classify(.tls(errSSLPeerBadRecordMac)) == .wrongKey)   // client, -9820
        #expect(NetworkStreamError.classify(.tls(errSSLBadRecordMac)) == .wrongKey)       // server, -9846
        #expect(NetworkStreamError.classify(.tls(errSSLHandshakeFail)) == .tls(errSSLHandshakeFail))
        #expect(NetworkStreamError.classify(.posix(.ECONNREFUSED)) == .refused)
        #expect(NetworkStreamError.classify(.posix(.ECONNRESET)) == .posix(ECONNRESET))
        #expect(NetworkStreamError.classify(.dns(-65570)) == .localNetworkDenied)       // kDNSServiceErr_PolicyDenied
        #expect(NetworkStreamError.classify(.dns(-65569)) == .dns(-65569))
    }

    @Test func pathKindsGoByNameThenType() {
        #expect(NetworkPath.kind(interfaceName: "awdl0", type: .wifi) == .peerToPeer)
        #expect(NetworkPath.kind(interfaceName: "llw0", type: .other) == .peerToPeer)
        #expect(NetworkPath.kind(interfaceName: "en1", type: .wifi) == .wifi)
        #expect(NetworkPath.kind(interfaceName: "en8", type: .wiredEthernet) == .wired)
        #expect(NetworkPath.kind(interfaceName: "lo0", type: .loopback) == .loopback)
        #expect(NetworkPath.kind(interfaceName: "utun4", type: .other) == .other)
        #expect(NetworkPath.kind(interfaceName: "pdp_ip0", type: .cellular) == .other)
        let unknown = NetworkPath(interface: nil)
        #expect(unknown.interfaceName.isEmpty && unknown.kind == .other)
    }

    @Test func negotiatedTLSDescribesItself() {
        #expect(NegotiatedTLS(version: 0x0303, cipherSuite: 0xCCAC).description == "TLS 1.2 suite 0xCCAC")
        #expect(WiFiTLS.required == NegotiatedTLS(version: 0x0303, cipherSuite: 0xCCAC))
    }

    @Test func pendingHandshakesEvictTheOldestOfTheSameAddressFirst() {
        var pending = PendingHandshakes<Int>(limit: 4, perHost: 2)
        let one = pending.admit(1, from: "a"), two = pending.admit(2, from: "a")
        #expect(one.evicted.isEmpty && two.evicted.isEmpty && two.key > one.key)
        let three = pending.admit(3, from: "a"), four = pending.admit(4, from: "b"), five = pending.admit(5, from: "c")
        #expect(three.evicted == [1])   // a at its cap: a's oldest goes
        #expect(four.evicted.isEmpty && five.evicted.isEmpty && pending.count == 4)
        let six = pending.admit(6, from: "c"), seven = pending.admit(7, from: "d")
        #expect(six.evicted == [5])     // at the total cap: the same address first
        #expect(seven.evicted == [2])   // an address with none waiting: the oldest overall
        #expect(pending.count == 4 && pending.count(from: "a") == 1 && pending.count(from: "d") == 1)
        let removed = [one.key, five.key, seven.key, seven.key].map { pending.remove($0) }
        #expect(removed == [nil, nil, 7, nil])   // evicted or removed: gone for good
        let eight = pending.admit(8, from: "d")
        #expect(eight.evicted.isEmpty && eight.key > seven.key)   // keys are never reused
        let rest = pending.removeAll()
        #expect(rest == [3, 4, 6, 8] && pending.count == 0)
    }

    @Test func aFloodEvictsItsOwnConnectionsFirst() {
        var pending = PendingHandshakes<String>(limit: 32, perHost: 8)
        _ = pending.admit("iPad", from: "fe80::1%awdl0")
        // One address, or a few that each keep connections waiting, only ever evict their own.
        let evicted = (0..<1_000).flatMap { pending.admit("idle", from: "attacker\($0 % 4)").evicted }
        #expect(evicted.count == 1_000 - 31 && !evicted.contains("iPad"))
        #expect(pending.count == 32 && pending.count(from: "fe80::1%awdl0") == 1)
        // A fresh address per connection reaches the oldest overall, but only after the total cap's worth
        // of newer connections: a real client is done long before.
        var fresh = PendingHandshakes<String>(limit: 32, perHost: 8)
        _ = fresh.admit("iPad", from: "fe80::1%awdl0")
        let early = (0..<31).flatMap { fresh.admit("idle", from: "fresh\($0)").evicted }
        let late = fresh.admit("idle", from: "fresh31").evicted
        #expect(early.isEmpty && late == ["iPad"])
    }

    @Test func thePerAddressCapCountsAddressesNotPorts() {
        let host = NetworkStreamListener.remoteHost
        #expect(host(.hostPort(host: .ipv4(.loopback), port: 50_001)) == host(.hostPort(host: .ipv4(.loopback), port: 50_002)))
        #expect(host(.hostPort(host: "127.0.0.1", port: 1)) == "127.0.0.1")
        #expect(host(.hostPort(host: "192.168.1.20", port: 1)) != host(.hostPort(host: "192.168.1.21", port: 1)))
        #expect(host(.service(name: "Mac mini", type: "_lain._tcp", domain: "local.", interface: nil)) == "")
    }

    @Test func dropReportsAreRateLimitedAndSummedUp() {
        var reports = DropReports()
        let window = UInt64(DropReports.window * 1e9)
        let first = (0..<DropReports.limit).map { reports.rejected(at: 1_000 + UInt64($0)) }
        #expect(first.allSatisfy { $0.report && !$0.summarize })
        let over = reports.rejected(at: 2_000), again = reports.rejected(at: 3_000)
        #expect(!over.report && over.summarize)   // counted; the first count schedules the one summary
        #expect(!again.report && !again.summarize)
        let evictions = [reports.evicted(3), reports.evicted(0)]
        #expect(evictions == [false, false])      // counted into the summary already scheduled
        let summary = reports.takeSummary()
        #expect(summary.unreported == 2 && summary.evicted == 3)
        // The next window reports again; the next count schedules the next summary.
        let nextWindow = reports.rejected(at: 1_000 + window), nextEviction = reports.evicted(1)
        #expect(nextWindow.report && nextEviction)
        let next = reports.takeSummary()
        #expect(next.unreported == 0 && next.evicted == 1)
    }
}
