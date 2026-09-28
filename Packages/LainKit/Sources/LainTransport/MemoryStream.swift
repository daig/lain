import Dispatch
import Synchronization

/// An in-memory `ByteStream` pair for loopback tests and the pipeline test (§12.2). Writes are
/// delivered to the peer's queue in order; bytes written before the peer starts are buffered.
public final class MemoryStream: ByteStream {
    private struct State {
        weak var peer: MemoryStream?
        var queue: DispatchQueue?
        var onBytes: (@Sendable ([UInt8]) -> Void)?
        var onClose: (@Sendable ((any Error)?) -> Void)?
        var pending: [[UInt8]] = []
        var closed = false
        var bytesDelivered = 0
    }
    private let state = Mutex(State())

    private init() {}

    public static func pair() -> (MemoryStream, MemoryStream) {
        let a = MemoryStream(), b = MemoryStream()
        a.state.withLock { $0.peer = b }
        b.state.withLock { $0.peer = a }
        return (a, b)
    }

    /// Total bytes delivered to this end's handler.
    public var bytesDelivered: Int { state.withLock { $0.bytesDelivered } }

    public func start(queue: DispatchQueue, onBytes: @escaping @Sendable ([UInt8]) -> Void,
                      onClose: @escaping @Sendable ((any Error)?) -> Void) {
        let (pending, closed) = state.withLock { s in
            s.queue = queue
            s.onBytes = onBytes
            s.onClose = onClose
            defer { s.pending = [] }
            return (s.pending, s.closed)
        }
        queue.async { [self] in
            for chunk in pending { deliverNow(chunk, onBytes) }
            if closed { onClose(nil) }
        }
    }

    public func write(_ bytes: [UInt8]) {
        guard let peer = state.withLock({ $0.closed ? nil : $0.peer }) else { return }
        peer.receive(bytes)
    }

    public func close() {
        let peer = state.withLock { s -> MemoryStream? in
            guard !s.closed else { return nil }
            return s.peer
        }
        markClosed()
        peer?.markClosed()
    }

    private func receive(_ bytes: [UInt8]) {
        let target = state.withLock { s -> (DispatchQueue, @Sendable ([UInt8]) -> Void)? in
            guard !s.closed else { return nil }
            guard let q = s.queue, let h = s.onBytes else { s.pending.append(bytes); return nil }
            return (q, h)
        }
        guard let (queue, handler) = target else { return }
        queue.async { [self] in deliverNow(bytes, handler) }
    }

    private func deliverNow(_ bytes: [UInt8], _ handler: @Sendable ([UInt8]) -> Void) {
        state.withLock { $0.bytesDelivered += bytes.count }
        handler(bytes)
    }

    private func markClosed() {
        let target = state.withLock { s -> (DispatchQueue, @Sendable ((any Error)?) -> Void)? in
            guard !s.closed else { return nil }
            s.closed = true
            guard let q = s.queue, let h = s.onClose else { return nil }
            return (q, h)
        }
        if let (queue, handler) = target { queue.async { handler(nil) } }
    }
}
