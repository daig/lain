/// Frame-ack backpressure (§7.3, invariant 2): the host encodes a new frame only while fewer than
/// `maxInFlight` frames are unacknowledged. Socket writability is never the signal.
public struct FrameAckWindow: Sendable {
    public struct Ack: Sendable, Equatable {
        public var frameId: UInt32
        /// Send → ack received, on the host clock.
        public var roundTripNs: UInt64
        public var bytes: Int
    }

    public var maxInFlight: Int
    private var inFlight: [(id: UInt32, bytes: Int, sentNs: UInt64)] = []

    public init(maxInFlight: Int = 2) {
        precondition(maxInFlight > 0)
        self.maxInFlight = maxInFlight
        inFlight.reserveCapacity(8)
    }

    public var inFlightCount: Int { inFlight.count }
    public var canSend: Bool { inFlight.count < maxInFlight }

    public mutating func sent(frameId: UInt32, bytes: Int, at timeNs: UInt64) {
        inFlight.append((frameId, bytes, timeNs))
    }

    /// Records an ack. Acks arrive in order on one TCP stream, so an ack also retires anything older.
    /// Returns nil for an unknown (stale or duplicate) frame.
    public mutating func acked(frameId: UInt32, at timeNs: UInt64) -> Ack? {
        guard let i = inFlight.firstIndex(where: { $0.id == frameId }) else { return nil }
        let f = inFlight[i]
        inFlight.removeFirst(i + 1)
        return Ack(frameId: frameId, roundTripNs: timeNs >= f.sentNs ? timeNs - f.sentNs : 0, bytes: f.bytes)
    }

    /// Forget everything in flight (reconnect, keyframe restart).
    public mutating func reset() { inFlight.removeAll(keepingCapacity: true) }
}
