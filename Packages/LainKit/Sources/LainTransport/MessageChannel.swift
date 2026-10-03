import Dispatch
import LainTelemetry
import Synchronization

/// Framed messages over a `ByteStream` (§7.4). Incoming messages go to the current handler on the
/// channel's serial queue; while no handler is set they are buffered, so a handshake can read one
/// message at a time without losing what follows.
///
/// Every channel starts in the handshake layer: it sends and accepts only handshake frames (header
/// version 0xFF) until `setVersion` fixes the version the link negotiated; from then on it writes every
/// message at that version and accepts only frames in it (PROTOCOL-VERSIONING §3.2). A frame in any
/// other version closes the channel.
///
/// Bytes that don't parse close the channel. A frame in a version this build doesn't implement (a
/// legacy peer's) is reported as the close error, `TransportError.versionMismatch(remote:)`, so a
/// one-sided update says why instead of just dropping the link.
public final class MessageChannel: Sendable {
    public let stream: any ByteStream
    public let queue: DispatchQueue
    private let sequence = Atomic<UInt32>(0)
    private let answersVersionMismatch: Bool
    private let log = Telemetry.logger("channel")

    private enum Handler {
        case none
        case once(@Sendable (Envelope) -> Void)
        case always(@Sendable (Envelope) -> Void)
    }

    private struct State {
        var parser = FrameParser()
        var handler: Handler = .none
        var pending: [Envelope] = []
        var onClose: (@Sendable ((any Error)?) -> Void)?
        var closedWith: ((any Error)?)?
        var started = false
        var parsedAny = false
        /// The parse error that is closing the channel (the stream can't be resynchronized).
        var failure: ProtocolError?
        /// The negotiated version; nil while the channel is in the handshake layer.
        var version: UInt8?
        /// A frame in the wrong version that is closing the channel.
        var violation: String?
    }
    private let state = Mutex(State())

    /// - Parameters:
    ///   - answeringVersionMismatch: an acceptor's channel (§7.7 D29): a first frame in a version this build
    ///     doesn't implement (a legacy peer's) is answered with `Error(versionMismatch)` framed in that
    ///     version, which the peer can parse, before the channel closes.
    ///   - version: the session version, for a channel that skips the handshake (tests); nil starts in the
    ///     handshake layer.
    public init(stream: any ByteStream, label: String, answeringVersionMismatch: Bool = false, version: UInt8? = nil) {
        self.stream = stream
        answersVersionMismatch = answeringVersionMismatch
        queue = DispatchQueue(label: label, qos: .userInteractive)
        if let version { state.withLock { $0.version = version } }
    }

    /// The negotiated version; nil while in the handshake layer.
    public var version: UInt8? { state.withLock { $0.version } }

    /// Leaves the handshake layer: from now on messages go out, and must come in, at `version`. Call it
    /// before reading the first session message.
    public func setVersion(_ version: UInt8) {
        state.withLock { $0.version = version }
        queue.async { [self] in drain() }
    }

    /// Starts receiving. Messages are buffered until a handler is set.
    public func start() {
        let first = state.withLock { s in
            defer { s.started = true }
            return !s.started
        }
        guard first else { return }
        stream.start(queue: queue, onBytes: { [weak self] in self?.receive($0) },
                     onClose: { [weak self] in self?.closed($0) })
    }

    /// Delivers all messages (buffered ones first) to `handler`.
    public func setHandler(_ handler: @escaping @Sendable (Envelope) -> Void) { install(.always(handler)) }

    /// Delivers exactly the next message to `handler`, then buffers again.
    public func receiveOnce(_ handler: @escaping @Sendable (Envelope) -> Void) { install(.once(handler)) }

    /// Called once on the channel's queue when the stream closes (immediately if it already has).
    public func setCloseHandler(_ handler: @escaping @Sendable ((any Error)?) -> Void) {
        let closed = state.withLock { s -> ((any Error)?)? in
            s.onClose = handler
            return s.closedWith
        }
        if let closed { queue.async { handler(closed) } }
    }

    /// Frames and queues a message at the channel's version (the handshake's until `setVersion`). Safe
    /// from any thread. A message that doesn't exist at that version isn't sent (false): callers check the
    /// feature first (`Link.supports`), so that is a bug, asserted in Debug builds.
    @discardableResult
    public func send(_ message: Message, flags: HeaderFlags? = nil) -> Bool {
        let version = state.withLock { $0.version } ?? LainProtocol.handshakeVersion
        let seq = sequence.add(1, ordering: .relaxed).oldValue
        switch MessageCodec.lower(message, to: version, sequence: seq, timestampNs: MonotonicClock.now(), flags: flags) {
        case .exact(let bytes), .projected(let bytes, _):
            stream.write(bytes)
            return true
        case .unrepresentable(let why):
            log.fault("not sent: \(why, privacy: .public)")
            assertionFailure("not sent: \(why)")
            return false
        }
    }

