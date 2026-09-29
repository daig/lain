import Dispatch
import LainTelemetry
import Synchronization

/// The three authenticated connections of one session (§7.1).
public struct Link: Sendable {
    public let sessionToken: [UInt8]
    public let realtime: MessageChannel
    public let video: MessageChannel
    public let audio: MessageChannel
    /// What the link runs over, read from its realtime connection (§7.7).
    public let transport: LinkTransport

    public init(sessionToken: [UInt8], realtime: MessageChannel, video: MessageChannel, audio: MessageChannel,
                transport: LinkTransport = .usb) {
        self.sessionToken = sessionToken
        self.realtime = realtime
        self.video = video
        self.audio = audio
        self.transport = transport
    }

    public var channels: [MessageChannel] { [realtime, video, audio] }

    public func close() { channels.forEach { $0.close() } }
}

/// USB through usbmuxd (§7.2), or a Network.framework path (§7.7): the realtime connection's interface
/// (awdl0, en1…; nil if unknown) and whether it is peer-to-peer (AWDL/LLW).
public enum LinkTransport: Sendable, Hashable {
    case usb
    case network(interface: String?, peerToPeer: Bool)
}

/// Opens byte streams to the peer: usbmuxd `Connect` over USB, plain loopback TCP in tests,
/// Network.framework over Wi-Fi (§7.7).
public protocol StreamDialer: Sendable {
    func dial() async throws -> any ByteStream
    /// One connection of a link: a Wi-Fi dialer marks realtime traffic and keeps all three on one path.
    /// Defaults to `dial()`.
    func dial(kind: ConnectionKind) async throws -> any ByteStream
}

extension StreamDialer {
    public func dial(kind: ConnectionKind) async throws -> any ByteStream { try await dial() }
}

public struct LoopbackDialer: StreamDialer {
    public let port: UInt16
    public init(port: UInt16) { self.port = port }
    public func dial() async throws -> any ByteStream { try TCP.connectLoopback(port: port) }
}

#if os(macOS)
import LainUSBMux

/// Dials the client's listener through usbmuxd (§7.2).
public struct USBMuxDialer: StreamDialer {
    public let client: USBMuxClient
    public let deviceID: Int
    public let port: UInt16

    /// `port` nil: `LainProtocol.usbPort`.
    public init(client: USBMuxClient = USBMuxClient(), deviceID: Int, port: UInt16? = nil) {
        self.client = client
        self.deviceID = deviceID
        self.port = port ?? LainProtocol.usbPort
    }

    public func dial() async throws -> any ByteStream {
        SocketStream(fd: try await client.connect(deviceID: deviceID, port: port), label: "lain.usbmux")
    }
}
#endif

// MARK: - Dialer

/// The dialer role (§7.6, §7.7 D29): opens realtime, video and audio and sends `ChannelHello` on each,
/// plus `Pair` on realtime when pairing (USB only). Over USB the host dials; over Wi-Fi the client does.
/// The acceptor answers only to refuse (an `Error`, then a close); the handshake reply that follows
/// (`Hello` over USB, `HelloAck` over Wi-Fi) is read with `reply(on:timeoutSeconds:)`.
public struct LinkDialer: Sendable {
    public let dialer: any StreamDialer
    public let label: String
    /// Runs on each new stream before its channel starts (HostLink: the video socket's small send
    /// buffer, §7.3).
    public let configure: @Sendable (ConnectionKind, any ByteStream) -> Void
    /// What the link runs over, read from its realtime stream (by default the stream's own path:
    /// `LinkTransport(stream:)`).
    public let transport: @Sendable (any ByteStream) -> LinkTransport

    public init(dialer: any StreamDialer, label: String = "lain.link",
                configure: @escaping @Sendable (ConnectionKind, any ByteStream) -> Void = { _, _ in },
                transport: @escaping @Sendable (any ByteStream) -> LinkTransport = { LinkTransport(stream: $0) }) {
        self.dialer = dialer
        self.label = label
        self.configure = configure
        self.transport = transport
    }

    /// A new session authenticated with a stored secret.
    public func open(secret: [UInt8]) async throws -> Link { try await open(secret: secret, pair: nil) }

