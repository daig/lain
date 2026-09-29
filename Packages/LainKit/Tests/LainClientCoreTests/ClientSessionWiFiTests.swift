import Dispatch
import Foundation
import LainInput
import LainProtocol
import LainTelemetry
import Network
import Synchronization
import Testing
@testable import LainClientCore
@testable import LainTransport

// ClientSession over Wi-Fi (§7.7 D29), loopback only: the "Mac" is a TLS-PSK listener bound to
// 127.0.0.1 and never advertised, and discovery is a FixedHostDiscovery (nothing browses).

// MARK: Helpers

/// The client's store, counting writes: a Wi-Fi `HelloAck` never writes, a USB one only under the rules.
final class RecordingSecrets: SecretStore {
    let inner: InMemorySecretStore
    private let writes = Atomic<Int>(0)

    init(_ initial: [String: [UInt8]] = [:]) { inner = InMemorySecretStore(initial) }

    var writeCount: Int { writes.load(ordering: .relaxed) }
    func secret(for peer: String) -> [UInt8]? { inner.secret(for: peer) }
    func setSecret(_ secret: [UInt8], for peer: String) {
        writes.add(1, ordering: .relaxed)
        inner.setSecret(secret, for: peer)
    }
    func removeSecret(for peer: String) { inner.removeSecret(for: peer) }
    func allSecrets() -> [String: [UInt8]] { inner.allSecrets() }
}

/// A Mac's Wi-Fi side, reduced to what the client meets: a loopback-only TLS-PSK listener holding the
/// iPad's PSK, feeding a `LinkAcceptor` that refuses pairing (as the host builds it). Each link reads
/// `Hello` and answers as `reply` says at that moment.
final class WiFiMac: Sendable {
    enum Reply: Sendable, Equatable {
        case helloAck(hostId: String)
        /// `Error(busy)`, then a close after a short drain (as the host does).
        case busy
        /// A close before `HelloAck`.
        case close
    }

    struct Stamped<T: Sendable>: Sendable {
        let value: T
        let at: UInt64
    }

    final class Script: Sendable {
        let reply: Mutex<Reply>
        init(_ reply: Reply) { self.reply = Mutex(reply) }
    }

    let hostId: String
    let name: String
    let script: Script
    /// Every link the acceptor delivered.
    let links: Inbox<AcceptedLink>
    /// Each link's `Hello`, with its arrival time.
    let hellos: Inbox<Stamped<Hello>>
    /// Links closed by the client before any `Hello`.
    let unused: Inbox<Bool>
    /// Realtime messages after `HelloAck`: the client's input.
    let received: Inbox<Message>
    /// Closes of links that sent `Hello` (the client's, unless the reply closes).
    let closes: Inbox<Bool>
    /// TLS handshakes the listener refused, with when.
    let refused: Inbox<Stamped<NetworkStreamError>>
    private let listener: NetworkStreamListener
    private let acceptor: LinkAcceptor
    let port: UInt16

    /// `psks`: the listener's keys, if not the pairing's own (a Mac that lost or replaced the pairing).
    init(secret: [UInt8], hostId: String = UUID().uuidString, name: String = "Mac mini",
         reply: Reply? = nil, psks: [WiFiPSK]? = nil) async throws {
        let script = Script(reply ?? .helloAck(hostId: hostId))
        let links = Inbox<AcceptedLink>(), hellos = Inbox<Stamped<Hello>>(), unused = Inbox<Bool>()
        let received = Inbox<Message>(), closes = Inbox<Bool>(), refused = Inbox<Stamped<NetworkStreamError>>()
        let ready = Inbox<UInt16>()
        let acceptor = LinkAcceptor(secrets: InMemorySecretStore(["IPAD": secret]), pairing: .refuse, label: "test.mac") { accepted in
            links.put(accepted)
            Task {
                let realtime = accepted.link.realtime
                guard let first = try? await realtime.next(timeoutSeconds: 5), case .hello(let h) = first.message else {
                    unused.put(true)
                    return accepted.link.close()
                }
                // Read before the Hello is reported: a test that changes the reply on seeing this Hello
                // changes the next link's.
                let reply = script.reply.withLock { $0 }
                realtime.setCloseHandler { _ in closes.put(true) }
                hellos.put(Stamped(value: h, at: MonotonicClock.now()))
                switch reply {
                case .helloAck(let id):
                    realtime.setHandler { received.put($0.message) }
                    var answer = ack
                    answer.hostId = id
                    answer.hostName = name
                    realtime.send(.helloAck(answer))
                case .busy:
                    realtime.send(.error(ErrorMessage(code: .busy, message: "another session is live")))
                    try? await Task.sleep(for: .milliseconds(200))
                    accepted.link.close()
                case .close:
                    accepted.link.close()
                }
            }
        }
        let listener = try NetworkStreamListener(psks: psks ?? [WiFiPSK(secret: secret)], options: .loopback, onEvent: { event in
            switch event {
            case .state(.ready(let port)): ready.put(port)
            case .rejected(let error): refused.put(Stamped(value: error, at: MonotonicClock.now()))
            default: break
            }
        }, onAccept: { acceptor.accept($0) })
        guard let port = await ready.next() else {
            listener.cancel()
            throw TransportError.timeout
        }
        (self.hostId, self.name, self.script, self.port) = (hostId, name, script, port)
        (self.links, self.hellos, self.unused, self.received, self.closes, self.refused) = (links, hellos, unused, received, closes, refused)
        (self.listener, self.acceptor) = (listener, acceptor)
    }

    /// What Bonjour would report for it (TXT `v` = `version`, `id` = `hostId`).
    func discovered(version: UInt8? = LainProtocol.majorVersion) -> DiscoveredHost {
        DiscoveredHost(hostId: hostId, name: name, protocolVersion: version,
                       endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!),
                       interfaceNames: ["lo0"])
    }

    func answer(_ reply: Reply) { script.reply.withLock { $0 = reply } }

    func cancel() {
        listener.cancel()
        acceptor.cancel()
    }
}

/// A `FixedHostDiscovery` per start, each remembered (tests never browse).
final class Discoveries: Sendable {
    private let made = Mutex<[FixedHostDiscovery]>([])
    private let setup: Mutex<(hosts: [DiscoveredHost], states: [DiscoveryState])>

    /// `states`: the n-th discovery's initial state (then `.searching`).
    init(_ hosts: [DiscoveredHost] = [], states: [DiscoveryState] = []) { setup = Mutex((hosts, states)) }

    func make() -> any HostDiscovery {
        let (hosts, states) = setup.withLock { $0 }
        return made.withLock { m in
            let d = FixedHostDiscovery(hosts: hosts, state: m.count < states.count ? states[m.count] : .searching)
            m.append(d)
            return d
        }
    }

    /// Later discoveries report these.
    func show(_ hosts: [DiscoveredHost]) { setup.withLock { $0.hosts = hosts } }
    var all: [FixedHostDiscovery] { made.withLock { $0 } }
}