    public func close() { stream.close() }

    /// Waits for the next message (handshakes only: replaces the close handler). A close caused by a
    /// frame in another major version throws `versionMismatch`; any other close throws `closed`.
    public func next(timeoutSeconds: Double) async throws(TransportError) -> Envelope {
        let result: Result<Envelope, TransportError> = await withCheckedContinuation { cont in
            let once = OneShot(cont)
            receiveOnce { once.resume(.success($0)) }
            queue.asyncAfter(deadline: .now() + timeoutSeconds) { once.resume(.failure(.timeout)) }
            setCloseHandler { error in
                if let e = error as? TransportError, case .versionMismatch = e { return once.resume(.failure(e)) }
                once.resume(.failure(.closed))
            }
        }
        setCloseHandler { _ in }
        if case .failure = result { state.withLock { $0.handler = .none } }
        return try result.get()
    }

    private func install(_ handler: Handler) {
        state.withLock { $0.handler = handler }
        queue.async { [self] in drain() }
    }

    private func receive(_ bytes: [UInt8]) {
        let failed = state.withLock { s -> (error: ProtocolError, first: Bool)? in
            guard s.failure == nil else { return nil }   // already closing: the rest can't be parsed
            s.parser.append(bytes)
            do throws(ProtocolError) {
                while let env = try s.parser.next() {
                    s.pending.append(env)
                    s.parsedAny = true
                }
                return nil
            } catch {
                s.failure = error
                return (error, !s.parsedAny)
            }
        }
        drain()
        guard let failed else { return }
        if answersVersionMismatch, failed.first, case .versionMismatch(let remote) = failed.error {
            let why = "lain here speaks protocol \(VersionList.supported)"
            stream.write(MessageCodec.legacyVersionMismatch(remote: remote, why: why,
                                                            sequence: sequence.add(1, ordering: .relaxed).oldValue,
                                                            timestampNs: MonotonicClock.now()))
        }
        stream.close()   // after the answer: close sends what is queued first
    }

    /// Runs on `queue`: hands buffered messages to the handler. Each frame's version is checked as it's
    /// handed over, so a version fixed by `setVersion` after the previous frame applies to the next.
    private func drain() {
        enum Next { case deliver(Envelope, @Sendable (Envelope) -> Void), violation(String) }
        while true {
            let next = state.withLock { s -> Next? in
                guard s.violation == nil, let env = s.pending.first else { return nil }
                let handler: @Sendable (Envelope) -> Void
                switch s.handler {
                case .none: return nil
                case .once(let h): handler = h
                case .always(let h): handler = h
                }
                let expected = s.version ?? LainProtocol.handshakeVersion
                guard env.header.version == expected else {
                    let why = "a \(env.header.type) frame in v\(env.header.version) on a channel at "
                        + (s.version.map { "v\($0)" } ?? "the handshake")
                    s.violation = why
                    s.pending.removeAll()
                    return .violation(why)
                }
                if case .once = s.handler { s.handler = .none }
                s.pending.removeFirst()
                return .deliver(env, handler)
            }
            switch next {
            case nil:
                return
            case .deliver(let env, let handler):
                handler(env)
            case .violation(let why):
                log.error("closing: \(why, privacy: .public)")
                stream.close()
                return
            }
        }
    }

    private func closed(_ error: (any Error)?) {
        drain()
        let (handler, reported) = state.withLock { s -> ((@Sendable ((any Error)?) -> Void)?, (any Error)?) in
            var reported = error
            if case .versionMismatch(let remote)? = s.failure { reported = TransportError.versionMismatch(remote: remote) }
            if let violation = s.violation { reported = TransportError.unexpectedMessage(violation) }
            s.closedWith = .some(reported)
            return (s.onClose, reported)
        }
        handler?(reported)
    }
}

/// Resumes a continuation exactly once, whichever event comes first.
final class OneShot<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>
    init(_ c: CheckedContinuation<T, Never>) { continuation = Mutex(c) }
    func resume(_ value: T) {
        continuation.withLock { c in
            c?.resume(returning: value)
            c = nil
        }
    }
}
