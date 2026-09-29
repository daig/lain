/// Statistics for the benches' reports (§13), pure functions of their samples: nearest-rank
/// percentiles, the S9 latency histogram, stalls between frame sends and acks, per-second throughput.
public enum BenchStats {
    /// The nearest-rank percentile of ascending `sorted` (p in 0...1), as `RollingPercentiles` takes
    /// it; nil when empty.
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        // The epsilon keeps floating-point error in p × n from pushing an exact rank up by one.
        let rank = Int((p * Double(sorted.count) - 1e-9).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    /// p50, p90, p99, p99.9 and the maximum of a set of samples; nil when there are none.
    public struct Distribution: Sendable, Equatable {
        public var count: Int
        public var p50: Double?
        public var p90: Double?
        public var p99: Double?
        public var p999: Double?
        public var max: Double?

        public init(_ samples: [Double]) {
            let sorted = samples.sorted()
            count = sorted.count
            p50 = BenchStats.percentile(sorted, 0.5)
            p90 = BenchStats.percentile(sorted, 0.9)
            p99 = BenchStats.percentile(sorted, 0.99)
            p999 = BenchStats.percentile(sorted, 0.999)
            max = sorted.last
        }
    }

    /// The S9 latency histogram: log2 buckets ≤1, ≤2, ≤4 … ≤128 ms, then >128 ms.
    public struct Histogram: Sendable, Equatable {
        public static let edgesMs: [Double] = [1, 2, 4, 8, 16, 32, 64, 128]
        /// One count per bucket (`edgesMs.count + 1`).
        public var counts: [Int]

        public init(_ samplesMs: [Double]) {
            var counts = [Int](repeating: 0, count: Self.edgesMs.count + 1)
            for ms in samplesMs { counts[Self.bucket(ms)] += 1 }
            self.counts = counts
        }

        /// The first bucket whose edge `ms` doesn't exceed; past the last edge, the overflow bucket.
        public static func bucket(_ ms: Double) -> Int {
            edgesMs.firstIndex { ms <= $0 } ?? edgesMs.count
        }

        public static var labels: [String] {
            edgesMs.map { "≤\(Int($0))" } + [">\(Int(edgesMs[edgesMs.count - 1]))"]
        }
    }

    /// The intervals during which at least one frame was in flight and no ack came (§7.3): each ends
    /// at an ack, or at `endNs` for frames still unacknowledged then, and starts at the previous ack
    /// or at the send that found the window empty. Acks retire frames in order, as on one TCP stream.
    public static func stallGaps(_ frames: [(sentNs: UInt64, ackNs: UInt64?)], endNs: UInt64) -> [UInt64] {
        var events: [(atNs: UInt64, isAck: Bool)] = []
        events.reserveCapacity(frames.count * 2)
        for frame in frames {
            if let ack = frame.ackNs, ack <= frame.sentNs { continue }   // never in flight
            events.append((frame.sentNs, false))
            if let ack = frame.ackNs { events.append((ack, true)) }
        }
        // At one instant an ack goes first: it frees the window a send then fills.
        events.sort { $0.atNs != $1.atNs ? $0.atNs < $1.atNs : $0.isAck && !$1.isAck }
        var gaps: [UInt64] = []
        var inFlight = 0
        var since: UInt64 = 0
        for event in events {
            if event.isAck {
                if inFlight > 0 {
                    gaps.append(event.atNs - since)
                    inFlight -= 1
                }
                since = event.atNs
            } else {
                if inFlight == 0 { since = event.atNs }
                inFlight += 1
            }
        }
        if inFlight > 0, endNs > since { gaps.append(endNs - since) }
        return gaps
    }

    /// Stall counts over the S9 thresholds (a frame in flight with no ack for longer than 50, 100 and
    /// 250 ms) and the longest.
    public struct Stalls: Sendable, Equatable {
        public static let thresholdsMs: [Double] = [50, 100, 250]
        /// Gaps longer than each threshold.
        public var counts: [Int]
        public var longestMs: Double

        public init(gapsMs: [Double]) {
            counts = Self.thresholdsMs.map { threshold in gapsMs.filter { $0 > threshold }.count }
            longestMs = gapsMs.max() ?? 0
        }
    }

    /// MB/s (10⁶ bytes) acknowledged in each full second from `startNs`. A partial last second before
    /// `endNs` is left out, and so are acks outside the seconds counted.
    public static func perSecondMBps(_ acks: [(atNs: UInt64, bytes: Int)], startNs: UInt64, endNs: UInt64) -> [Double] {
        guard endNs > startNs else { return [] }
        let seconds = Int((endNs - startNs) / 1_000_000_000)
        var bytes = [Int](repeating: 0, count: seconds)
        for ack in acks where ack.atNs >= startNs {
            let second = Int((ack.atNs - startNs) / 1_000_000_000)
            if second < seconds { bytes[second] += ack.bytes }
        }
        return bytes.map { Double($0) / 1e6 }
    }
}