    /// USB pairing (D23): realtime's hello carries the all-zero HMAC and is followed by `pair`; video
    /// and audio authenticate with its secret.
    public func open(pairing pair: Pair) async throws -> Link { try await open(secret: pair.secret, pair: pair) }

    private func open(secret: [UInt8], pair: Pair?) async throws -> Link {
        let token = ChannelAuth.randomBytes(ChannelHello.tokenSize)
        var opened: [MessageChannel] = []
        do {
            func connect(_ kind: ConnectionKind) async throws -> MessageChannel {
                let stream = try await dialer.dial(kind: kind)
                configure(kind, stream)
                let channel = MessageChannel(stream: stream, label: "\(label).\(kind)")
                opened.append(channel)
                channel.start()
                if kind == .realtime, let pair {
                    channel.send(.channelHello(ChannelAuth.hello(kind: kind, token: token, secret: nil)))
                    channel.send(.pair(pair))
                } else {
                    channel.send(.channelHello(ChannelAuth.hello(kind: kind, token: token, secret: secret)))
                }
                return channel
            }
            let realtime = try await connect(.realtime)
            let video = try await connect(.video)
            let audio = try await connect(.audio)
            return Link(sessionToken: token, realtime: realtime, video: video, audio: audio,
                        transport: transport(realtime.stream))
        } catch {
            opened.forEach { $0.close() }
            throw error
        }
    }

    /// The peer's first message on realtime. A refusal throws: `Error(authenticationFailed)` as
    /// `authenticationFailed`; `Error(versionMismatch)`, or a close after a frame in another major
    /// version, as `versionMismatch` (§7.5). Anything else, other `Error`s included, is returned.
    public static func reply(on link: Link, timeoutSeconds: Double) async throws(TransportError) -> Envelope {
        let first = try await link.realtime.next(timeoutSeconds: timeoutSeconds)
        if case .error(let e) = first.message {
            switch e.code {
            case .authenticationFailed: throw .authenticationFailed
            case .versionMismatch: throw .versionMismatch(remote: 0)   // framed in ours: the peer's is unknown
            default: break
            }
        }
        return first
    }
}

// MARK: - Host side (USB)

/// The host dials, authenticates and (over USB) pairs (§7.5 handshake steps 1–2, §7.6).
public enum HostLink {
    public static let handshakeTimeout = 5.0
    /// Video writes block on a small kernel buffer instead of queueing below the app (§7.3).
    public static let videoSendBuffer = 128 * 1024

    /// Opens realtime, video and audio, sends `ChannelHello` on each, and waits for the client's
    /// `Hello`. With no stored secret, or when the client rejects ours and `allowPairing` is set (USB),
    /// it pairs: a zero-HMAC hello plus `Pair` (carrying `hostId`, so the client can store the secret for
    /// Wi-Fi too) on realtime. The new secret is stored once `Hello` arrives. `paired` says whether this
    /// session paired (true) or authenticated with the stored secret. A client that couldn't read its
    /// secret (`Error(internal)`) fails the attempt without re-pairing: the caller just retries.
    public static func open(dialer: some StreamDialer, secrets: some SecretStore, peerID: String,
                            allowPairing: Bool, hostId: String = "") async throws -> (link: Link, hello: Hello, paired: Bool) {
        let stored = try secrets.secret(for: peerID)
        if stored == nil && !allowPairing { throw TransportError.noSecret }
        let links = LinkDialer(dialer: dialer, label: "lain.host", configure: { kind, stream in
            if kind == .video, let socket = stream as? SocketStream { socket.setSendBufferSize(videoSendBuffer) }
        })
        do {
            return try await attempt(links, secrets: secrets, peerID: peerID, secret: stored, hostId: hostId)
        } catch TransportError.authenticationFailed where stored != nil && allowPairing {
            Telemetry.logger("link").notice("client rejected stored secret; re-pairing over USB")
            return try await attempt(links, secrets: secrets, peerID: peerID, secret: nil, hostId: hostId)
        }
    }