/// Opens once; a wait ignores task cancellation (a held dial finishes only when the test says).
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let open = state.withLock { s -> Bool in
                if !s.open { s.waiters.append(c) }
                return s.open
            }
            if open { c.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.open = true
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// Wraps a stream so a test can hold what it receives and let it through later: the bytes, then the
/// close, in order, on the consumer's queue.
final class HoldingStream: ByteStream {
    let inner: any ByteStream
    private struct State {
        var holding = false
        var held: [[UInt8]] = []
        var close: ((any Error)?)?
        var queue: DispatchQueue?
        var onBytes: (@Sendable ([UInt8]) -> Void)?
        var onClose: (@Sendable ((any Error)?) -> Void)?
    }
    private let state = Mutex(State())

    init(_ inner: any ByteStream) { self.inner = inner }

    func start(queue: DispatchQueue, onBytes: @escaping @Sendable ([UInt8]) -> Void,
               onClose: @escaping @Sendable ((any Error)?) -> Void) {
        state.withLock { s in
            s.queue = queue
            s.onBytes = onBytes
            s.onClose = onClose
        }
        inner.start(queue: queue, onBytes: { [self] bytes in
            let pass = state.withLock { s -> Bool in
                if s.holding { s.held.append(bytes) }
                return !s.holding
            }
            if pass { onBytes(bytes) }
        }, onClose: { [self] error in
            let pass = state.withLock { s -> Bool in
                if s.holding { s.close = .some(error) }
                return !s.holding
            }
            if pass { onClose(error) }
        })
    }

    func write(_ bytes: [UInt8]) { inner.write(bytes) }
    func close() { inner.close() }

    func hold() { state.withLock { $0.holding = true } }
    var heldBytes: Int { state.withLock { $0.held.reduce(0) { $0 + $1.count } } }

    /// Delivers what was held, then the close if one came; returns once the consumer has run.
    func release() async {
        guard let queue = state.withLock({ $0.queue }) else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                let (held, close, onBytes, onClose) = state.withLock { s in
                    s.holding = false
                    defer { (s.held, s.close) = ([], nil) }
                    return (s.held, s.close, s.onBytes, s.onClose)
                }
                held.forEach { onBytes?($0) }
                if let close { onClose?(close) }
                c.resume()
            }
        }
    }
}

/// Interposes on each Wi-Fi attempt's dialer: records where it goes and (weakly) the streams it opens,
/// optionally holds the dial once its last connection is up (until `gate` opens, whatever happened to
/// the attempt meanwhile), and optionally wraps each stream in a `HoldingStream`.
final class DialProbe: Sendable {
    let holdsDial: Bool
    let wrapsStreams: Bool
    let gate = Gate()
    /// A dial reached the hold.
    let held = Inbox<Bool>()
    /// A held dial went on after the gate opened.
    let released = Inbox<Bool>()
    let streams = Mutex<[ConnectionKind: HoldingStream]>([:])
    private let attempts = Mutex<[NWEndpoint]>([])
    private let opened = Mutex<[WeakStream]>([])

    init(holdsDial: Bool = false, wrapsStreams: Bool = false) {
        self.holdsDial = holdsDial
        self.wrapsStreams = wrapsStreams
    }

    func interpose(_ inner: any StreamDialer) -> any StreamDialer {
        if let wifi = inner as? WiFiLinkDialer { attempts.withLock { $0.append(wifi.endpoint) } }
        return Dialer(inner: inner, probe: self)
    }

    func stream(_ kind: ConnectionKind) -> HoldingStream? { streams.withLock { $0[kind] } }

    /// The endpoint of each attempt, in order.
    var dialed: [NWEndpoint] { attempts.withLock { $0 } }
    /// Streams the attempts opened that are still in memory.
    var liveStreams: Int { opened.withLock { $0.filter { $0.stream != nil }.count } }

    struct Dialer: StreamDialer {
        let inner: any StreamDialer
        let probe: DialProbe

        func dial() async throws -> any ByteStream { try await inner.dial() }

        func dial(kind: ConnectionKind) async throws -> any ByteStream {
            var stream = try await inner.dial(kind: kind)
            probe.opened.withLock { $0.append(WeakStream(stream)) }
            if probe.wrapsStreams {
                let holding = HoldingStream(stream)
                probe.streams.withLock { $0[kind] = holding }
                stream = holding
            }
            if kind == .audio, probe.holdsDial {
                probe.held.put(true)
                await probe.gate.wait()
                probe.released.put(true)
            }
            return stream
        }
    }
}

/// A stream held weakly, to see it freed.
final class WeakStream: @unchecked Sendable {
    weak var stream: (any ByteStream)?
    init(_ stream: any ByteStream) { self.stream = stream }
}

/// A service that accepts TCP and never answers: a TLS handshake with it stalls until the dial times
/// out (what anyone copying a Mac's public host id into its own TXT record can do). Loopback only.
final class StallingService: Sendable {
    let port: UInt16
    private let listener: TCPListener
    private let held: Held

    private final class Held: Sendable {
        let sockets = Mutex<[SocketStream]>([])
    }

    init() throws {
        let held = Held()
        listener = try TCPListener(port: 0, queue: DispatchQueue(label: "test.stalling")) { socket in
            held.sockets.withLock { $0.append(socket) }
        }
        port = listener.port
        self.held = held
    }

    /// Connections it took (each one a dial it stalled).
    var accepted: Int { held.sockets.withLock { $0.count } }

    /// Listed under `hostId`, as `name`.
    func discovered(claiming hostId: String, name: String) -> DiscoveredHost {
        DiscoveredHost(hostId: hostId, name: name, protocolVersion: LainProtocol.majorVersion,
                       endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!),
                       interfaceNames: ["lo0"])
    }

    func cancel() {
        listener.cancel()
        held.sockets.withLock { s in
            s.forEach { $0.close() }
            s = []
        }
    }
}

/// A closed loopback port: one the kernel just handed out, released again. (A socket kept bound but
/// not listening would be a black hole, which drops the SYN instead of refusing.)
func closedLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TransportError.posix("socket", errno) }
    defer { close(fd) }
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

/// Short times for tests; loopback only.
func testWiFi(_ discoveries: Discoveries, lastHost: LastConnectedHost = .memory(), probe: DialProbe? = nil) -> ClientWiFiConfig {
    var config = ClientWiFiConfig(discovery: { discoveries.make() }, options: .loopback, lastHost: lastHost)
    config.grace = WiFiTimes.grace
    config.busyBackoff = WiFiTimes.busy
    config.failureBackoff = 0.1
    config.maxBackoff = 0.4
    config.serviceBackoff = 0.1
    config.discoveryBackoff = 0.1
    config.maxDiscoveryBackoff = 0.4
    config.dialTimeout = 2
    if let probe { config.interpose = { probe.interpose($0) } }
    return config
}

enum WiFiTimes {
    static let grace = 0.3
    static let busy = 1.0
}

/// Seconds from one `MonotonicClock` time to another.
func elapsed(_ from: UInt64, _ to: UInt64) -> Double { Double(Int64(bitPattern: to &- from)) / 1e9 }

/// `ack` for the Mac with this id.
func helloAck(hostId: String, name: String = "Mac mini") -> HelloAck {
    var a = ack
    a.hostId = hostId
    a.hostName = name
    return a
}

func isConfigured(_ status: ClientSession.Status, via transport: LinkTransport? = nil) -> Bool {
    guard case .connected(let info) = status, info.isConfigured else { return false }
    return transport.map { info.transport == $0 } ?? true
}

func isNetwork(_ status: ClientSession.Status) -> Bool {
    guard case .connected(let info) = status, info.isConfigured, case .network = info.transport else { return false }
    return true
}

/// Polls `body` every 5 ms until it holds (false after `seconds`).
func eventually(within seconds: Double = 5, _ body: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if body() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return body()
}

