/// Maps the peer's CLOCK_UPTIME_RAW onto ours so every per-frame timestamp lands on one timeline (§9).
///
/// Each ping/pong exchange gives t0 (local send), t1 (remote receive), t2 (remote send) and t3
/// (local receive). Its offset estimate is ((t1 − t0) + (t2 − t3)) / 2, exact when the two legs take
/// equal time; the error is at most half the round trip minus the remote hold time. So the estimator
/// keeps a sliding window and trusts the sample with the smallest round trip.
public struct ClockOffsetEstimator: Sendable {
    public struct Sample: Sendable, Equatable {
        /// remote − local, in ns.
        public var offsetNs: Int64
        /// Round trip excluding the remote's hold time, in ns.
        public var rttNs: Int64
    }

    public let windowSize: Int
    private var window: [Sample] = []
    private var next = 0

    public init(windowSize: Int = 32) {
        precondition(windowSize > 0)
        self.windowSize = windowSize
        window.reserveCapacity(windowSize)
    }

    /// Adds one exchange; returns its sample, or nil if the timestamps are inconsistent.
    @discardableResult
    public mutating func add(t0: UInt64, t1: UInt64, t2: UInt64, t3: UInt64) -> Sample? {
        guard t3 >= t0, t2 >= t1 else { return nil }
        let rtt = Int64(t3 - t0) - Int64(t2 - t1)
        guard rtt >= 0 else { return nil }
        let offset = (Int64(bitPattern: t1 &- t0) + Int64(bitPattern: t2 &- t3)) / 2
        let s = Sample(offsetNs: offset, rttNs: rtt)
        if window.count < windowSize { window.append(s) } else { window[next] = s }
        next = (next + 1) % windowSize
        return s
    }

    /// The minimum-RTT sample in the window.
    public var best: Sample? { window.min { $0.rttNs < $1.rttNs } }

    /// remote − local, in ns, from the minimum-RTT sample.
    public var offsetNs: Int64? { best?.offsetNs }

    public var sampleCount: Int { window.count }

    /// Converts a remote timestamp to the local clock.
    public func toLocal(remoteNs: UInt64) -> UInt64? {
        guard let o = offsetNs else { return nil }
        return UInt64(bitPattern: Int64(bitPattern: remoteNs) &- o)
    }
}