    private static func attempt(_ links: LinkDialer, secrets: some SecretStore, peerID: String, secret stored: [UInt8]?,
                                hostId: String) async throws -> (link: Link, hello: Hello, paired: Bool) {
        let secret = stored ?? ChannelAuth.randomBytes(Pair.secretSize)
        let link: Link
        if stored != nil {
            link = try await links.open(secret: secret)
        } else {
            link = try await links.open(pairing: Pair(secret: secret, hostId: hostId))
        }
        do {
            let first = try await LinkDialer.reply(on: link, timeoutSeconds: handshakeTimeout)
            switch first.message {
            case .hello(let hello):
                if stored == nil { try secrets.setSecret(secret, for: peerID) }
                return (link, hello, stored == nil)
            case .error(let e):
                throw TransportError.unexpectedMessage("Error(\(e.code)): \(e.message)")
            default:
                throw TransportError.unexpectedMessage("\(first.message.type)")
            }
        } catch {
            link.close()
            throw error
        }
    }
}

// MARK: - Acceptor

/// A link the acceptor authenticated (§7.7 D29).
public struct AcceptedLink: Sendable {
    public let link: Link
    /// The stored account whose secret the dialer used (on the client "host" or `mac:<hostId>`, on the
    /// host the iPad's USB serial), or the account a pairing stored the new secret under.
    public let peer: String
    /// The session's secret: it verified all three `ChannelHello`s.
    public let secret: [UInt8]
    /// This link paired (USB only) instead of authenticating with a stored secret.
    public let paired: Bool

    public init(link: Link, peer: String, secret: [UInt8], paired: Bool) {
        self.link = link
        self.peer = peer
        self.secret = secret
        self.paired = paired
    }
}

/// The acceptor role (§7.6, §7.7 D29). Every accepted connection must open with a valid `ChannelHello`
/// within `helloTimeout`. Realtime starts a session, authenticated by a stored secret (or paired, where
/// `pairing` allows it); video and audio join it by session token under that session's secret, waiting
/// up to `helloTimeout` for their realtime. Once all three are in, `onLink` gets the link and the
/// acceptor forgets the session, keeping only its token (a late join is closed): what happens to an
/// earlier link is the consumer's policy. A session whose video and audio don't follow its realtime
/// within `helloTimeout` is dropped. On a connection whose transport already authenticated one pairing
/// (`PairingBoundStream`: Wi-Fi TLS-PSK), a `ChannelHello` under any other secret is refused, so the
/// HMAC and the TLS key always name the same pairing.
public final class LinkAcceptor: Sendable {
    public static let helloTimeout = 3.0
    /// Tokens of delivered and dropped sessions kept to close late joins; older ones fall back to the
    /// wait for a realtime that never comes.
    static let rememberedTokens = 64

    public enum Pairing: Sendable {
        /// A zero-HMAC hello is refused: wireless never pairs (D13).
        case refuse
        /// USB only (D23): a zero-HMAC realtime hello plus `Pair` is accepted. `store` persists the secret
        /// (a throw answers `Error(internal)`); the link's peer is `peer`.
        case accept(peer: String, store: @Sendable (Pair) throws -> Void)
    }

    private let control: DispatchQueue
    private let label: String
    private let secrets: any SecretStore
    private let primaryAccount: String?
    private let pairing: Pairing
    private let transport: @Sendable (any ByteStream) -> LinkTransport
    private let onReject: @Sendable (any Error) -> Void
    private let onLink: @Sendable (AcceptedLink) -> Void
    private let log = Telemetry.logger("link")

    private struct Session {
        var token: [UInt8]
        var secret: [UInt8]
        var peer: String
        var paired: Bool
        var realtime: MessageChannel
        var video: MessageChannel?
        var audio: MessageChannel?
        var channels: [MessageChannel] { [realtime, video, audio].compactMap { $0 } }
    }

    private struct State {
        var cancelled = false
        /// Connections that still owe their `ChannelHello` (and, pairing, `Pair`).
        var handshaking: [ObjectIdentifier: MessageChannel] = [:]
        /// Sessions whose realtime is in, waiting for video and audio.
        var pending: [Session] = []
        /// Video/audio connections that arrived before their realtime connection.
        var waiting: [(hello: ChannelHello, channel: MessageChannel)] = []
        /// Tokens of delivered and dropped sessions, newest last.
        var finished: [[UInt8]] = []

