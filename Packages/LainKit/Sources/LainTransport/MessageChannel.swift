import Dispatch
import LainTelemetry
import Synchronization

/// Framed messages over a `ByteStream` (§7.4). Incoming messages go to the current handler on the
/// channel's serial queue; while no handler is set they are buffered, so a handshake can read one
/// message at a time without losing what follows.
///
/// Bytes that don't parse close the channel. A frame in another major version is reported as the close
/// error, `TransportError.versionMismatch(remote:)`, so a one-sided update says why instead of just
/// dropping the link (§7.5).
public final class MessageChannel: Sendable {
    public let stream: any ByteStream
    public let queue: DispatchQueue
    private let sequence = Atomic<UInt32>(0)
    private let answersVersionMismatch: Bool

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
    }
    private let state = Mutex(State())

    /// - Parameter answeringVersionMismatch: an acceptor's channel (§7.7 D29): a first frame in another
    ///   major version is answered with `Error(versionMismatch)` framed in that version, which the peer
    ///   can parse, before the channel closes.
    public init(stream: any ByteStream, label: String, answeringVersionMismatch: Bool = false) {
        self.stream = stream
        answersVersionMismatch = answeringVersionMismatch
        queue = DispatchQueue(label: label, qos: .userInteractive)
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

    /// Frames and queues a message. Safe from any thread.
    public func send(_ message: Message, flags: HeaderFlags? = nil) {
        let seq = sequence.add(1, ordering: .relaxed).oldValue
        stream.write(MessageCodec.encode(message, sequence: seq, timestampNs: MonotonicClock.now(), flags: flags))
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
            let why = ErrorMessage(code: .versionMismatch, message: "lain here speaks protocol v\(LainProtocol.majorVersion)")
            stream.write(MessageCodec.encode(.error(why), sequence: sequence.add(1, ordering: .relaxed).oldValue,
                                             timestampNs: MonotonicClock.now(), version: remote))
        }
        stream.close()   // after the answer: close sends what is queued first
    }

    /// Runs on `queue`: hands buffered messages to the handler.
    private func drain() {
        while true {
            let next = state.withLock { s -> (Envelope, @Sendable (Envelope) -> Void)? in
                guard !s.pending.isEmpty else { return nil }
                switch s.handler {
                case .none: return nil
                case .once(let h):
                    s.handler = .none
                    return (s.pending.removeFirst(), h)
                case .always(let h):
                    return (s.pending.removeFirst(), h)
                }
            }
            guard let (env, handler) = next else { return }
            handler(env)
        }
    }

    private func closed(_ error: (any Error)?) {
        drain()
        let (handler, reported) = state.withLock { s -> ((@Sendable ((any Error)?) -> Void)?, (any Error)?) in
            var reported = error
            if case .versionMismatch(let remote)? = s.failure { reported = TransportError.versionMismatch(remote: remote) }
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
