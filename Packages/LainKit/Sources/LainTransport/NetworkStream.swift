import Dispatch
import Foundation
import LainTelemetry
import Network
import Security
import Synchronization

private let log = Telemetry.logger("wifi")

// MARK: - Parameters

/// Parameters for lain's Network.framework connections (§7.7, D29): TCP + TLS-PSK. Every call builds
/// fresh `NWParameters` (a mutable class), one per connection or listener.
public struct NetworkStreamOptions: Sendable {
    /// TCP keepalive (tunable): the first probe after 2 s idle, then every 1 s; 4 unanswered probes
    /// drop the connection, so a vanished peer ends the session in about 6 s (invariant 4).
    public static let keepaliveIdle = 2
    public static let keepaliveInterval = 1
    public static let keepaliveCount = 4
    /// Seconds before unacknowledged data (video in flight to a vanished peer) drops the connection.
    public static let connectionDropTime = 6

    /// AWDL and the other peer-to-peer interfaces. On for Wi-Fi links; the bench's `lan` mode turns it
    /// off on its listener.
    public var includePeerToPeer: Bool
    /// Tests: loopback only and never peer-to-peer; a listener binds 127.0.0.1, not the wildcard.
    public var loopbackOnly: Bool
    /// The dialer's realtime connection uses the voice access category (`.interactiveVoice`), so small
    /// input packets don't queue behind video on the radio (invariant 3); video and audio stay best
    /// effort. Off: everything best effort (the bench compares both).
    public var interactiveRealtime: Bool

    public init(includePeerToPeer: Bool = true, loopbackOnly: Bool = false, interactiveRealtime: Bool = true) {
        self.includePeerToPeer = includePeerToPeer
        self.loopbackOnly = loopbackOnly
        self.interactiveRealtime = interactiveRealtime
    }

    /// Loopback only, for tests: nothing leaves the machine and nothing is advertised.
    public static var loopback: NetworkStreamOptions { NetworkStreamOptions(includePeerToPeer: false, loopbackOnly: true) }

    /// A dialer's parameters: `kind` picks the service class; `requiredInterface` pins the path.
    public func dialParameters(psk: WiFiPSK, kind: ConnectionKind?, requiredInterface: NWInterface? = nil) -> NWParameters {
        let p = parameters(tls: WiFiTLS.clientOptions(psk))
        p.serviceClass = kind == .realtime && interactiveRealtime ? .interactiveVoice : .bestEffort
        if let requiredInterface { p.requiredInterface = requiredInterface }
        return p
    }

    /// A listener's parameters. Production keeps the wildcard dual-stack bind (awdl0 has only an IPv6
    /// link-local address); `requiredInterfaceType = .loopback` alone would still bind `*:port`.
    public func listenerParameters(psks: [WiFiPSK]) -> NWParameters {
        listenerParameters(tls: WiFiTLS.serverOptions(psks))
    }

    /// `NetworkStreamListener`'s: `offered` learns which PSK each connection's client used.
    func listenerParameters(psks: [WiFiPSK], offered: OfferedPSKIdentities) -> NWParameters {
        listenerParameters(tls: WiFiTLS.serverOptions(psks, recordingInto: offered))
    }

    private func listenerParameters(tls: NWProtocolTLS.Options) -> NWParameters {
        let p = parameters(tls: tls)
        if loopbackOnly { p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any) }
        return p
    }

    private func parameters(tls: NWProtocolTLS.Options) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = Self.keepaliveIdle
        tcp.keepaliveInterval = Self.keepaliveInterval
        tcp.keepaliveCount = Self.keepaliveCount
        tcp.connectionDropTime = Self.connectionDropTime
        let p = NWParameters(tls: tls, tcp: tcp)
        p.includePeerToPeer = includePeerToPeer && !loopbackOnly
        if loopbackOnly { p.requiredInterfaceType = .loopback }
        return p
    }
}

// MARK: - Path, TLS and errors

/// Where a connection runs, known once it is ready (§7.7): for the HUD, the host menu and the bench.
public struct NetworkPath: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// AWDL or low-latency WLAN (awdl*, llw*): direct, no router.
        case peerToPeer
        /// Through the Wi-Fi network (the LAN path).
        case wifi
        /// Ethernet, including the iPad's USB-Ethernet CoreDevice link while the cable is in.
        case wired
        case loopback
        case other
    }

    /// The interface's BSD name ("" if unknown). Names differ per machine: never hardcode them.
    public var interfaceName: String
    public var kind: Kind
    public var interface: NWInterface?
    /// The far end as resolved (address and port), e.g. `fe80::…%awdl0` for a Bonjour service.
    public var remoteEndpoint: NWEndpoint?
    public var localEndpoint: NWEndpoint?

    public init(interface: NWInterface?, remoteEndpoint: NWEndpoint? = nil, localEndpoint: NWEndpoint? = nil) {
        self.interface = interface
        interfaceName = interface?.name ?? ""
        kind = Self.kind(interfaceName: interfaceName, type: interface?.type)
        self.remoteEndpoint = remoteEndpoint
        self.localEndpoint = localEndpoint
    }

    init(_ path: NWPath?) {
        self.init(interface: path?.availableInterfaces.first, remoteEndpoint: path?.remoteEndpoint,
                  localEndpoint: path?.localEndpoint)
    }

    /// By name first (awdl0 and llw0 report as Wi-Fi or other), then by type.
    public static func kind(interfaceName name: String, type: NWInterface.InterfaceType?) -> Kind {
        if name.hasPrefix("awdl") || name.hasPrefix("llw") { return .peerToPeer }
        switch type {
        case .loopback?: return .loopback
        case .wifi?: return .wifi
        case .wiredEthernet?: return .wired
        default: return name.hasPrefix("lo") ? .loopback : .other
        }
    }

    /// This path as a link's transport: the interface (nil if unknown) and whether it is AWDL/LLW.
    public var linkTransport: LinkTransport {
        .network(interface: interfaceName.isEmpty ? nil : interfaceName, peerToPeer: kind == .peerToPeer)
    }
}