        /// Takes a connection out of the handshake; false if it already left (expired, closed, cancelled).
        mutating func leaveHandshake(_ channel: MessageChannel) -> Bool {
            handshaking.removeValue(forKey: ObjectIdentifier(channel)) != nil
        }

        mutating func finish(_ token: [UInt8]) {
            finished.append(token)
            if finished.count > LinkAcceptor.rememberedTokens { finished.removeFirst() }
        }
    }
    private let state = Mutex(State())

    /// - Parameters:
    ///   - primaryAccount: tried first, with the one read USB always made (the client's "host"); if that
    ///     read throws the connection gets `Error(internal)`, so the dialer retries instead of re-pairing.
    ///     Every other stored account is a further candidate, listed with `allSecrets()`, whose failure is
    ///     only logged. Without a primary account (the host), `allSecrets()` is the read that must work.
    ///     `authenticationFailed` thus always means "read fine, nothing matched".
    ///   - transport: what an accepted link runs over, read from its realtime stream (by default the
    ///     stream's own path: `LinkTransport(stream:)`).
    ///   - onReject: a refused connection, on the acceptor's queue: `TransportError.versionMismatch` (the
    ///     peer runs another lain: worth telling the owner), `.authenticationFailed`, `.unexpectedMessage`,
    ///     or the secret store's error.
    ///   - onLink: a complete link, on the acceptor's queue.
    public init(secrets: some SecretStore, primaryAccount: String? = nil, pairing: Pairing = .refuse,
                label: String = "lain.acceptor",
                transport: @escaping @Sendable (any ByteStream) -> LinkTransport = { LinkTransport(stream: $0) },
                onReject: @escaping @Sendable (any Error) -> Void = { _ in },
                onLink: @escaping @Sendable (AcceptedLink) -> Void) {
        control = DispatchQueue(label: "\(label).acceptor", qos: .userInitiated)
        self.label = label
        self.secrets = secrets
        self.primaryAccount = primaryAccount
        self.pairing = pairing
        self.transport = transport
        self.onReject = onReject
        self.onLink = onLink
    }

    deinit { cancel() }