// MARK: Sessions over Wi-Fi

@Suite(.serialized) struct ClientSessionWiFiTests {
    let secret = ChannelAuth.randomBytes(32)

    @Test func aWiFiSessionComesUpAfterTheGraceAndCarriesInput() async throws {
        let mac = try await WiFiMac(secret: secret)
        defer { mac.cancel() }
        let store = RecordingSecrets([PairingAccounts.mac(mac.hostId): secret])
        let lastHost = LastConnectedHost.memory()
        let statuses = Inbox<ClientSession.Status>()
        let started = MonotonicClock.now()
        let session = try ClientSession(port: 0, secrets: store, hello: hello,
                                        wifi: testWiFi(Discoveries([mac.discovered()]), lastHost: lastHost)) { statuses.put($0) }
        defer { session.stop() }

        let first = try #require(await mac.hellos.next())
        #expect(first.value == hello)
        #expect(elapsed(started, first.at) >= WiFiTimes.grace)   // USB gets the grace to come first
        let accepted = try #require(await mac.links.next())
        let status = try #require(await statuses.first { isConfigured($0) })
        guard case .connected(let info) = status else { Issue.record("no configured status"); return }
        // The transport the Mac saw (the loopback interface), and the Mac's name from HelloAck.
        #expect(info.transport == accepted.link.transport)
        guard case .network(let interface, false) = info.transport else { Issue.record("\(info.transport)"); return }
        #expect(interface?.isEmpty == false)
        #expect(info.hostName == "Mac mini" && info.displayPointWidth == 1376)
        #expect(ClientStatus(status).detail.hasPrefix("Wi-Fi · LAN "))

        // Input reaches the Mac over Wi-Fi.
        session.input.keyChanged(.key(0x04), isDown: true)
        let key = await mac.received.first { if case .keyEvent = $0 { true } else { false } }
        #expect(key.map { if case .keyEvent(let e) = $0 { e.usage == 0x04 && e.isDown } else { false } } == true)
        // A Wi-Fi session never writes a secret (Wi-Fi never pairs, D13); it's now the last-connected Mac.
        #expect(store.writeCount == 0)
        #expect(lastHost.get() == mac.hostId)
        #expect(await mac.refused.next(within: 0.1) == nil)
    }

    /// The owner's morning (§7.7 D29): the pairing exists only under "host" until a v2 USB session
    /// records `mac:<hostId>`; only then does Wi-Fi dial.
    @Test func theMigrationPathRecordsTheMacOverUSBThenDialsIt() async throws {
        let mac = try await WiFiMac(secret: secret)
        defer { mac.cancel() }
        let store = RecordingSecrets([PairingAccounts.usbHost: secret])
        let discoveries = Discoveries([mac.discovered()])
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: store, hello: hello, wifi: testWiFi(discoveries)) { statuses.put($0) }
        defer { session.stop() }

        // Seen but not dialable: no Wi-Fi secret for it yet.
        #expect(await statuses.first { $0 == .needsCable(hostName: "Mac mini") } != nil)
        #expect(await mac.links.next(within: WiFiTimes.grace + 0.5) == nil)
        #expect(await mac.refused.next(within: 0.1) == nil)

        // A USB session authenticated by "host" whose HelloAck names the Mac records it for Wi-Fi.
        let (usb, _, paired) = try await HostLink.open(dialer: LoopbackDialer(port: session.port),
                                                       secrets: InMemorySecretStore(["IPAD": secret]), peerID: "IPAD",
                                                       allowPairing: false)
        #expect(!paired)
        usb.realtime.send(.helloAck(helloAck(hostId: mac.hostId)))
        #expect(await statuses.first { isConfigured($0, via: .usb) } != nil)
        #expect(store.secret(for: PairingAccounts.mac(mac.hostId)) == secret)
        #expect(store.writeCount == 1)
        // No browsing, and no Wi-Fi dial, while USB is current.
        #expect(discoveries.all.count == 1 && discoveries.all.allSatisfy(\.isCancelled))
        #expect(await mac.links.next(within: WiFiTimes.grace + 0.3) == nil)