extension LinkTransport {
    /// What `stream` runs over: a Network.framework stream's path, anything else USB (the usbmuxd pipe,
    /// or the iPad's loopback listener it feeds). `LinkDialer`'s and `LinkAcceptor`'s default.
    public init(stream: any ByteStream) {
        self = (stream as? NetworkStream)?.path.linkTransport ?? .usb
    }
}

/// What the TLS handshake negotiated (D29 expects TLS 1.2 with 0xCCAC).
public struct NegotiatedTLS: Sendable, Equatable, CustomStringConvertible {
    public var version: UInt16
    public var cipherSuite: UInt16

    public init(version: UInt16, cipherSuite: UInt16) {
        self.version = version
        self.cipherSuite = cipherSuite
    }

    init?(_ connection: NWConnection) {
        guard let meta = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        let sec = meta.securityProtocolMetadata
        self.init(version: sec_protocol_metadata_get_negotiated_tls_protocol_version(sec).rawValue,
                  cipherSuite: sec_protocol_metadata_get_negotiated_tls_ciphersuite(sec).rawValue)
    }

    public var description: String {
        let name = version == WiFiTLS.version ? "TLS 1.2" : "TLS 0x" + String(version, radix: 16)
        return name + " suite 0x" + String(cipherSuite, radix: 16, uppercase: true)
    }
}

/// Why a Network.framework dial, handshake or stream failed, classified for status and backoff.
public enum NetworkStreamError: Error, Equatable, Sendable {
    /// The peer holds no PSK with our identity (-9864): the Mac doesn't have this pairing loaded.
    case unknownIdentity
    /// The identity matched but the key didn't (-9820 on the client, -9846 on the server).
    case wrongKey
    /// Any other TLS failure.
    case tls(OSStatus)
    /// TLS completed on something other than `WiFiTLS.required`, e.g. a plain-PSK suite without forward
    /// secrecy (nil: no TLS metadata): refused like a failed handshake (D29).
    case unexpectedTLS(NegotiatedTLS?)
    /// Local Network access is off for this app (TN3179): Privacy & Security › Local Network.
    case localNetworkDenied
    /// Nothing listens there (ECONNREFUSED).
    case refused
    /// Not ready within the dial or handshake deadline.
    case timeout
    case posix(Int32)
    case dns(Int32)
    case other(String)

    /// `path` is the connection's current path: a denied one says so in `unsatisfiedReason`.
    public static func classify(_ error: NWError, path: NWPath? = nil) -> NetworkStreamError {
        if path?.unsatisfiedReason == .localNetworkDenied { return .localNetworkDenied }
        switch error {
        case .tls(let status) where status == errSSLUnknownPSKIdentity:
            return .unknownIdentity
        case .tls(let status) where [errSSLPeerBadRecordMac, errSSLBadRecordMac, errSSLPeerDecryptionFail,
                                     errSSLDecryptionFail].contains(status):
            return .wrongKey
        case .tls(let status):
            return .tls(status)
        case .posix(.ECONNREFUSED):
            return .refused
        case .posix(let code):
            return .posix(code.rawValue)
        case .dns(let code) where Int(code) == kDNSServiceErr_PolicyDenied:
            return .localNetworkDenied
        case .dns(let code):
            return .dns(code)
        default:
            return .other(error.debugDescription)
        }
    }
}

// MARK: - NetworkStream

/// A `ByteStream` over a Network.framework TCP + TLS-PSK connection (§7.7, D29). Dialers and the
/// listener hand it out only once ready, with its path and TLS known. A state machine (connecting →
/// open → closing → closed) under one `stateUpdateHandler` for the connection's whole life:
/// - bytes and the close go from the connection's private queue to the consumer's queue in order
///   (bytes that arrive with the peer's EOF before the nil close), and the close is reported once;
/// - `close()` delivers what is queued, then cancels (the peer sees EOF); a peer that stops reading
///   can't hold it past `closeDeadline` (then `forceCancel`). After it, incoming bytes and writes are
///   dropped, and however the connection ends counts as a clean close (nil);
/// - a failure before `start` is remembered and reported at `start` (as `SocketStream` does);
/// - the connection's handlers capture the `Core`, never the stream, so a stream dropped without
///   `close()` deinits and closes; cancellation releases them.
public final class NetworkStream: ByteStream {
    /// Seconds a local close waits for queued writes before it force-cancels.
    public static let closeDeadline = 1.5
    static let receiveChunk = 256 * 1024