    /// Takes a connected stream that hasn't been started (the USB listener's socket, a Wi-Fi listener's
    /// TLS connection). After `cancel()` it is closed at once.
    public func accept(_ stream: any ByteStream) {
        let channel = MessageChannel(stream: stream, label: "\(label).conn", answeringVersionMismatch: true)
        let admitted = state.withLock { s -> Bool in
            guard !s.cancelled else { return false }
            s.handshaking[ObjectIdentifier(channel)] = channel
            return true
        }
        guard admitted else { return stream.close() }
        channel.setCloseHandler { [weak self, weak channel] error in
            guard let self, let channel else { return }
            control.async { self.closedEarly(channel, error) }
        }
        channel.receiveOnce { [weak self, weak channel] env in
            guard let self, let channel else { return }
            control.async { self.handleFirst(env, on: channel) }
        }
        channel.start()
        control.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in self?.expire(channel) }
    }

    /// Closes every connection not yet delivered and refuses new ones. Delivered links are the consumer's.
    public func cancel() {
        let s = state.withLock { s -> State in
            s.cancelled = true
            defer { s.handshaking = [:]; s.pending = []; s.waiting = [] }
            return s
        }
        s.handshaking.values.forEach { $0.close() }
        s.pending.forEach { $0.channels.forEach { $0.close() } }
        s.waiting.forEach { $0.channel.close() }
    }

    // MARK: Handshake (all on `control`)

    private func isHandshaking(_ channel: MessageChannel) -> Bool {
        state.withLock { $0.handshaking[ObjectIdentifier(channel)] != nil }
    }

    /// Answers `Error(code)` so the dialer can say why, then closes.
    private func reject(_ channel: MessageChannel, _ code: ErrorMessage.Code, _ why: String, _ error: any Error) {
        _ = state.withLock { $0.leaveHandshake(channel) }
        log.error("rejecting connection: \(why, privacy: .public)")
        channel.send(.error(ErrorMessage(code: code, message: why)))
        channel.close()
        onReject(error)
    }

    /// The connection closed during its handshake. A first frame in another major version was already
    /// answered by the channel (§7.5): report it.
    private func closedEarly(_ channel: MessageChannel, _ error: (any Error)?) {
        guard state.withLock({ $0.leaveHandshake(channel) }) else { return }
        guard let e = error as? TransportError, case .versionMismatch(let remote) = e else { return }
        log.error("rejecting connection: protocol v\(remote) (answered in v\(remote))")
        onReject(e)
    }

    private func expire(_ channel: MessageChannel) {
        guard state.withLock({ $0.leaveHandshake(channel) }) else { return }
        log.error("closing a connection that sent no ChannelHello in \(Self.helloTimeout) s")
        channel.close()
    }

    private func handleFirst(_ env: Envelope, on channel: MessageChannel) {
        guard isHandshaking(channel) else { return }
        guard case .channelHello(let hello) = env.message else {
            return reject(channel, .authenticationFailed, "first message was \(env.message.type)",
                          TransportError.unexpectedMessage("\(env.message.type)"))
        }
        guard hello.protocolVersion == LainProtocol.majorVersion else {
            return reject(channel, .versionMismatch, "protocol v\(hello.protocolVersion)",
                          TransportError.versionMismatch(remote: hello.protocolVersion))
        }
        switch hello.connectionKind {
        case .realtime where hello.hmac == ChannelAuth.pairingMAC:
            guard case .accept(let peer, let store) = pairing else {
                return reject(channel, .authenticationFailed, "pairing not accepted here", TransportError.authenticationFailed)
            }
            channel.receiveOnce { [weak self, weak channel] env in
                guard let self, let channel else { return }
                control.async { self.handlePair(env, hello, on: channel, peer: peer, store: store) }
            }
        case .realtime:
            let match: (peer: String, secret: [UInt8])?
            do {
                match = try candidate(for: hello)
            } catch {
                return reject(channel, .internal, "could not read the pairing secrets", error)
            }
            guard let match else {
                return reject(channel, .authenticationFailed, "bad HMAC", TransportError.authenticationFailed)
            }
            guard isBound(channel, to: match.secret) else {
                return reject(channel, .authenticationFailed, "HMAC under another pairing than the TLS key",
                              TransportError.authenticationFailed)
            }
            establish(hello, peer: match.peer, secret: match.secret, paired: false, realtime: channel)
        case .video, .audio:
            route(hello, channel)
        }
    }

    /// The stored secret `hello` was made with, and its account (the rules are `init`'s).
    private func candidate(for hello: ChannelHello) throws -> (peer: String, secret: [UInt8])? {
        func matching(_ all: [String: [UInt8]]) -> (peer: String, secret: [UInt8])? {
            // Few candidates; each check is constant-time (§7.6).
            all.sorted { $0.key < $1.key }.first { ChannelAuth.isValid(hello, secret: $0.value) }.map { ($0.key, $0.value) }
        }
        guard let primary = primaryAccount else { return matching(try secrets.allSecrets()) }
        if let secret = try secrets.secret(for: primary), ChannelAuth.isValid(hello, secret: secret) {
            return (primary, secret)
        }
        do {
            return matching(try secrets.allSecrets().filter { $0.key != primary })
        } catch {
            log.error("could not list the pairing secrets (\(String(describing: error), privacy: .public)); only \(primary, privacy: .public) was tried")
            return nil
        }
    }

    /// A connection whose transport authenticated one pairing (Wi-Fi TLS-PSK) carries only that
    /// pairing's `ChannelHello`; others (USB) have nothing to check.
    private func isBound(_ channel: MessageChannel, to secret: [UInt8]) -> Bool {
        (channel.stream as? any PairingBoundStream)?.isBound(toSecret: secret) ?? true
    }

    private func handlePair(_ env: Envelope, _ hello: ChannelHello, on channel: MessageChannel, peer: String,
                            store: @Sendable (Pair) throws -> Void) {
        guard isHandshaking(channel) else { return }
        guard case .pair(let pair) = env.message else {
            return reject(channel, .authenticationFailed, "expected Pair, got \(env.message.type)",
                          TransportError.unexpectedMessage("\(env.message.type)"))
        }
        do {
            try store(pair)
        } catch {
            return reject(channel, .internal, "could not store pairing secret", error)
        }
        log.notice("paired over USB (\(peer, privacy: .public))")
        establish(hello, peer: peer, secret: pair.secret, paired: true, realtime: channel)
    }

    // MARK: Sessions (all on `control`)

    private func establish(_ hello: ChannelHello, peer: String, secret: [UInt8], paired: Bool, realtime: MessageChannel) {
        let token = hello.sessionToken
        enum Outcome: Sendable { case gone, duplicate, established(early: [(hello: ChannelHello, channel: MessageChannel)]) }
        let outcome = state.withLock { s -> Outcome in
            guard s.leaveHandshake(realtime) else { return .gone }
            guard !s.finished.contains(token), !s.pending.contains(where: { $0.token == token }) else { return .duplicate }
            s.pending.append(Session(token: token, secret: secret, peer: peer, paired: paired, realtime: realtime))
            let early = s.waiting.filter { $0.hello.sessionToken == token }
            s.waiting.removeAll { $0.hello.sessionToken == token }
            return .established(early: early)
        }
        switch outcome {
        case .gone:
            return
        case .duplicate:
            log.error("closing a second realtime connection for one session")
            realtime.close()
        case .established(let early):
            control.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in self?.dropIncomplete(token) }
            for w in early { join(w.hello, w.channel, secret: secret) }
        }
    }

    /// A video or audio connection: joins its session, or waits for the session's realtime.
    private func route(_ hello: ChannelHello, _ channel: MessageChannel) {
        let token = hello.sessionToken
        enum Route: Sendable { case gone, late, join(secret: [UInt8]), wait }
        let route = state.withLock { s -> Route in
            guard s.leaveHandshake(channel) else { return .gone }
            if s.finished.contains(token) { return .late }
            if let session = s.pending.first(where: { $0.token == token }) { return .join(secret: session.secret) }
            s.waiting.append((hello, channel))
            return .wait
        }
        switch route {
        case .gone:
            return
        case .late:
            let kind = "\(hello.connectionKind)"
            log.error("closing a late \(kind, privacy: .public) connection: its session was already delivered or dropped")
            channel.close()
        case .join(let secret):
            join(hello, channel, secret: secret)
        case .wait:
            control.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in self?.dropWaiting(channel) }
        }
    }

    private func join(_ hello: ChannelHello, _ channel: MessageChannel, secret: [UInt8]) {
        guard ChannelAuth.isValid(hello, secret: secret) else {
            return reject(channel, .authenticationFailed, "bad HMAC on \(hello.connectionKind)", TransportError.authenticationFailed)
        }
        guard isBound(channel, to: secret) else {
            return reject(channel, .authenticationFailed, "\(hello.connectionKind) under another pairing than its TLS key",
                          TransportError.authenticationFailed)
        }
        enum Joined: Sendable {
            case orphan
            case partial(replaced: MessageChannel?)
            case complete(Session, video: MessageChannel, audio: MessageChannel, replaced: MessageChannel?)
        }
        let joined = state.withLock { s -> Joined in
            guard let i = s.pending.firstIndex(where: { $0.token == hello.sessionToken }) else { return .orphan }
            let replaced: MessageChannel?
            if hello.connectionKind == .video {
                replaced = s.pending[i].video
                s.pending[i].video = channel
            } else {
                replaced = s.pending[i].audio
                s.pending[i].audio = channel
            }
            guard let video = s.pending[i].video, let audio = s.pending[i].audio else { return .partial(replaced: replaced) }
            let session = s.pending.remove(at: i)
            s.finish(session.token)
            return .complete(session, video: video, audio: audio, replaced: replaced)
        }
        switch joined {
        case .orphan:
            channel.close()   // its session was dropped or cancelled meanwhile
        case .partial(let replaced):
            replaced?.close()
        case .complete(let session, let video, let audio, let replaced):
            replaced?.close()
            let link = Link(sessionToken: session.token, realtime: session.realtime, video: video, audio: audio,
                            transport: transport(session.realtime.stream))
            onLink(AcceptedLink(link: link, peer: session.peer, secret: session.secret, paired: session.paired))
        }
    }

    private func dropWaiting(_ channel: MessageChannel) {
        let dropped = state.withLock { s -> Bool in
            let before = s.waiting.count
            s.waiting.removeAll { $0.channel === channel }
            return s.waiting.count != before
        }
        guard dropped else { return }
        log.error("closing a video/audio connection whose realtime never came")
        channel.close()
    }

    private func dropIncomplete(_ token: [UInt8]) {
        let dropped = state.withLock { s -> Session? in
            guard let i = s.pending.firstIndex(where: { $0.token == token }) else { return nil }
            s.finish(token)
            return s.pending.remove(at: i)
        }
        guard let dropped else { return }
        log.error("dropping a session: its video and audio didn't follow realtime within \(Self.helloTimeout) s")
        dropped.channels.forEach { $0.close() }
    }
}