        // The cable goes: browsing resumes, and after the grace the Wi-Fi session comes up.
        usb.close()
        #expect(await mac.hellos.next() != nil)
        #expect(await statuses.first { isNetwork($0) } != nil)
        #expect(discoveries.all.count == 2)
        #expect(store.writeCount == 1)
    }

    @Test func aWiFiHelloAckFromAnotherHostIdClosesTheLinkAndNeverWrites() async throws {
        let mac = try await WiFiMac(secret: secret, reply: .helloAck(hostId: UUID().uuidString))
        defer { mac.cancel() }
        let store = RecordingSecrets([PairingAccounts.mac(mac.hostId): secret])
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: store, hello: hello,
                                        wifi: testWiFi(Discoveries([mac.discovered()]))) { statuses.put($0) }
        defer { session.stop() }

        // The Mac dialed as X answers as Y: the client closes the link, unconfigured.
        #expect(await mac.hellos.next() != nil)
        mac.answer(.helloAck(hostId: mac.hostId))
        #expect(await mac.closes.next() == true)
        // The next dial reaches the real X.
        #expect(await mac.hellos.next() != nil)
        let up = await statuses.first { isConfigured($0) }
        #expect(up.map(isNetwork) == true)
        #expect(store.writeCount == 0)
        #expect(store.inner.allSecrets() == [PairingAccounts.mac(mac.hostId): secret])
    }

    @Test func aWiFiDialFinishingAfterAUSBLinkArrivesIsClosedWithoutHello() async throws {
        let mac = try await WiFiMac(secret: secret)
        defer { mac.cancel() }
        let probe = DialProbe(holdsDial: true)
        let store = RecordingSecrets([PairingAccounts.usbHost: secret, PairingAccounts.mac(mac.hostId): secret])
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: store, hello: hello,
                                        wifi: testWiFi(Discoveries([mac.discovered()]), probe: probe)) { statuses.put($0) }
        defer { session.stop() }

        // The Wi-Fi dial is under way (all three connections up, held before returning)…
        #expect(await probe.held.next() == true)
        #expect(await statuses.first { if case .connecting(let name, ["lo0"]) = $0 { name == "Mac mini" } else { false } } != nil)
        // …when the cable brings a USB link.
        let (usb, _, _) = try await HostLink.open(dialer: LoopbackDialer(port: session.port),
                                                  secrets: InMemorySecretStore(["IPAD": secret]), peerID: "IPAD",
                                                  allowPairing: false)
        defer { usb.close() }
        let usbMessages = Inbox<Message>()
        usb.realtime.setHandler { usbMessages.put($0.message) }
        usb.realtime.send(.helloAck(helloAck(hostId: mac.hostId)))
        #expect(await statuses.first { isConfigured($0, via: .usb) } != nil)

        // The dial finishes now: the Mac gets the link, and the client closes it without Hello.
        probe.gate.open()
        #expect(await probe.released.next() == true)
        #expect(await mac.unused.next() == true)
        #expect(await mac.hellos.next(within: 0.5) == nil)
        // USB stays current: its link still answers, and no status replaced it.
        usb.realtime.send(.ping(Ping(id: 5, sentAtNs: 1)))
        #expect(await usbMessages.first { isPong($0, 5) } != nil)
        #expect(await statuses.next(within: 0.3) == nil)
    }

    @Test func stopDuringADialInstallsNothing() async throws {
        let mac = try await WiFiMac(secret: secret)
        defer { mac.cancel() }
        let probe = DialProbe(holdsDial: true)
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: testWiFi(Discoveries([mac.discovered()]), probe: probe)) {
            statuses.put($0)
        }
        #expect(await probe.held.next() == true)
        session.stop()
        while await statuses.next(within: 0.05) != nil {}   // what was published before the stop

        // The held dial completes after the stop (its task was cancelled, its connections are up).
        probe.gate.open()
        #expect(await probe.released.next() == true)
        #expect(await mac.unused.next() == true)
        #expect(await mac.hellos.next(within: 0.5) == nil)
        #expect(await statuses.next(within: 0.3) == nil)
        #expect(session.input.sync { $0.isConfigured } == false)
    }

    /// The owner switches away while a dial is under way: iPadOS suspends the app soon, so the finished
    /// dial is closed without `Hello` (the Mac starts no session for it); back in front, the loop dials
    /// again.
    @Test func aDialFinishingInTheBackgroundIsClosedUnusedAndRedialedInFront() async throws {
        let mac = try await WiFiMac(secret: secret)
        defer { mac.cancel() }
        let probe = DialProbe(holdsDial: true)
        let discoveries = Discoveries([mac.discovered()])
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: testWiFi(discoveries, probe: probe)) { statuses.put($0) }
        defer { session.stop() }

        #expect(await probe.held.next() == true)
        session.sceneDidEnterBackground()
        let first = try #require(discoveries.all.first)
        #expect(await eventually { first.isCancelled })   // the background reached the loop

        // The dial finishes in the background: its link reaches the Mac and is closed unused.
        probe.gate.open()
        #expect(await probe.released.next() == true)
        #expect(await mac.unused.next() == true)
        #expect(await mac.hellos.next(within: 0.5) == nil)
        #expect(await statuses.first(within: 0.3) { if case .connected = $0 { true } else { false } } == nil)

        // In front again: a new discovery, a new dial, a session.
        session.sceneDidBecomeActive()
        #expect(await mac.hellos.next() != nil)
        #expect(await statuses.first { isNetwork($0) } != nil)
        #expect(discoveries.all.count == 2)
    }

    /// A link that stops being current is freed, streams and all (its channels keep their handlers for
    /// life, and those hold the link): when the Mac ends it, when USB replaces it, and at `stop()`.
    @Test func aLinkThatStopsBeingCurrentIsFreed() async throws {
        let mac = try await WiFiMac(secret: secret)
        defer { mac.cancel() }
        let probe = DialProbe()
        let store = RecordingSecrets([PairingAccounts.usbHost: secret, PairingAccounts.mac(mac.hostId): secret])
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: store, hello: hello, video: ClientVideoPipeline(),
                                        wifi: testWiFi(Discoveries([mac.discovered()]), probe: probe)) { statuses.put($0) }
        defer { session.stop() }

        // The Mac ends a Wi-Fi session.
        #expect(await statuses.first { isNetwork($0) } != nil)
        #expect(probe.liveStreams == 3)
        try #require(await mac.links.next()).link.close()
        #expect(await eventually { probe.liveStreams == 0 })

        // The next one is replaced by USB.
        #expect(await statuses.first { isNetwork($0) } != nil)
        #expect(probe.liveStreams == 3)
        let (usb, _, _) = try await HostLink.open(dialer: LoopbackDialer(port: session.port),
                                                  secrets: InMemorySecretStore(["IPAD": secret]), peerID: "IPAD",
                                                  allowPairing: false)
        usb.realtime.send(.helloAck(helloAck(hostId: mac.hostId)))
        #expect(await statuses.first { isConfigured($0, via: .usb) } != nil)
        #expect(await eventually { probe.liveStreams == 0 })

        // The cable goes: a third Wi-Fi session is current when the session stops.
        usb.close()
        #expect(await statuses.first { isNetwork($0) } != nil)
        #expect(probe.liveStreams == 3)
        session.stop()
        #expect(await eventually { probe.liveStreams == 0 })
        #expect(probe.dialed.count == 3)
    }

    @Test func busyDelaysTheNextDialByTheBusyBackoff() async throws {
        let mac = try await WiFiMac(secret: secret, reply: .close)
        defer { mac.cancel() }
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: testWiFi(Discoveries([mac.discovered()]))) { statuses.put($0) }
        defer { session.stop() }

        // A link that ends before HelloAck is retried after the short failure backoff…
        let first = try #require(await mac.hellos.next())
        mac.answer(.busy)
        let second = try #require(await mac.hellos.next())
        #expect(elapsed(first.at, second.at) < WiFiTimes.busy - 0.1)
        // …but Error(busy) holds the next dial for at least the busy backoff, and the status says why.
        #expect(await statuses.first { $0 == .hostBusy(hostName: "Mac mini") } != nil)
        mac.answer(.helloAck(hostId: mac.hostId))
        let third = try #require(await mac.hellos.next(within: 5))
        #expect(elapsed(second.at, third.at) >= WiFiTimes.busy)
        #expect(await statuses.first { isNetwork($0) } != nil)
    }

    /// A USB link replacing a Wi-Fi one while the Wi-Fi link still has messages in flight: delivered
    /// late, they change neither the cursor overlay, the cursor, nor what the new link acks.
    @Test func staleMessagesOnAReplacedLinkChangeNothing() async throws {
        let mac = try await WiFiMac(secret: secret)
        defer { mac.cancel() }
        let probe = DialProbe(wrapsStreams: true)
        let store = RecordingSecrets([PairingAccounts.usbHost: secret, PairingAccounts.mac(mac.hostId): secret])
        let statuses = Inbox<ClientSession.Status>()
        let video = ClientVideoPipeline()
        let session = try ClientSession(port: 0, secrets: store, hello: hello, video: video,
                                        wifi: testWiFi(Discoveries([mac.discovered()]), probe: probe)) { statuses.put($0) }
        defer { session.stop() }
        #expect(await statuses.first { isConfigured($0) } != nil)
        let wifiLink = try #require(await mac.links.next()).link
        let realtime = try #require(probe.stream(.realtime)), wifiVideo = try #require(probe.stream(.video))

        // The Wi-Fi Mac's last messages reach the iPad but wait in its streams.
        realtime.hold()
        wifiVideo.hold()
        let staleShape = CursorShape(shapeId: 1, pixelWidth: 1, pixelHeight: 1, scale: 1, hotspotX: 0, hotspotY: 0,
                                     pixels: [0, 0, 255, 255])
        let stale: [Message] = [.cursorShape(staleShape), .cursorSelect(CursorSelect(shapeId: 1, visible: true)),
                                .cursorWarp(CursorWarp(x: 100, y: 200))]
        stale.forEach { wifiLink.realtime.send($0) }
        let staleFrame = Message.videoFrame(VideoFrame(frameId: 99, configId: 1, captureTimeNs: 0, encodeDoneNs: 0,
                                                       isKeyframe: true, data: [0, 0, 0, 1, 0x26]))
        wifiLink.video.send(staleFrame)
        let realtimeBytes = stale.map { MessageCodec.encode($0, sequence: 0, timestampNs: 0).count }.reduce(0, +)
        let videoBytes = MessageCodec.encode(staleFrame, sequence: 0, timestampNs: 0).count
        #expect(await eventually { realtime.heldBytes >= realtimeBytes && wifiVideo.heldBytes >= videoBytes })

        // The cable: USB replaces the Wi-Fi link, with its own cursor shape 1.
        let (usb, _, _) = try await HostLink.open(dialer: LoopbackDialer(port: session.port),
                                                  secrets: InMemorySecretStore(["IPAD": secret]), peerID: "IPAD",
                                                  allowPairing: false)
        defer { usb.close() }
        let usbVideo = Inbox<Message>(), usbRealtime = Inbox<Message>()
        usb.video.setHandler { usbVideo.put($0.message) }
        usb.realtime.setHandler { usbRealtime.put($0.message) }
        usb.realtime.send(.helloAck(helloAck(hostId: mac.hostId)))
        let shape = CursorShape(shapeId: 1, pixelWidth: 1, pixelHeight: 1, scale: 1, hotspotX: 0, hotspotY: 0,
                                pixels: [255, 0, 0, 255])
        usb.realtime.send(.cursorShape(shape))
        usb.realtime.send(.cursorSelect(CursorSelect(shapeId: 1, visible: true)))
        #expect(await statuses.first { isConfigured($0, via: .usb) } != nil)
        #expect(await eventually { video.cursor.current.sprite.pixels == shape.pixels })
        session.input.sync { _ in }
        let cursor = session.input.cursor, version = video.cursor.version
        #expect(cursor.x == 688 && cursor.y == 516)   // recentred by the USB HelloAck

        // Now the stale messages land. The replaced link's channels drop them (its handlers were
        // released); the generation gating covers a message already in a handler (LinkGenerationTests).
        await realtime.release()
        await wifiVideo.release()
        session.input.sync { _ in }
        #expect(video.cursor.version == version && video.cursor.current.sprite.pixels == shape.pixels)
        #expect(session.input.cursor == cursor)
        #expect(await usbVideo.next(within: 0.3) == nil)   // no FrameAck for frame 99 on the USB link
        #expect(await usbRealtime.first(within: 0.3) { if case .keyframeRequest = $0 { true } else { false } } == nil)
        #expect(video.stats().framesReceived == 0)
    }

    @Test func aDeniedDiscoveryIsReportedAndAFailedOneIsRecreated() async throws {
        let discoveries = Discoveries(states: [.denied])
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets(), hello: hello, wifi: testWiFi(discoveries)) {
            statuses.put($0)
        }
        defer { session.stop() }
        #expect(await statuses.first { $0 == .localNetworkDenied } != nil)
        #expect(ClientStatus(.localNetworkDenied).detail.contains("Settings › Privacy & Security › Local Network"))

        // A browser that dies (mDNSResponder's connection went defunct) is replaced after a backoff.
        let first = try #require(discoveries.all.first)
        first.update(state: .failed("defunct"))
        try #require(await eventually { discoveries.all.count == 2 && first.isCancelled })
        #expect(await statuses.first { $0 == .searching } != nil)

        // The background pauses browsing; back in front, a new discovery starts.
        let second = discoveries.all[1]
        session.sceneDidEnterBackground()
        #expect(await eventually { second.isCancelled })
        #expect(await statuses.first { $0 == .listening(port: session.port, wifi: true) } != nil)
        session.sceneDidBecomeActive()
        #expect(await eventually { discoveries.all.count == 3 })
        #expect(await statuses.first { $0 == .searching } != nil)
    }

    @Test func aMacOnAnotherProtocolVersionIsNotDialedAndTheStatusSaysSo() async throws {
        let mac = try await WiFiMac(secret: secret)
        defer { mac.cancel() }
        let discoveries = Discoveries([mac.discovered(version: 1)])
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: testWiFi(discoveries)) { statuses.put($0) }
        defer { session.stop() }
        let status = try #require(await statuses.first { if case .versionMismatch = $0 { true } else { false } })
        #expect(status == .versionMismatch(hostName: "Mac mini", remote: 1))
        let detail = ClientStatus(status).detail
        #expect(detail.contains("protocol v1") && detail.contains("update lain on the Mac"))
        #expect(await mac.links.next(within: WiFiTimes.grace + 0.5) == nil)
        // A TXT record without a version isn't dialed either.
        discoveries.all.last?.update(hosts: [mac.discovered(version: nil)])
        #expect(await statuses.first { $0 == .versionMismatch(hostName: "Mac mini", remote: nil) } != nil)
        #expect(await mac.links.next(within: 0.4) == nil)
    }

    @Test func theLastConnectedMacIsPreferred() async throws {
        let other = ChannelAuth.randomBytes(32)
        let a = try await WiFiMac(secret: secret, name: "A Mac"), b = try await WiFiMac(secret: other, name: "B Mac")
        defer { a.cancel(); b.cancel() }
        let store = RecordingSecrets([PairingAccounts.mac(a.hostId): secret, PairingAccounts.mac(b.hostId): other])
        let discoveries = Discoveries([a.discovered(), b.discovered()])

        // B was the last one: dialed although A comes first.
        let preferB = LastConnectedHost.memory(b.hostId)
        let first = try ClientSession(port: 0, secrets: store, hello: hello, wifi: testWiFi(discoveries, lastHost: preferB)) { _ in }
        #expect(await b.hellos.next() != nil)
        #expect(await a.links.next(within: 0.3) == nil)
        first.stop()

        // With no preference, the discovery order decides.
        let noPreference = LastConnectedHost.memory()
        let second = try ClientSession(port: 0, secrets: store, hello: hello, wifi: testWiFi(discoveries, lastHost: noPreference)) { _ in }
        defer { second.stop() }
        #expect(await a.hellos.next() != nil)
        #expect(await eventually { noPreference.get() == a.hostId })
    }
}

