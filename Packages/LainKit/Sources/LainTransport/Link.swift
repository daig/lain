import Dispatch
import LainTelemetry
import Synchronization

/// The three authenticated connections of one session (§7.1).
public struct Link: Sendable {
    public let sessionToken: [UInt8]
    public let realtime: MessageChannel
    public let video: MessageChannel
    public let audio: MessageChannel

    public var channels: [MessageChannel] { [realtime, video, audio] }

    public func close() { channels.forEach { $0.close() } }
}

/// Opens byte streams to the client: usbmuxd `Connect` over USB, plain loopback TCP in tests.
public protocol StreamDialer: Sendable {
    func dial() async throws -> any ByteStream
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

    public init(client: USBMuxClient = USBMuxClient(), deviceID: Int, port: UInt16 = LainProtocol.usbPort) {
        self.client = client
        self.deviceID = deviceID
        self.port = port
    }

    public func dial() async throws -> any ByteStream {
        SocketStream(fd: try await client.connect(deviceID: deviceID, port: port), label: "lain.usbmux")
    }
}
#endif

// MARK: - Host side

/// The host dials, authenticates and (over USB) pairs (§7.5 handshake steps 1–2, §7.6).
public enum HostLink {
    public static let handshakeTimeout = 5.0
    /// Video writes block on a small kernel buffer instead of queueing below the app (§7.3).
    public static let videoSendBuffer = 128 * 1024

    /// Opens realtime, video and audio, sends `ChannelHello` on each, and waits for the client's
    /// `Hello`. With no stored secret, or when the client rejects ours and `allowPairing` is set (USB),
    /// it pairs: a zero-HMAC hello plus `Pair` on realtime. The new secret is stored once `Hello` arrives.
    /// `paired` says whether this session paired (true) or authenticated with the stored secret.
    public static func open(dialer: some StreamDialer, secrets: some SecretStore, peerID: String,
                            allowPairing: Bool) async throws -> (link: Link, hello: Hello, paired: Bool) {
        let stored = try secrets.secret(for: peerID)
        if stored == nil && !allowPairing { throw TransportError.noSecret }
        do {
            return try await attempt(dialer: dialer, secrets: secrets, peerID: peerID, secret: stored)
        } catch TransportError.authenticationFailed where stored != nil && allowPairing {
            Telemetry.logger("link").notice("client rejected stored secret; re-pairing over USB")
            return try await attempt(dialer: dialer, secrets: secrets, peerID: peerID, secret: nil)
        }
    }

    private static func attempt(dialer: some StreamDialer, secrets: some SecretStore, peerID: String,
                                secret stored: [UInt8]?) async throws -> (link: Link, hello: Hello, paired: Bool) {
        let token = ChannelAuth.randomBytes(ChannelHello.tokenSize)
        let secret = stored ?? ChannelAuth.randomBytes(Pair.secretSize)
        var opened: [MessageChannel] = []
        do {
            func connect(_ kind: ConnectionKind) async throws -> MessageChannel {
                let stream = try await dialer.dial()
                if kind == .video, let socket = stream as? SocketStream { socket.setSendBufferSize(videoSendBuffer) }
                let channel = MessageChannel(stream: stream, label: "lain.host.\(kind)")
                opened.append(channel)
                channel.start()
                if kind == .realtime, stored == nil {
                    channel.send(.channelHello(ChannelAuth.hello(kind: kind, token: token, secret: nil)))
                    channel.send(.pair(Pair(secret: secret)))
                } else {
                    channel.send(.channelHello(ChannelAuth.hello(kind: kind, token: token, secret: secret)))
                }
                return channel
            }
            let realtime = try await connect(.realtime)
            let video = try await connect(.video)
            let audio = try await connect(.audio)
            let first = try await realtime.next(timeoutSeconds: handshakeTimeout)
            switch first.message {
            case .hello(let hello):
                if stored == nil { try secrets.setSecret(secret, for: peerID) }
                return (Link(sessionToken: token, realtime: realtime, video: video, audio: audio), hello, stored == nil)
            case .error(let e) where e.code == .authenticationFailed:
                throw TransportError.authenticationFailed
            case .error(let e) where e.code == .versionMismatch:
                throw TransportError.versionMismatch(remote: 0)
            default:
                throw TransportError.unexpectedMessage("\(first.message.type)")
            }
        } catch {
            opened.forEach { $0.close() }
            throw error
        }
    }
}

// MARK: - Client side

/// The client's single loopback listener (§7.2). Every accepted connection must open with a valid
/// `ChannelHello`. The realtime connection establishes the session (and pairs, when asked and
/// allowed); video and audio join it by session token. `onLink` fires once all three are in.
public final class ClientLinkListener: Sendable {
    public static let helloTimeout = 3.0

    public let port: UInt16
    private let listener: TCPListener
    private let control: DispatchQueue
    private let secrets: any SecretStore
    private let peerID: String
    private let acceptsPairing: Bool
    private let onLink: @Sendable (Link) -> Void
    private let sessions = Mutex<Sessions>(Sessions())

    private struct Session {
        var token: [UInt8]
        var secret: [UInt8]
        var realtime: MessageChannel
        var video: MessageChannel?
        var audio: MessageChannel?
        var delivered = false
    }

    private struct Sessions {
        var current: Session?
        /// Video/audio connections that arrived before their realtime connection.
        var waiting: [(hello: ChannelHello, channel: MessageChannel)] = []
    }