// MARK: - Client side (USB)

/// The client's single loopback listener (§7.2): a `LinkAcceptor` fed by a `TCPListener`, with
/// `TCP_NODELAY` on every accepted socket (§7.1). `peerID` ("host", the Mac last paired over USB) is
/// the first candidate, every other stored account (`mac:<hostId>`) the next ones. With
/// `acceptsPairing`, a pairing stores the secret under `peerID` and, when the Mac sent a canonical host
/// id, under `mac:<hostId>` too.
public final class ClientLinkListener: Sendable {
    public static let helloTimeout = LinkAcceptor.helloTimeout

    public let port: UInt16
    private let listener: TCPListener
    private let acceptor: LinkAcceptor

    /// - Parameters:
    ///   - port: nil: `LainProtocol.usbPort`; 0 picks an ephemeral port (tests).
    ///   - acceptsPairing: accept a zero-HMAC hello plus `Pair` (true for the USB listener: the cable
    ///     and "Trust This Computer" are the authorization, D13).
    public convenience init(port: UInt16? = nil, secrets: some SecretStore,
                            peerID: String = PairingAccounts.usbHost, acceptsPairing: Bool,
                            onLink: @escaping @Sendable (Link) -> Void) throws {
        try self.init(port: port, secrets: secrets, peerID: peerID, acceptsPairing: acceptsPairing,
                      onReject: { _ in }, onLink: { onLink($0.link) })
    }