// MARK: The loop's policies over Wi-Fi

/// What the Wi-Fi loop does between links: browsing, backoffs, the dial order among one Mac's services,
/// a Mac that refuses the key.
@Suite(.serialized) struct ClientWiFiLoopTests {
    let secret = ChannelAuth.randomBytes(32)

    /// No browse while a Wi-Fi link through the LAN is up (it would keep AWDL busy for nothing, next to
    /// the LAN's channel); browsing resumes when the link ends. (Over a peer-to-peer link it goes on:
    /// `WiFiPolicyTests.onlyAPeerToPeerLinkKeepsTheBrowse`.)
    @Test func browsingStopsDuringALANSessionAndResumesAfterIt() async throws {
        let mac = try await WiFiMac(secret: secret)
        defer { mac.cancel() }
        let discoveries = Discoveries([mac.discovered()])
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: testWiFi(discoveries)) { statuses.put($0) }
        defer { session.stop() }

        let status = try #require(await statuses.first { isNetwork($0) })
        guard case .connected(let info) = status, case .network(_, peerToPeer: false) = info.transport else {
            Issue.record("not a LAN link: \(status)")
            return
        }
        #expect(discoveries.all.count == 1 && discoveries.all[0].isCancelled)

        _ = await mac.hellos.next()
        try #require(await mac.links.next()).link.close()
        #expect(await eventually { discoveries.all.count == 2 })
        #expect(await mac.hellos.next() != nil)
        #expect(await statuses.first { isNetwork($0) } != nil)
        #expect(discoveries.all.count == 2 && discoveries.all[1].isCancelled)
    }

    /// A Mac whose listener doesn't hold this iPad's key (it lost or replaced the pairing): after two
    /// refusals in a row the status says so, and what fixes it; the loop keeps retrying every
    /// `maxBackoff` without the status flipping back to "Connecting". A service that leaves the list
    /// is forgotten: back, it is dialed afresh.
    @Test func aMacThatRefusesTheKeyIsReportedAndStillRetried() async throws {
        let mac = try await WiFiMac(secret: ChannelAuth.randomBytes(32))   // another iPad's pairing
        defer { mac.cancel() }
        let discoveries = Discoveries([mac.discovered()])
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: testWiFi(discoveries)) { statuses.put($0) }
        defer { session.stop() }

        #expect(await mac.refused.next()?.value == .unknownIdentity)
        #expect(await statuses.first { $0 == .connecting(hostName: "Mac mini", interfaces: ["lo0"]) } != nil)
        // One refusal isn't news (the next dial comes after the 0.1 s service backoff).
        #expect(await statuses.first(within: 0.05) { $0 == .pairingRefused(hostName: "Mac mini") } == nil)
        let second = try #require(await mac.refused.next())
        #expect(await statuses.first { $0 == .pairingRefused(hostName: "Mac mini") } != nil)
        #expect(ClientStatus(.pairingRefused(hostName: "Mac mini")).detail == "Connect the USB-C cable once to pair again")

        // Retried at the longest backoff (0.4 s here, where the doubling would be at 0.2 s), and the
        // status stays put through the redials.
        let third = try #require(await mac.refused.next(within: 3))
        #expect(elapsed(second.at, third.at) >= 0.35)
        #expect(await mac.refused.next(within: 3) != nil)
        #expect(await statuses.next(within: 0.1) == nil)
        #expect(await mac.links.next(within: 0.1) == nil)

        // It leaves the list and comes back (say the Mac restarted): a new service, not yet refusing.
        discoveries.all.forEach { $0.update(hosts: []) }
        #expect(await statuses.first { $0 == .searching } != nil)
        discoveries.all.forEach { $0.update(hosts: [mac.discovered()]) }
        #expect(await statuses.next() == .connecting(hostName: "Mac mini", interfaces: ["lo0"]))
    }

    /// The same with a listener that holds a key under this iPad's identity, but not its key.
    @Test func aMacWithAnotherKeyUnderThisIPadsIdentityIsReportedToo() async throws {
        let wrong = WiFiPSK(identity: WiFiPSK(secret: secret).identity, key: ChannelAuth.randomBytes(32))
        let mac = try await WiFiMac(secret: secret, psks: [wrong])
        defer { mac.cancel() }
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: testWiFi(Discoveries([mac.discovered()]))) { statuses.put($0) }
        defer { session.stop() }
        #expect(await statuses.first { $0 == .pairingRefused(hostName: "Mac mini") } != nil)
        #expect(await mac.links.next(within: 0.1) == nil)
    }

    /// Two services claim the Mac's id and nothing listens at the first: the loop goes on to the second.
    @Test func aFailingServiceFallsThroughToTheMacsOtherService() async throws {
        let mac = try await WiFiMac(secret: secret)
        defer { mac.cancel() }
        let dead = DiscoveredHost(hostId: mac.hostId, name: "A Mac", protocolVersion: LainProtocol.majorVersion,
                                  endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: try closedLoopbackPort())!),
                                  interfaceNames: ["lo0"])
        let probe = DialProbe()
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: testWiFi(Discoveries([dead, mac.discovered()]), probe: probe)) {
            statuses.put($0)
        }
        defer { session.stop() }
        #expect(await mac.hellos.next(within: 3) != nil)
        #expect(await statuses.first { isNetwork($0) } != nil)
        #expect(probe.dialed == [dead.endpoint, mac.discovered().endpoint])
    }

    /// Services that copy the Mac's public host id and stall TLS can't keep the Mac from being dialed:
    /// one Mac's services are taken in turn, each stalling one only once before the Mac's turn.
    @Test func stallingServicesCannotStarveTheMac() async throws {
        let mac = try await WiFiMac(secret: secret)
        let rogues = try (1...3).map { _ in try StallingService() }
        defer {
            mac.cancel()
            rogues.forEach { $0.cancel() }
        }
        // Listed first, as Bonjour sorts by name.
        let hosts = rogues.enumerated().map { $1.discovered(claiming: mac.hostId, name: "A rogue \($0)") } + [mac.discovered()]
        var config = testWiFi(Discoveries(hosts))
        config.dialTimeout = 0.5
        let started = MonotonicClock.now()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: config) { _ in }
        defer { session.stop() }

        let first = try #require(await mac.hellos.next(within: 5))
        #expect(rogues.map(\.accepted) == [1, 1, 1])
        #expect(elapsed(started, first.at) < WiFiTimes.grace + 3 * config.dialTimeout + 1.5)
    }

    /// Nor can one that reappears under a new endpoint after each stall: a service listed later waits
    /// behind the Mac's other services.
    @Test func aServiceReappearingUnderNewEndpointsCannotStarveTheMac() async throws {
        let mac = try await WiFiMac(secret: secret)
        let first = try StallingService(), second = try StallingService()
        defer {
            mac.cancel()
            first.cancel()
            second.cancel()
        }
        let discoveries = Discoveries([first.discovered(claiming: mac.hostId, name: "A rogue"), mac.discovered()])
        var config = testWiFi(discoveries)
        config.dialTimeout = 0.5
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: config) { _ in }
        defer { session.stop() }

        // Dialed first (listed first); while that dial stalls, it moves.
        #expect(await eventually { first.accepted == 1 })
        let moved = [second.discovered(claiming: mac.hostId, name: "A rogue (2)"), mac.discovered()]
        discoveries.show(moved)
        discoveries.all.forEach { $0.update(hosts: moved) }
        #expect(await mac.hellos.next(within: 3) != nil)
        #expect(second.accepted == 0)
    }

    /// The service that last answered with `HelloAck` is remembered with the Mac and dialed first next
    /// time, wherever discovery lists it.
    @Test func theServiceThatLastAnsweredIsDialedFirst() async throws {
        let mac = try await WiFiMac(secret: secret)
        let rogue = try StallingService()
        defer {
            mac.cancel()
            rogue.cancel()
        }
        let store = RecordingSecrets([PairingAccounts.mac(mac.hostId): secret])
        let lastHost = LastConnectedHost.memory()
        let discoveries = Discoveries([mac.discovered()])
        let before = try ClientSession(port: 0, secrets: store, hello: hello, wifi: testWiFi(discoveries, lastHost: lastHost)) { _ in }
        defer { before.stop() }
        #expect(await mac.hellos.next() != nil)
        #expect(await eventually { lastHost.service(mac.hostId) == WiFiDialPlan.serviceKey(mac.discovered().endpoint) })
        before.stop()

        discoveries.show([rogue.discovered(claiming: mac.hostId, name: "A rogue"), mac.discovered()])
        let probe = DialProbe()
        let after = try ClientSession(port: 0, secrets: store, hello: hello,
                                      wifi: testWiFi(discoveries, lastHost: lastHost, probe: probe)) { _ in }
        defer { after.stop() }
        #expect(await mac.hellos.next() != nil)
        #expect(rogue.accepted == 0 && probe.dialed == [mac.discovered().endpoint])
    }

    /// Links that end before `HelloAck` back off 0.05, 0.1, 0.2, 0.4 s (doubling); a session that ran
    /// resets that, and the next dial waits the grace instead.
    @Test func failuresBeforeHelloAckDoubleTheBackoffAndASessionResetsIt() async throws {
        let mac = try await WiFiMac(secret: secret, reply: .close)
        defer { mac.cancel() }
        var config = testWiFi(Discoveries([mac.discovered()]))
        config.failureBackoff = 0.05
        config.maxBackoff = 3.2
        let statuses = Inbox<ClientSession.Status>()
        let session = try ClientSession(port: 0, secrets: RecordingSecrets([PairingAccounts.mac(mac.hostId): secret]),
                                        hello: hello, wifi: config) { statuses.put($0) }
        defer { session.stop() }

        var hellos: [UInt64] = []
        for n in 1...5 {
            if n == 5 { mac.answer(.helloAck(hostId: mac.hostId)) }   // read at the 5th link
            hellos.append(try #require(await mac.hellos.next(within: 5)).at)
        }
        for (i, least) in [0.05, 0.1, 0.2, 0.4].enumerated() {
            #expect(elapsed(hellos[i], hellos[i + 1]) >= least, "gap \(i + 1)")
        }

        // The 5th link got HelloAck: a session. The Mac ends it; the next dial comes after the grace, and
        // the next failure backs off 0.05 s again (not the 0.8 s the doubling had reached).
        #expect(await statuses.first { isNetwork($0) } != nil)
        mac.answer(.close)
        var session5: AcceptedLink?
        while let link = await mac.links.next(within: 0.1) { session5 = link }
        let ended = MonotonicClock.now()
        try #require(session5).link.close()
        let afterSession = try #require(await mac.hellos.next(within: 5)).at
        #expect(elapsed(ended, afterSession) >= WiFiTimes.grace)
        let next = try #require(await mac.hellos.next(within: 5)).at
        #expect(elapsed(afterSession, next) >= 0.05 && elapsed(afterSession, next) < 0.75)
    }
}