    /// - Parameters:
    ///   - acceptsPairing: accept a zero-HMAC hello plus `Pair` (true for the USB listener: the cable
    ///     and "Trust This Computer" are the authorization, D13).
    public init(port: UInt16 = LainProtocol.usbPort, secrets: some SecretStore, peerID: String = "host",
                acceptsPairing: Bool, onLink: @escaping @Sendable (Link) -> Void) throws {
        let control = DispatchQueue(label: "lain.client.listener", qos: .userInitiated)
        self.control = control
        self.secrets = secrets
        self.peerID = peerID
        self.acceptsPairing = acceptsPairing
        self.onLink = onLink
        let box = WeakBox<ClientLinkListener>()
        listener = try TCPListener(port: port, queue: control) { stream in box.value?.accepted(stream) }
        self.port = listener.port
        box.value = self
    }

    public func cancel() {
        listener.cancel()
        let s = sessions.withLock { s in
            defer { s = Sessions() }
            return s
        }
        s.current.map { [$0.realtime, $0.video, $0.audio].compactMap { $0 }.forEach { $0.close() } }
        s.waiting.forEach { $0.channel.close() }
    }

    private func accepted(_ stream: SocketStream) {
        stream.setNoDelay()
        let channel = MessageChannel(stream: stream, label: "lain.client.conn")
        channel.start()
        let settled = Mutex(false)
        channel.receiveOnce { [weak self] env in
            settled.withLock { $0 = true }
            self?.control.async { self?.handleFirst(env, on: channel) }
        }
        control.asyncAfter(deadline: .now() + Self.helloTimeout) {
            if !settled.withLock({ $0 }) { channel.close() }
        }
    }

    private func reject(_ channel: MessageChannel, _ code: ErrorMessage.Code, _ why: String) {
        Telemetry.logger("link").error("rejecting connection: \(why, privacy: .public)")
        channel.send(.error(ErrorMessage(code: code, message: why)))
        channel.close()
    }

    /// Runs on `control`.
    private func handleFirst(_ env: Envelope, on channel: MessageChannel) {
        guard case .channelHello(let hello) = env.message else {
            return reject(channel, .authenticationFailed, "first message was \(env.message.type)")
        }
        guard hello.protocolVersion == LainProtocol.majorVersion else {
            return reject(channel, .versionMismatch, "protocol v\(hello.protocolVersion)")
        }
        switch hello.connectionKind {
        case .realtime where hello.hmac == ChannelAuth.pairingMAC:
            guard acceptsPairing else { return reject(channel, .authenticationFailed, "pairing not accepted here") }
            channel.receiveOnce { [weak self] env in self?.control.async { self?.handlePair(env, hello, channel) } }
        case .realtime:
            guard let secret = try? secrets.secret(for: peerID), ChannelAuth.isValid(hello, secret: secret) else {
                return reject(channel, .authenticationFailed, "bad HMAC")
            }
            establish(hello, secret: secret, realtime: channel)
        case .video, .audio:
            let current = sessions.withLock { $0.current }
            if let current, current.token == hello.sessionToken {
                join(hello, channel, secret: current.secret)
            } else {
                sessions.withLock { $0.waiting.append((hello, channel)) }
                control.asyncAfter(deadline: .now() + Self.helloTimeout) { [weak self] in
                    self?.dropWaiting(channel)
                }
            }
        }
    }

    private func handlePair(_ env: Envelope, _ hello: ChannelHello, _ channel: MessageChannel) {
        guard case .pair(let pair) = env.message else {
            return reject(channel, .authenticationFailed, "expected Pair, got \(env.message.type)")
        }
        do {
            try secrets.setSecret(pair.secret, for: peerID)
        } catch {
            return reject(channel, .internal, "could not store pairing secret")
        }
        Telemetry.logger("link").notice("paired over USB")
        establish(hello, secret: pair.secret, realtime: channel)
    }

    private func establish(_ hello: ChannelHello, secret: [UInt8], realtime: MessageChannel) {
        let (old, waiting) = sessions.withLock { s in
            let old = s.current
            s.current = Session(token: hello.sessionToken, secret: secret, realtime: realtime)
            let waiting = s.waiting.filter { $0.hello.sessionToken == hello.sessionToken }
            s.waiting.removeAll { $0.hello.sessionToken == hello.sessionToken }
            return (old, waiting)
        }
        if let old { [old.realtime, old.video, old.audio].compactMap { $0 }.forEach { $0.close() } }
        for w in waiting { join(w.hello, w.channel, secret: secret) }
    }

    private func join(_ hello: ChannelHello, _ channel: MessageChannel, secret: [UInt8]) {
        guard ChannelAuth.isValid(hello, secret: secret) else { return reject(channel, .authenticationFailed, "bad HMAC") }
        let link = sessions.withLock { s -> Link? in
            guard var cur = s.current, cur.token == hello.sessionToken else { return nil }
            if hello.connectionKind == .video { cur.video?.close(); cur.video = channel }
            if hello.connectionKind == .audio { cur.audio?.close(); cur.audio = channel }
            var link: Link?
            if !cur.delivered, let v = cur.video, let a = cur.audio {
                cur.delivered = true
                link = Link(sessionToken: cur.token, realtime: cur.realtime, video: v, audio: a)
            }
            s.current = cur
            return link
        }
        if let link { onLink(link) }
    }

    private func dropWaiting(_ channel: MessageChannel) {
        let dropped = sessions.withLock { s in
            let before = s.waiting.count
            s.waiting.removeAll { $0.channel === channel }
            return s.waiting.count != before
        }
        if dropped { channel.close() }
    }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    private let lock = Mutex<Void>(())
    private weak var _value: T?
    var value: T? {
        get { lock.withLock { _ in _value } }
        set { lock.withLock { _ in _value = newValue } }
    }
}