    /// With the details of each accepted link (which account matched, whether it paired) and of each
    /// refused connection (`LinkAcceptor`'s `onReject`: `versionMismatch` means the Mac runs another lain).
    public init(port: UInt16? = nil, secrets: some SecretStore,
                peerID: String = PairingAccounts.usbHost, acceptsPairing: Bool,
                onReject: @escaping @Sendable (any Error) -> Void,
                onLink: @escaping @Sendable (AcceptedLink) -> Void) throws {
        let pairing: LinkAcceptor.Pairing = acceptsPairing
            ? .accept(peer: peerID, store: { pair in try ClientLinkListener.storePairing(pair, as: peerID, in: secrets) })
            : .refuse
        let acceptor = LinkAcceptor(secrets: secrets, primaryAccount: peerID, pairing: pairing, label: "lain.client",
                                    onReject: onReject, onLink: onLink)
        self.acceptor = acceptor
        let queue = DispatchQueue(label: "lain.client.listener", qos: .userInitiated)
        listener = try TCPListener(port: port ?? LainProtocol.usbPort, queue: queue) { socket in
            socket.setNoDelay()
            acceptor.accept(socket)
        }
        self.port = listener.port
    }

    public func cancel() {
        listener.cancel()
        acceptor.cancel()
    }

    /// USB pairing stores the Mac's secret for USB and, given a canonical host id, for Wi-Fi together, so
    /// a cable pull can't leave a stale Wi-Fi secret behind (§7.7 D29).
    static func storePairing(_ pair: Pair, as peerID: String, in secrets: some SecretStore) throws {
        try secrets.setSecret(pair.secret, for: peerID)
        if PairingAccounts.isCanonicalHostId(pair.hostId) {
            try secrets.setSecret(pair.secret, for: PairingAccounts.mac(pair.hostId))
        } else if !pair.hostId.isEmpty {
            Telemetry.logger("link").error("Pair carried a malformed host id; stored for USB only")
        }
    }
}
