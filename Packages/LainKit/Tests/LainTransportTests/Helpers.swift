import Dispatch
import LainProtocol
import Synchronization
@testable import LainTransport

/// Collects values from callbacks and lets tests await them.
final class Inbox<T: Sendable>: Sendable {
    private let state = Mutex<(items: [T], waiters: [CheckedContinuation<T?, Never>])>(([], []))

    func put(_ v: T) {
        let waiter = state.withLock { s -> CheckedContinuation<T?, Never>? in
            if s.waiters.isEmpty { s.items.append(v); return nil }
            return s.waiters.removeFirst()
        }
        waiter?.resume(returning: v)
    }

    /// The next value, or nil after `seconds`.
    func next(within seconds: Double = 5) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let ready = state.withLock { s -> T? in
                if !s.items.isEmpty { return s.items.removeFirst() }
                s.waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                let timedOut = state.withLock { s -> CheckedContinuation<T?, Never>? in
                    guard let i = s.waiters.firstIndex(where: { _ in true }) else { return nil }
                    return s.waiters.remove(at: i)
                }
                timedOut?.resume(returning: nil)
            }
        }
    }

    var count: Int { state.withLock { $0.items.count } }
}

/// A secret store whose reads fail on demand and that counts writes (the acceptor's read rules,
/// §7.7 D29: a pairing writes, a re-authentication doesn't).
final class ScriptedSecrets: SecretStore {
    struct Failure: Error {}
    let inner: InMemorySecretStore
    let failsSecretRead: Bool
    let failsListing: Bool
    private let writes = Atomic<Int>(0)

    init(_ initial: [String: [UInt8]] = [:], failsSecretRead: Bool = false, failsListing: Bool = false) {
        inner = InMemorySecretStore(initial)
        self.failsSecretRead = failsSecretRead
        self.failsListing = failsListing
    }

    var writeCount: Int { writes.load(ordering: .relaxed) }

    func secret(for peer: String) throws -> [UInt8]? {
        if failsSecretRead { throw Failure() }
        return inner.secret(for: peer)
    }
    func setSecret(_ secret: [UInt8], for peer: String) {
        writes.add(1, ordering: .relaxed)
        inner.setSecret(secret, for: peer)
    }
    func removeSecret(for peer: String) { inner.removeSecret(for: peer) }
    func allSecrets() throws -> [String: [UInt8]] {
        if failsListing { throw Failure() }
        return inner.allSecrets()
    }
}

/// A `LinkAcceptor` fed by a loopback TCP listener, as the host's Wi-Fi acceptor is fed by its
/// listener: no primary account, no pairing unless asked.
final class AcceptorHarness: Sendable {
    let accepted: Inbox<AcceptedLink>
    let rejected: Inbox<any Error>
    let acceptor: LinkAcceptor
    let listener: TCPListener
    var port: UInt16 { listener.port }

    init(secrets: some SecretStore, primaryAccount: String? = nil, pairing: LinkAcceptor.Pairing = .refuse,
         transport: LinkTransport = .usb) throws {
        let accepted = Inbox<AcceptedLink>(), rejected = Inbox<any Error>()
        self.accepted = accepted
        self.rejected = rejected
        let acceptor = LinkAcceptor(secrets: secrets, primaryAccount: primaryAccount, pairing: pairing, label: "test.acceptor",
                                    transport: { _ in transport }, onReject: { rejected.put($0) }, onLink: { accepted.put($0) })
        self.acceptor = acceptor
        listener = try TCPListener(port: 0, queue: DispatchQueue(label: "test.listener")) { acceptor.accept($0) }
    }

    func cancel() {
        listener.cancel()
        acceptor.cancel()
    }
}

/// The client's USB listener reporting each link in full (`AcceptedLink`) and each refusal; its links
/// answer `Hello` at once, as ClientSession does.
struct AcceptingClient<Store: SecretStore> {
    let listener: ClientLinkListener
    let accepted: Inbox<AcceptedLink>
    let rejected: Inbox<any Error>
    let secrets: Store

    init(secrets: Store, acceptsPairing: Bool = true) throws {
        let accepted = Inbox<AcceptedLink>(), rejected = Inbox<any Error>()
        self.accepted = accepted
        self.rejected = rejected
        self.secrets = secrets
        listener = try ClientLinkListener(port: 0, secrets: secrets, acceptsPairing: acceptsPairing,
                                          onReject: { rejected.put($0) }) { link in
            link.link.realtime.send(.hello(sampleHello))
            accepted.put(link)
        }
    }
}

/// A raw connection to a listener, started, for writing handshakes by hand.
func rawChannel(to port: UInt16, _ label: String = "raw") throws -> MessageChannel {
    let channel = MessageChannel(stream: try TCP.connectLoopback(port: port), label: label)
    channel.start()
    return channel
}

/// Collects a channel's close.
func closeWatch(_ channel: MessageChannel) -> Inbox<Bool> {
    let closed = Inbox<Bool>()
    channel.setCloseHandler { _ in closed.put(true) }
    return closed
}

func transportError(_ error: (any Error)?) -> TransportError? { error as? TransportError }

let sampleHello = Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                        decodeCapabilities: [.hevcMain, .hevcMain44410Hardware], keyboardType: .ansi)

let sampleHelloAck = HelloAck(codec: .hevc, chroma: .yuv444, bitDepth: 10, displayMode: .extend, bitrate: 60_000_000,
                              refreshRate: 120, displayPointWidth: 1376, displayPointHeight: 1032,
                              audioSampleRate: 48_000, audioChannels: 2, audioEncoding: .pcm16LE,
                              doubleClickIntervalMs: 500, keyRepeatDelayMs: 225, keyRepeatIntervalMs: 30,
                              macInputSource: "com.apple.keylayout.Colemak")