    /// The interface and far end (see `NetworkPath`).
    public let path: NetworkPath
    public let tls: NegotiatedTLS?
    /// The PSK identity TLS authenticated: the dialer's own, or the one the client offered to the
    /// listener (nil if TLS didn't report it). Names one pairing (`isBound(toSecret:)`).
    public let pskIdentity: String?
    /// Start to ready: resolution, TCP and TLS for a dial; the TLS handshake for an accepted connection.
    public let handshakeNs: UInt64
    let core: Core

    struct Opened: Sendable {
        var path: NetworkPath
        var tls: NegotiatedTLS?
        var pskIdentity: String?
        var handshakeNs: UInt64
    }

    init(core: Core, opened: Opened) {
        self.core = core
        path = opened.path
        tls = opened.tls
        pskIdentity = opened.pskIdentity
        handshakeNs = opened.handshakeNs
    }

    deinit { core.close() }

    public func start(queue: DispatchQueue, onBytes: @escaping @Sendable ([UInt8]) -> Void,
                      onClose: @escaping @Sendable ((any Error)?) -> Void) {
        core.start(queue: queue, onBytes: onBytes, onClose: onClose)
    }

    public func write(_ bytes: [UInt8]) { core.write(bytes) }

    public func close() { core.close() }

    /// Connects with `psk` and waits for `.ready`. Fails on `.failed`, on `.waiting` (it never waits
    /// for a better path), on the timeout and on task cancellation, always cancelling the connection.
    static func connect(to endpoint: NWEndpoint, using parameters: NWParameters, psk: WiFiPSK, timeout: Double,
                        label: String) async throws -> NetworkStream {
        let identity = psk.identity
        let core = Core(connection: NWConnection(to: endpoint, using: parameters), label: label) { _ in identity }
        let opened = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Opened, any Error>) in
                core.open(timeout: timeout) { continuation.resume(with: $0) }
            }
        } onCancel: {
            core.abort(CancellationError())
        }
        let stream = NetworkStream(core: core, opened: opened)
        if Task.isCancelled {
            stream.close()
            throw CancellationError()
        }
        return stream
    }
}

extension NetworkStream: PairingBoundStream {
    /// TLS proved the key of exactly one pairing, `WiFiPSK(secret:)`, named by its identity. When TLS
    /// didn't say which (the listener learns it from the PSK selection block, documented for clients),
    /// the `ChannelHello` HMAC, which already proves a stored secret, decides alone.
    public func isBound(toSecret secret: [UInt8]) -> Bool {
        guard let pskIdentity else { return true }
        return WiFiPSK(secret: secret).identity == pskIdentity
    }
}

extension NetworkStream {
    /// The connection and its state: the only thing the connection's handlers capture. Every
    /// connection callback runs on `queue` (private, serial); so do sends, receives and the close.
    final class Core: Sendable {
        enum Phase: Equatable { case connecting, open, closing, closed }

        private struct Consumer {
            let queue: DispatchQueue
            let onBytes: @Sendable ([UInt8]) -> Void
            let onClose: @Sendable ((any Error)?) -> Void
        }

        private struct State {
            var phase = Phase.connecting
            /// The dial or accept waiting for `.ready`; called exactly once.
            var opening: (@Sendable (Result<Opened, any Error>) -> Void)?
            /// Why connecting failed, for an `open` that comes after the failure.
            var failure: (any Error)?
            var connectionStarted = false
            var startedAtNs: UInt64 = 0
            /// Writes handed to the connection and not yet processed; a close waits for them.
            var sending = 0
            var started = false
            var consumer: Consumer?
            /// A close that happened before `start`, reported there.
            var outcome: ((any Error)?)?
            var receiving = false
        }

        let connection: NWConnection
        let queue: DispatchQueue
        /// The PSK identity TLS authenticated, asked once the connection is ready.
        private let pskIdentity: @Sendable (NWConnection) -> String?
        private let state = Mutex(State())

        init(connection: NWConnection, label: String, pskIdentity: @escaping @Sendable (NWConnection) -> String?) {
            self.connection = connection
            self.pskIdentity = pskIdentity
            queue = DispatchQueue(label: label, qos: .userInteractive)
        }

        var phase: Phase { state.withLock { $0.phase } }

        /// Starts the connection; `completion` gets `.ready` (with the path and TLS) or the first
        /// failure: `.failed`, `.waiting`, the deadline or `abort`. A failure cancels the connection.
        func open(timeout: Double, completion: @escaping @Sendable (Result<Opened, any Error>) -> Void) {
            queue.async { [self] in
                let early = state.withLock { s -> (any Error)? in
                    guard s.phase == .connecting, s.opening == nil else { return s.failure ?? TransportError.closed }
                    s.opening = completion
                    s.connectionStarted = true
                    s.startedAtNs = MonotonicClock.now()
                    return nil
                }
                if let early { return completion(.failure(early)) }
                connection.stateUpdateHandler = { [self] in stateChanged($0) }
                connection.start(queue: queue)
                // Weak: a force-cancelled connection keeps its socket until the `NWConnection` goes away
                // (measured 2026-09-29), so a strong deadline would hold every aborted or evicted
                // handshake's descriptor until the deadline.
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.failConnecting(NetworkStreamError.timeout) }
            }
        }