func isPong(_ message: Message, _ id: UInt32) -> Bool {
    if case .pong(let p) = message { p.id == id } else { false }
}

// MARK: Dial policy, statuses and link generations

@Suite struct WiFiPolicyTests {
    @Test func onlyCanonicalPairedMacsOnOurVersionAreDialedLastConnectedFirst() {
        let x = UUID().uuidString, y = UUID().uuidString, z = UUID().uuidString
        func host(_ id: String, _ name: String, port: UInt16, version: UInt8? = LainProtocol.majorVersion) -> DiscoveredHost {
            DiscoveredHost(hostId: id, name: name, protocolVersion: version,
                           endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!))
        }
        let hosts = [host(x, "X", port: 1), host(y, "Y", port: 2), host(y, "Y (2)", port: 3), host(z, "Z", port: 4),
                     host(x.lowercased(), "x", port: 5), host(z, "Z old", port: 6, version: 1)]
        let stored = [PairingAccounts.mac(x): [UInt8](repeating: 1, count: 32), PairingAccounts.mac(y): [UInt8](repeating: 2, count: 32),
                      PairingAccounts.mac(x.lowercased()): [UInt8](repeating: 3, count: 32)]
        let plan = WiFiDialPlan(hosts: hosts, preferring: y) { stored[$0] }
        // Both of Y's services (one id advertised twice), then X; the lowercase id is never an account.
        #expect(plan.candidates.map(\.host.name) == ["Y", "Y (2)", "X"])
        #expect(plan.candidates.first?.secret == [UInt8](repeating: 2, count: 32))
        #expect(plan.needsCable.map(\.name) == ["Z"])
        #expect(plan.otherVersion == [WiFiDialPlan.OtherVersion(host: hosts[5], paired: false)])
        #expect(WiFiDialPlan(hosts: hosts, preferring: nil) { stored[$0] }.candidates.map(\.host.name) == ["X", "Y", "Y (2)"])
    }

    /// Among one Mac's services: the one that last answered first, then the least recently tried (ties
    /// in discovery order); Macs keep their order.
    @Test func oneMacsServicesAreTriedLastAnsweredFirstThenInTurn() {
        let x = UUID().uuidString, y = UUID().uuidString
        func host(_ id: String, _ name: String, port: UInt16) -> DiscoveredHost {
            DiscoveredHost(hostId: id, name: name, protocolVersion: LainProtocol.majorVersion,
                           endpoint: .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!))
        }
        let hosts = [host(x, "A", port: 1), host(y, "B", port: 2), host(x, "C", port: 3), host(x, "D", port: 4)]
        let stored = [PairingAccounts.mac(x): [UInt8](repeating: 1, count: 32), PairingAccounts.mac(y): [UInt8](repeating: 2, count: 32)]
        func order(preferring: String? = nil, lastGood: [String: String] = [:], tried: [UInt16: UInt64]) -> [String] {
            WiFiDialPlan(hosts: hosts, preferring: preferring) { stored[$0] }
                .ordered(lastGood: { lastGood[$0] }, lastTried: { endpoint in
                    guard case .hostPort(_, let port) = endpoint else { return 0 }
                    return tried[port.rawValue] ?? 0
                })
                .candidates.map(\.host.name)
        }
        // X's services, least recently tried first, then Y's; ties keep discovery order.
        #expect(order(tried: [1: 30, 3: 10, 4: 20]) == ["C", "D", "A", "B"])
        #expect(order(tried: [:]) == ["A", "C", "D", "B"])
        // The one that last answered goes first, however recently it was tried.
        #expect(order(lastGood: [x: WiFiDialPlan.serviceKey(hosts[0].endpoint)], tried: [1: 30, 3: 10, 4: 20]) == ["A", "C", "D", "B"])
        // What another Mac last answered on doesn't reorder this one's services; the last-connected Mac leads.
        #expect(order(preferring: y, lastGood: [y: WiFiDialPlan.serviceKey(hosts[3].endpoint)], tried: [1: 30, 3: 10, 4: 20])
                == ["B", "C", "D", "A"])
        // A Bonjour service is named by name, type and domain, whatever interface it was resolved on.
        #expect(WiFiDialPlan.serviceKey(.service(name: "Mac mini", type: "_lain._tcp", domain: "local.", interface: nil))
                == "Mac mini._lain._tcp.local.")
    }

    /// Browsing goes on only with no link, or over a peer-to-peer Wi-Fi link.
    @Test func onlyAPeerToPeerLinkKeepsTheBrowse() {
        let mac = DiscoveredHost(hostId: UUID().uuidString, name: "Mac mini", protocolVersion: LainProtocol.majorVersion,
                                 endpoint: .hostPort(host: .ipv4(.loopback), port: 1))
        #expect(WiFiLoop.browses(during: nil))
        #expect(!WiFiLoop.browses(during: (.usb(peer: PairingAccounts.usbHost, paired: false, secret: []), .usb)))
        #expect(!WiFiLoop.browses(during: (.wifi(mac), .network(interface: "en1", peerToPeer: false))))
        #expect(!WiFiLoop.browses(during: (.wifi(mac), .network(interface: nil, peerToPeer: false))))
        #expect(WiFiLoop.browses(during: (.wifi(mac), .network(interface: "awdl0", peerToPeer: true))))
    }

    @Test func statusesSayWhatToDo() {
        #expect(ClientStatus(.listening(port: 1)).detail == "Connect your iPad to the Mac with a USB-C cable")
        #expect(ClientStatus(.listening(port: 1, wifi: true)).detail.contains("paired Mac with Wi-Fi on"))
        #expect(ClientStatus(.needsCable(hostName: "Mac mini")).title == "Found Mac mini")
        #expect(ClientStatus(.needsCable(hostName: "Mac mini")).detail == "Connect the cable once to use it over Wi-Fi")
        #expect(ClientStatus(.versionMismatch(hostName: nil, remote: 1)).title == "The Mac runs another lain")
        #expect(ClientStatus(.versionMismatch(hostName: "Mac mini", remote: 3)).detail.contains("update lain on this iPad"))
        #expect(ClientStatus(.connecting(hostName: "Mac mini", interfaces: ["en0", "awdl0"])).detail == "over Wi-Fi (en0, awdl0)")
        #expect(ClientStatus(.pairingRefused(hostName: "Mac mini")).title == "Mac mini doesn't recognize this iPad")
        #expect(ClientStatus(.pairingRefused(hostName: "Mac mini")).detail == "Connect the USB-C cable once to pair again")
        #expect(ClientStatus.describe(.usb) == "USB")
        #expect(ClientStatus.describe(.network(interface: "awdl0", peerToPeer: true)) == "Wi-Fi · AWDL awdl0")
        #expect(ClientStatus.describe(.network(interface: "en1", peerToPeer: false)) == "Wi-Fi · LAN en1")
        var info = ClientSession.ConnectionInfo()
        info.transport = .network(interface: "awdl0", peerToPeer: true)
        info.hostName = "Mac mini"
        #expect(ClientStatus(.connected(info)).title == "Connected to Mac mini")
        #expect(ClientStatus(.connected(info)).detail.hasPrefix("Wi-Fi · AWDL awdl0 · "))
    }
}

