import Synchronization

/// Invariant 2 in one place (§5.2, §7.3): captured frames go into a **latest-wins slot**, and a frame
/// enters the encoder only when the encoder is idle (one frame in, one out) and fewer than
/// `maxInFlight` encoded frames are unacknowledged. Frames are dropped before encoding, never after.
public final class FrameGate<Frame: Sendable>: Sendable {
    public struct Stats: Sendable, Equatable {
        public var offered = 0
        public var encoded = 0
        /// Replaced in the slot by a newer frame before they could be encoded.
        public var droppedBeforeEncode = 0
        public var peakInFlight = 0
    }

    private struct State {
        var slot: Frame?
        var encoderBusy = false
        var window: FrameAckWindowLite
        var stats = Stats()
    }
    private let state: Mutex<State>
    private let encode: @Sendable (Frame) -> Void

    /// - Parameter encode: submits a frame to the encoder; called outside the lock on whichever thread
    ///   freed capacity (capture, encoder output or ack). Must not block.
    public init(maxInFlight: Int = 2, encode: @escaping @Sendable (Frame) -> Void) {
        state = Mutex(State(window: FrameAckWindowLite(maxInFlight: maxInFlight)))
        self.encode = encode
    }

    public var stats: Stats { state.withLock { $0.stats } }
    public var inFlight: Int { state.withLock { $0.window.count } }
    public var slotOccupied: Bool { state.withLock { $0.slot != nil } }

    /// A newly captured frame (capture thread).
    public func offer(_ frame: Frame) {
        let now = state.withLock { s -> Frame? in
            s.stats.offered += 1
            if !s.encoderBusy && s.window.canSend {
                s.encoderBusy = true
                s.stats.encoded += 1
                return frame
            }
            if s.slot != nil { s.stats.droppedBeforeEncode += 1 }
            s.slot = frame
            return nil
        }
        if let now { encode(now) }
    }

    /// The encoder emitted the frame and it was sent (encoder thread).
    public func sent(frameId: UInt32) {
        pump { s in
            s.encoderBusy = false
            s.window.sent(frameId)
            s.stats.peakInFlight = max(s.stats.peakInFlight, s.window.count)
        }
    }

    /// The encoder produced nothing for the frame (dropped or failed).
    public func encodeFailed() { pump { $0.encoderBusy = false } }

    /// A `FrameAck` arrived (video connection queue).
    public func acked(frameId: UInt32) { pump { $0.window.acked(frameId) } }

    /// Forget in-flight frames (reconnect).
    public func reset() { pump { $0.window.reset() } }

    private func pump(_ update: (inout State) -> Void) {
        let next = state.withLock { s -> Frame? in
            update(&s)
            guard !s.encoderBusy, s.window.canSend, let f = s.slot else { return nil }
            s.slot = nil
            s.encoderBusy = true
            s.stats.encoded += 1
            return f
        }
        if let next { encode(next) }
    }
}

/// In-flight frame ids (LainTransport's FrameAckWindow also tracks bytes and timing for stats).
struct FrameAckWindowLite: Sendable {
    let maxInFlight: Int
    private var ids: [UInt32] = []
    init(maxInFlight: Int) {
        precondition(maxInFlight > 0)
        self.maxInFlight = maxInFlight
        ids.reserveCapacity(maxInFlight + 1)
    }
    var count: Int { ids.count }
    var canSend: Bool { ids.count < maxInFlight }
    mutating func sent(_ id: UInt32) { ids.append(id) }
    /// Acks arrive in order; an ack retires older frames too.
    mutating func acked(_ id: UInt32) { if let i = ids.firstIndex(of: id) { ids.removeFirst(i + 1) } }
    mutating func reset() { ids.removeAll(keepingCapacity: true) }
}

/// Idle refinement (§5.3): after ~150 ms without a new frame, re-submit the last frame (up to twice)
/// so static text sharpens.
public struct IdleRefiner: Sendable {
    public var idleNs: UInt64
    public var maxRefinements: Int
    private var lastNewFrameNs: UInt64?
    private var done = 0

    public init(idleMs: UInt64 = 150, maxRefinements: Int = 2) {
        idleNs = idleMs * 1_000_000
        self.maxRefinements = maxRefinements
    }

    public mutating func newFrame(at timeNs: UInt64) {
        lastNewFrameNs = timeNs
        done = 0
    }

    /// True when the last frame should be re-submitted now; each refinement waits another `idleNs`.
    public mutating func shouldRefine(at timeNs: UInt64) -> Bool {
        guard let last = lastNewFrameNs, done < maxRefinements, timeNs >= last,
              timeNs - last >= idleNs * UInt64(done + 1) else { return false }
        done += 1
        return true
    }
}