        /// Fails a connection that isn't ready yet (task cancellation, a cancelled listener).
        func abort(_ error: any Error) {
            queue.async { [self] in failConnecting(error) }
        }

        func start(queue consumerQueue: DispatchQueue, onBytes: @escaping @Sendable ([UInt8]) -> Void,
                   onClose: @escaping @Sendable ((any Error)?) -> Void) {
            let closed = state.withLock { s -> ((any Error)?)? in
                precondition(!s.started, "NetworkStream.start called twice")
                s.started = true
                if let outcome = s.outcome { return .some(outcome) }
                s.consumer = Consumer(queue: consumerQueue, onBytes: onBytes, onClose: onClose)
                return nil
            }
            if let closed {
                consumerQueue.async { onClose(closed) }
                return
            }
            queue.async { [self] in receiveIfNeeded() }
        }

        func write(_ bytes: [UInt8]) {
            queue.async { [self] in
                let open = state.withLock { s -> Bool in
                    guard s.phase == .open else { return false }
                    s.sending += 1
                    return true
                }
                guard open else { return }
                connection.send(content: bytes, completion: .contentProcessed { [self] error in sent(error) })
            }
        }

        func close() {
            queue.async { [self] in closeNow() }
        }

        // MARK: Private queue

        private func stateChanged(_ new: NWConnection.State) {
            switch new {
            case .ready:
                becameReady()
            case .waiting(let error), .failed(let error):
                let classified = NetworkStreamError.classify(error, path: connection.currentPath)
                switch phase {
                case .connecting: failConnecting(classified)
                // An established TCP connection can't move to another path: waiting means gone.
                case .open: finish(classified)
                // A local close was asked for; how the teardown went doesn't matter.
                case .closing, .closed: finish(nil)
                }
            case .cancelled:
                finish(nil)
                connection.stateUpdateHandler = nil
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }

        /// TLS is done. Only `WiFiTLS.required` opens, in both roles: Network.framework also enables the
        /// plain-PSK suites, so a peer can pick one (see `WiFiTLS`). Anything else, or no TLS metadata,
        /// fails the dial or the accept.
        private func becameReady() {
            let now = MonotonicClock.now()
            let tls = NegotiatedTLS(connection)
            guard tls == WiFiTLS.required else { return failConnecting(NetworkStreamError.unexpectedTLS(tls)) }
            let (path, identity) = (NetworkPath(connection.currentPath), pskIdentity(connection))
            let ready = state.withLock { s -> (opening: (@Sendable (Result<Opened, any Error>) -> Void)?, since: UInt64)? in
                guard s.phase == .connecting else { return nil }
                s.phase = .open
                defer { s.opening = nil }
                return (s.opening, s.startedAtNs)
            }
            guard let ready else { return }
            ready.opening?(.success(Opened(path: path, tls: tls, pskIdentity: identity, handshakeNs: now &- ready.since)))
        }

        private func failConnecting(_ error: any Error) {
            let taken = state.withLock { s -> (opening: (@Sendable (Result<Opened, any Error>) -> Void)?, started: Bool)? in
                guard s.phase == .connecting else { return nil }
                s.phase = .closed
                s.failure = error
                defer { s.opening = nil }
                return (s.opening, s.connectionStarted)
            }
            guard let taken else { return }
            if taken.started { connection.forceCancel() }
            taken.opening?(.failure(error))
        }

        private func receiveIfNeeded() {
            let go = state.withLock { s -> Bool in
                guard !s.receiving, s.phase == .open || s.phase == .closing else { return false }
                s.receiving = true
                return true
            }
            if go { receiveNext() }
        }

        private func receiveNext() {
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: NetworkStream.receiveChunk) { [self] data, _, isComplete, error in
                received(data, isComplete: isComplete, error: error)
            }
        }

        private func received(_ data: Data?, isComplete: Bool, error: NWError?) {
            let (phase, consumer) = state.withLock { ($0.phase, $0.consumer) }
            guard phase == .open else {
                // Closing: drain and drop until the connection ends. Closed: stop.
                if phase == .closing, !isComplete, error == nil { return receiveNext() }
                state.withLock { $0.receiving = false }
                return
            }
            if let data, !data.isEmpty, let consumer {
                let bytes = [UInt8](data)
                consumer.queue.async { consumer.onBytes(bytes) }
            }
            // A reset completes the receive with `isComplete` and the error: only an error-free end is EOF.
            if let error { return finish(NetworkStreamError.classify(error, path: connection.currentPath)) }
            if isComplete { return finish(nil) }
            receiveNext()
        }