/// A decoder that records what it was given and never outputs.
final class RecordingDecoder: FrameDecoding, Sendable {
    let frames = Mutex<[UInt32]>([])
    func decode(_ frame: VideoFrame) { frames.withLock { $0.append(frame.frameId) } }
    func finish() {}
}

/// The decoders a pipeline made, in order.
final class DecoderList: Sendable {
    private let made = Mutex<[RecordingDecoder]>([])
    func make() -> RecordingDecoder {
        let d = RecordingDecoder()
        made.withLock { $0.append(d) }
        return d
    }
    var last: RecordingDecoder? { made.withLock { $0.last } }
}

@Suite struct LinkGenerationTests {
    func envelope(_ m: Message, seq: UInt32) -> Envelope {
        Envelope(header: FrameHeader(type: m.type, sequence: seq, timestampNs: 0, payloadLength: 0), message: m)
    }

    func frame(_ id: UInt32, key: Bool = false) -> Message {
        .videoFrame(VideoFrame(frameId: id, configId: 1, captureTimeNs: 0, encodeDoneNs: 0, isKeyframe: key, data: [0, 0, 0, 1]))
    }

    @Test func aReplacedLinksVideoIsNeitherDecodedNorAcked() {
        let decoders = DecoderList()
        let pipeline = ClientVideoPipeline(requireHardware444: false, makeDecoder: { _, _, _ in decoders.make() })
        let config = VideoConfig(configId: 1, codec: .hevc, chroma: .yuv420, bitDepth: 8, width: 16, height: 16, fullRange: true,
                                 colorPrimaries: 1, transferFunction: 1, matrix: 1, parameterSets: [[1], [2], [3]])
        let old = SentBox(), new = SentBox()
        pipeline.connect(generation: 1, control: { old.append($0) }, video: { old.append($0) })
        pipeline.handleVideo(envelope(.videoConfig(config), seq: 1), generation: 1)
        pipeline.handleVideo(envelope(frame(1, key: true), seq: 2), generation: 1)
        pipeline.connect(generation: 2, control: { new.append($0) }, video: { new.append($0) })
        pipeline.handleVideo(envelope(.videoConfig(config), seq: 1), generation: 2)
        // Link 1's late frame and config: consumed, never routed, decoded or acked on link 2.
        #expect(pipeline.handleVideo(envelope(frame(9, key: true), seq: 3), generation: 1))
        #expect(pipeline.handleVideo(envelope(.ping(Ping(id: 1, sentAtNs: 0)), seq: 4), generation: 1))
        #expect(pipeline.handleVideo(envelope(.videoConfig(config), seq: 5), generation: 1))
        pipeline.handleVideo(envelope(frame(1, key: true), seq: 2), generation: 2)
        #expect(acks(new).map(\.frameId) == [1] && new.messages.count == 1)
        #expect(acks(old).map(\.frameId) == [1])
        #expect(decoders.last?.frames.withLock { $0 } == [1])
        #expect(pipeline.stats().sequenceGaps == 0 && pipeline.stats().framesReceived == 1)
        // Untagged envelopes (standalone use) always apply; a disconnect drops tagged ones.
        #expect(!pipeline.handleVideo(envelope(.ping(Ping(id: 2, sentAtNs: 0)), seq: 3)))
        pipeline.disconnect()
        #expect(pipeline.handleVideo(envelope(frame(2), seq: 4), generation: 2))
        #expect(new.messages.count == 1)
    }