        /// Reports the close exactly once, after the bytes already queued for the consumer, and
        /// releases the connection.
        private func finish(_ error: (any Error)?) {
            let (first, consumer) = state.withLock { s -> (Bool, Consumer?) in
                guard s.phase != .closed else { return (false, nil) }
                s.phase = .closed
                if !s.started { s.outcome = .some(error) }
                defer { s.consumer = nil }
                return (true, s.consumer)
            }
            guard first else { return }
            connection.cancel()
            if let consumer { consumer.queue.async { consumer.onClose(error) } }
        }

        /// A write was processed. The last one outstanding lets a pending close go ahead.
        private func sent(_ error: NWError?) {
            let (phase, idle) = state.withLock { s -> (Phase, Bool) in
                s.sending -= 1
                return (s.phase, s.sending == 0)
            }
            if phase == .open, let error { return finish(NetworkStreamError.classify(error)) }
            if phase == .closing, idle { cancelWhenFlushed() }
        }

        /// Over TLS, Network.framework has no half-close: a `.finalMessage` send never reaches the
        /// peer as EOF (plain TCP does), only `cancel()` does (close_notify + FIN). And cancelling as
        /// soon as every write is processed still dropped 96–128 KB of records in 16 of 300 closes
        /// (measured 2026-09-29): "processed" isn't "on the wire". So the close cancels once every
        /// write is processed and the kernel holds nothing unacknowledged, draining (and dropping)
        /// what arrives meanwhile, since unread bytes can turn a close into a reset.
        private func closeNow() {
            let (phase, idle) = state.withLock { s -> (Phase, Bool) in
                defer { if s.phase == .open { s.phase = .closing } }
                return (s.phase, s.sending == 0)
            }
            switch phase {
            case .connecting:
                failConnecting(TransportError.closed)
            case .open:
                receiveIfNeeded()
                if idle { cancelWhenFlushed() }
                queue.asyncAfter(deadline: .now() + NetworkStream.closeDeadline) { [self] in
                    if self.phase != .closed {
                        log.notice("close deadline: queued data still unacknowledged; force-cancelling")
                        connection.forceCancel()
                    }
                }
            case .closing, .closed:
                break
            }
        }

        /// Cancels once the kernel reports no bytes waiting for an acknowledgement, twice, 1 ms apart:
        /// Network.framework refills a writable socket at once, so an empty send buffer that stays
        /// empty means nothing is left above it either. A peer that never acknowledges leaves it to
        /// the close deadline.
        private func cancelWhenFlushed(emptyBefore: Bool = false) {
            guard phase == .closing else { return }
            let tcp = connection.metadata(definition: NWProtocolTCP.definition) as? NWProtocolTCP.Metadata
            let empty = (tcp?.availableSendBuffer ?? 0) == 0
            if empty && emptyBefore { return connection.cancel() }
            queue.asyncAfter(deadline: .now() + .milliseconds(empty ? 1 : 2)) { [self] in cancelWhenFlushed(emptyBefore: empty) }
        }
    }
}

// MARK: - Dialers

/// Dials one endpoint over TCP + TLS-PSK (§7.7). Stateless: every dial resolves the endpoint on its
/// own. Tests and diagnostics use it; a Wi-Fi link uses `WiFiLinkDialer`, which keeps its three
/// connections on one path.
public struct NetworkStreamDialer: StreamDialer {
    public static let defaultTimeout = 5.0

    public let endpoint: NWEndpoint
    public let psk: WiFiPSK
    public let options: NetworkStreamOptions
    public let timeout: Double

    public init(endpoint: NWEndpoint, psk: WiFiPSK, options: NetworkStreamOptions = NetworkStreamOptions(),
                timeout: Double = NetworkStreamDialer.defaultTimeout) {
        self.endpoint = endpoint
        self.psk = psk
        self.options = options
        self.timeout = timeout
    }

    public func dial() async throws -> any ByteStream { try await connect(kind: nil) }

    public func dial(kind: ConnectionKind) async throws -> any ByteStream { try await connect(kind: kind) }

    /// Throws `NetworkStreamError` (or `CancellationError`); see `NetworkStream.connect`.
    public func connect(kind: ConnectionKind?) async throws -> NetworkStream {
        do {
            return try await NetworkStream.connect(to: endpoint, using: options.dialParameters(psk: psk, kind: kind), psk: psk,
                                                   timeout: timeout, label: "lain.wifi.\(kind.map { "\($0)" } ?? "stream")")
        } catch let error as NetworkStreamError {
            let what = "dial \(endpoint.debugDescription) failed: \(error)"
            log.notice("\(what, privacy: .public)")
            throw error
        }
    }
}

/// The dialer of one Wi-Fi link attempt (§7.7, D29). The first connection (realtime) dials the
/// discovered endpoint, a Bonjour `.service` resolved at connect time; once it is ready, its resolved
/// address and interface are pinned, and video and audio dial exactly there with `requiredInterface`,
/// so all three share one path instead of each racing onto AWDL or the LAN. Create one per attempt.
public final class WiFiLinkDialer: StreamDialer {
    /// Where the connections after the first go.
    public struct Pin: Sendable, Equatable {
        /// The first connection's resolved far end (or the discovered endpoint if it had none).
        public var endpoint: NWEndpoint
        public var interface: NWInterface?
    }

    public let endpoint: NWEndpoint
    public let psk: WiFiPSK
    public let options: NetworkStreamOptions
    public let timeout: Double
    private let pin = Mutex<Pin?>(nil)

    /// Peer-to-peer stays on whatever `options` say (without it awdl0 is excluded); only a
    /// loopback-only test dialer goes without.
    public init(endpoint: NWEndpoint, psk: WiFiPSK, options: NetworkStreamOptions = NetworkStreamOptions(),
                timeout: Double = NetworkStreamDialer.defaultTimeout) {
        var options = options
        options.includePeerToPeer = true
        self.endpoint = endpoint
        self.psk = psk
        self.options = options
        self.timeout = timeout
    }

    public var pinned: Pin? { pin.withLock { $0 } }

    public func dial() async throws -> any ByteStream { try await connect(kind: nil) }

    public func dial(kind: ConnectionKind) async throws -> any ByteStream { try await connect(kind: kind) }

    public func connect(kind: ConnectionKind?) async throws -> NetworkStream {
        let current = pinned
        let name = kind.map { "\($0)" } ?? "stream"
        let target = current?.endpoint ?? endpoint
        let stream: NetworkStream
        do {
            stream = try await NetworkStream.connect(
                to: target, using: options.dialParameters(psk: psk, kind: kind, requiredInterface: current?.interface), psk: psk,
                timeout: timeout, label: "lain.wifi.\(name)")
        } catch let error as NetworkStreamError {
            let what = "dial \(name) to \(target.debugDescription) failed: \(error)"
            log.notice("\(what, privacy: .public)")
            throw error
        }
        let via = stream.path.interfaceName
        if let current {
            if let want = current.interface?.name, via != want {
                let what = "\(name) connection runs on \(via), realtime on \(want)"
                log.error("\(what, privacy: .public)")
            }
        } else {
            let first = Pin(endpoint: stream.path.remoteEndpoint ?? endpoint, interface: stream.path.interface)
            pin.withLock { if $0 == nil { $0 = first } }
            let tls = stream.tls?.description ?? "no TLS"
            let what = "\(name) up via \(via) (\(stream.path.kind.rawValue)), \(tls); pinning \(first.endpoint.debugDescription)"
            log.notice("\(what, privacy: .public)")
        }
        return stream
    }
}

// MARK: - Listener

/// Accepts TLS-PSK connections (§7.7, D29), optionally advertised over Bonjour. Each accepted
/// connection is handed to `onAccept` only once `.ready` (TLS done; path and the client's PSK identity
/// known); one that isn't ready within `handshakeTimeout` is force-cancelled, so the acceptor's own
/// `ChannelHello` deadline measures the same thing as on USB. Cancelling the listener leaves
/// handed-over streams alone.
///
/// Anyone on the LAN or in AWDL range can connect, so unauthenticated handshakes are capped: at most
/// `maxPendingHandshakes` at once, `maxPendingHandshakesPerHost` per remote address. Past a cap the
/// oldest handshake goes, the same address's first (`PendingHandshakes`), silently. A real client is
/// done in milliseconds, so a flood of idle connections only evicts its own, and the descriptors it can
/// take stay a few dozen: the process's USB connections need them too.
public final class NetworkStreamListener: Sendable {
    /// Seconds from accept to TLS done. A real client needs milliseconds (1–8 ms over loopback; AWDL or
    /// the LAN add a few round trips).
    public static let handshakeTimeout = 3.0
    /// Handshakes in progress at once, in total and per remote address.
    public static let maxPendingHandshakes = 32
    public static let maxPendingHandshakesPerHost = 8

    public enum State: Equatable, Sendable {
        case setup
        /// Listening (and registering, when advertised) on this port.
        case ready(port: UInt16)
        /// Not listening yet, e.g. `.localNetworkDenied`.
        case waiting(NetworkStreamError)
        /// Dead: create a new listener (with backoff).
        case failed(NetworkStreamError)
        case cancelled
    }

    public enum Event: Equatable, Sendable {
        case state(State)
        /// Bonjour registered the service under this name: the computer name, or a renamed one after
        /// a conflict.
        case registered(name: String)
        case unregistered(name: String)
        /// A connection failed its handshake (TLS, or not ready in time) and was dropped. Rate-limited
        /// (`DropReports`); evicted handshakes aren't reported.
        case rejected(NetworkStreamError)
    }

    /// A Bonjour advertisement: the apps and the bench only, never tests.
    public struct Advertisement: Sendable, Equatable {
        public var type: String
        /// nil: the computer name.
        public var name: String?
        public var txt: [String: String]

        public init(type: String, name: String? = nil, txt: [String: String]) {
            self.type = type
            self.name = name
            self.txt = txt
        }
    }

    /// The PSK identities it accepts (logged at start; the keys never are).
    public let identities: [String]
    private let listener: NWListener
    private let box: Box