    func acks(_ box: SentBox) -> [FrameAck] { box.messages.compactMap { if case .frameAck(let a) = $0 { a } else { nil } } }

    @Test func aReplacedLinksCursorShapesAreDropped() {
        let overlay = CursorOverlay()
        let shape = { (pixel: UInt8) in
            CursorShape(shapeId: 1, pixelWidth: 1, pixelHeight: 1, scale: 1, hotspotX: 0, hotspotY: 0, pixels: [pixel, 0, 0, 255])
        }
        overlay.reset(generation: 2)
        overlay.apply(.cursorShape(shape(2)), generation: 2)
        overlay.apply(.cursorSelect(CursorSelect(shapeId: 1, visible: true)), generation: 2)
        let version = overlay.version
        overlay.apply(.cursorShape(shape(1)), generation: 1)
        overlay.apply(.cursorSelect(CursorSelect(shapeId: 1, visible: false)), generation: 1)
        #expect(overlay.version == version)
        #expect(overlay.current.sprite.pixels == [2, 0, 0, 255] && overlay.current.macVisible)
        overlay.reset()
        overlay.apply(.cursorShape(shape(3)), generation: 2)
        #expect(overlay.version == version + 1)   // only the reset: nothing is current
    }

    @Test func aReplacedLinksWarpLayoutAndSettingsAreDropped() {
        let input = ClientInput()
        let sent = SentBox()
        input.adopt(link: 2)
        input.configure(ack, generation: 2)
        input.connect(generation: 2) { sent.append($0) }
        input.sync { _ in }
        let centre = input.cursor
        var other = ack
        other.displayPointWidth = 800
        input.configure(other, generation: 1)
        input.applyLayout(DesktopLayoutTests.layout, generation: 1)
        input.warp(x: 5, y: 6, generation: 1)
        input.connect(generation: 1) { _ in Issue.record("a replaced link took the input") }
        input.sync { p in #expect(!p.hasLayout && p.streamedDisplay?.width == 1376) }
        #expect(input.cursor == centre)
        input.warp(x: 7, y: 8, generation: 2)
        input.keyChanged(.key(0x04), isDown: true)
        input.sync { _ in }
        #expect(input.cursor.x == 7 && input.cursor.y == 8)
        #expect(sent.messages.count == 1)
        // After a disconnect no link is current.
        input.disconnect()
        input.warp(x: 9, y: 9, generation: 2)
        input.sync { _ in }
        #expect(input.cursor.x == 7)
    }
}