    /// Starts listening at once. Events and accepted streams arrive on the listener's private queue.
    public init(psks: [WiFiPSK], options: NetworkStreamOptions = NetworkStreamOptions(),
                advertisement: Advertisement? = nil, handshakeTimeout: Double = NetworkStreamListener.handshakeTimeout,
                onEvent: @escaping @Sendable (Event) -> Void = { _ in },
                onAccept: @escaping @Sendable (NetworkStream) -> Void) throws {
        precondition(advertisement == nil || !options.loopbackOnly, "a loopback-only listener never advertises")
        identities = psks.map(\.identity)
        let offered = OfferedPSKIdentities()
        let listener = try NWListener(using: options.listenerParameters(psks: psks, offered: offered))
        let box = Box(handshakeTimeout: handshakeTimeout, offered: offered, onEvent: onEvent, onAccept: onAccept)
        if let advertisement {
            listener.service = NWListener.Service(name: advertisement.name, type: advertisement.type, domain: nil,
                                                  txtRecord: NWTXTRecord(advertisement.txt))
            listener.serviceRegistrationUpdateHandler = { [box] in box.registrationChanged($0) }
        }
        listener.stateUpdateHandler = { [box, weak listener] in box.stateChanged($0, port: listener?.port?.rawValue) }
        listener.newConnectionHandler = { [box] in box.accept($0) }
        self.listener = listener
        self.box = box
        let what = "PSK identities \(identities.joined(separator: ", ")); \(advertisement.map { "advertising \($0.type)" } ?? "not advertised")"
        log.notice("Wi-Fi listener starting: \(what, privacy: .public)")
        listener.start(queue: box.queue)
    }

    deinit { cancel() }

    public var port: UInt16? { listener.port?.rawValue }

    /// Stops listening and advertising and drops pending handshakes; streams already handed over
    /// stay up.
    public func cancel() {
        listener.cancel()
        box.cancelPending()
    }

    /// Accepted connections still in their handshake (tests).
    var pendingHandshakes: Int { box.pendingCount }

    /// The listener's handler state: what its handlers capture instead of the listener.
    private final class Box: Sendable {
        let queue = DispatchQueue(label: "lain.wifi.listener", qos: .userInitiated)
        private let handshakeTimeout: Double
        private let offered: OfferedPSKIdentities
        private let onEvent: @Sendable (Event) -> Void
        private let onAccept: @Sendable (NetworkStream) -> Void

        private struct Intake {
            /// Connections still in their handshake, oldest first.
            var pending = PendingHandshakes<NetworkStream.Core>(limit: NetworkStreamListener.maxPendingHandshakes,
                                                                 perHost: NetworkStreamListener.maxPendingHandshakesPerHost)
            var cancelled = false
            var drops = DropReports()
        }
        private let intake = Mutex(Intake())

        init(handshakeTimeout: Double, offered: OfferedPSKIdentities, onEvent: @escaping @Sendable (Event) -> Void,
             onAccept: @escaping @Sendable (NetworkStream) -> Void) {
            self.handshakeTimeout = handshakeTimeout
            self.offered = offered
            self.onEvent = onEvent
            self.onAccept = onAccept
        }

        var pendingCount: Int { intake.withLock { $0.pending.count } }

        /// On `queue`. Network.framework hands connections over in `.setup`, before TLS. Admitting one
        /// past a cap evicts an older one; an evicted handshake ends as not pending, so unreported.
        func accept(_ connection: NWConnection) {
            let core = NetworkStream.Core(connection: connection, label: "lain.wifi.accepted") { [offered] in
                offered.take(for: $0)
            }
            let host = NetworkStreamListener.remoteHost(of: connection.endpoint)
            let admitted = intake.withLock { s -> (key: UInt64, evicted: [NetworkStream.Core], summarize: Bool)? in
                guard !s.cancelled else { return nil }
                let (key, evicted) = s.pending.admit(core, from: host)
                return (key, evicted, s.drops.evicted(evicted.count))
            }
            guard let (key, evicted, summarize) = admitted else { return connection.cancel() }
            // Nothing may keep an evicted core, not even the new core's completion (it takes only the
            // key): a force-cancelled connection's socket closes only when the connection goes.
            evicted.forEach { $0.abort(CancellationError()) }
            if summarize { summarizeLater() }
            core.open(timeout: handshakeTimeout) { [self] result in
                queue.async { [self] in handshakeEnded(key, core, result) }
            }
        }

        private func handshakeEnded(_ key: UInt64, _ core: NetworkStream.Core,
                                    _ result: Result<NetworkStream.Opened, any Error>) {
            let wasPending = intake.withLock { $0.pending.remove(key) != nil }
            switch result {
            case .success(let opened):
                let stream = NetworkStream(core: core, opened: opened)
                guard wasPending else { return stream.close() }
                if opened.pskIdentity == nil {
                    log.error("TLS didn't report which PSK the client used: its ChannelHello HMAC alone decides the pairing")
                }
                onAccept(stream)
            case .failure(let error):
                // Evicted, or dropped by `cancel()`: not pending any more, and not a rejection.
                guard wasPending, let error = error as? NetworkStreamError else { return }
                let now = MonotonicClock.now()
                let (report, summarize) = intake.withLock { $0.drops.rejected(at: now) }
                if summarize { summarizeLater() }
                guard report else { return }
                log.notice("dropped a connection before handover: \(String(describing: error), privacy: .public)")
                onEvent(.rejected(error))
            }
        }

        /// One notice for what went unreported, a window after the first of it.
        private func summarizeLater() {
            queue.asyncAfter(deadline: .now() + DropReports.window) { [self] in
                let (unreported, evicted) = intake.withLock { $0.drops.takeSummary() }
                log.notice("handshake flood: \(evicted) pending handshakes evicted, \(unreported) failed handshakes not reported")
            }
        }

        func cancelPending() {
            let cores = intake.withLock { s -> [NetworkStream.Core] in
                s.cancelled = true
                return s.pending.removeAll()
            }
            cores.forEach { $0.abort(CancellationError()) }
        }

        func stateChanged(_ state: NWListener.State, port: UInt16?) {
            let mapped: State
            switch state {
            case .setup: mapped = .setup
            case .ready: mapped = .ready(port: port ?? 0)
            case .waiting(let error): mapped = .waiting(.classify(error))
            case .failed(let error): mapped = .failed(.classify(error))
            case .cancelled: mapped = .cancelled
            @unknown default: return
            }
            log.notice("Wi-Fi listener \(String(describing: mapped), privacy: .public)")
            onEvent(.state(mapped))
        }

        func registrationChanged(_ change: NWListener.ServiceRegistrationChange) {
            switch change {
            case .add(.service(let name, _, _, _)):
                log.notice("advertising as \(name, privacy: .public)")
                onEvent(.registered(name: name))
            case .remove(.service(let name, _, _, _)):
                onEvent(.unregistered(name: name))
            default:
                break
            }
        }
    }

    /// What the per-host cap counts: the remote address without its port ("" for anything else).
    static func remoteHost(of endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        return "\(host)"
    }
}

/// A listener's handshakes in progress, oldest first, within `limit` in total and `perHost` per remote
/// address. Admitting one past a cap evicts the oldest from the same address, else the oldest overall:
/// a flood of idle connections evicts its own, and a real client, done in milliseconds, goes only if a
/// flood outpaces its handshake. (Refusing the newest instead would let a few idle connections a second
/// keep everyone out.) Keys are admission numbers, never reused.
struct PendingHandshakes<Item> {
    let limit: Int
    let perHost: Int
    private var entries: [(key: UInt64, host: String, item: Item)] = []
    private var lastKey: UInt64 = 0

    init(limit: Int, perHost: Int) {
        precondition(limit > 0 && perHost > 0, "caps must admit something")
        self.limit = limit
        self.perHost = perHost
    }

    var count: Int { entries.count }

    func count(from host: String) -> Int { entries.reduce(0) { $0 + ($1.host == host ? 1 : 0) } }

    /// Admits `item` from `host`: its key, and what it evicted, oldest first.
    mutating func admit(_ item: Item, from host: String) -> (key: UInt64, evicted: [Item]) {
        var evicted: [Item] = []
        while count(from: host) >= perHost || entries.count >= limit {
            evicted.append(entries.remove(at: entries.firstIndex { $0.host == host } ?? 0).item)
        }
        lastKey += 1
        entries.append((lastKey, host, item))
        return (lastKey, evicted)
    }

    /// The item admitted under `key`; nil once evicted or removed.
    mutating func remove(_ key: UInt64) -> Item? {
        guard let i = entries.firstIndex(where: { $0.key == key }) else { return nil }
        return entries.remove(at: i).item
    }

    mutating func removeAll() -> [Item] {
        defer { entries.removeAll() }
        return entries.map { $0.item }
    }
}

/// What a listener says about the connections it drops before handover, so that a flood can't flood the
/// log or the event consumer: at most `limit` failed handshakes a `window` are reported one by one (a
/// notice and `.rejected`); the rest, like every eviction, are only counted, and one summary notice
/// follows a window after the first of them.
struct DropReports {
    static let limit = 5
    /// Seconds.
    static let window = 1.0

    private var windowStart: UInt64?
    private var reported = 0
    private var unreportedCount = 0
    private var evictedCount = 0
    private var summaryScheduled = false

    /// A handshake failed at `now` (ns): whether to report it, and whether to schedule the summary.
    mutating func rejected(at now: UInt64) -> (report: Bool, summarize: Bool) {
        if windowStart.map({ now &- $0 >= UInt64(Self.window * 1e9) }) ?? true {
            windowStart = now
            reported = 0
        }
        if reported < Self.limit {
            reported += 1
            return (true, false)
        }
        unreportedCount += 1
        return (false, summaryDue())
    }

    /// `count` pending handshakes were evicted: whether to schedule the summary.
    mutating func evicted(_ count: Int) -> Bool {
        guard count > 0 else { return false }
        evictedCount += count
        return summaryDue()
    }

    /// The counts since the last summary, reset.
    mutating func takeSummary() -> (unreported: Int, evicted: Int) {
        defer { (unreportedCount, evictedCount, summaryScheduled) = (0, 0, false) }
        return (unreportedCount, evictedCount)
    }

    /// True for the first count since the last summary.
    private mutating func summaryDue() -> Bool {
        defer { summaryScheduled = true }
        return !summaryScheduled
    }
}
