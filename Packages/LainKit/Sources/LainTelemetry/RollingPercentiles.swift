/// Fixed-capacity window of recent values with p50/p95 on demand (HUD, §6.6).
/// `record` never allocates, so real-time paths can call it; `percentile` sorts a copy and is
/// for the control plane.
public struct RollingPercentiles: Sendable {
    public let capacity: Int
    private var values: [Double]
    private var count = 0
    private var next = 0

    public init(capacity: Int = 240) {
        precondition(capacity > 0)
        self.capacity = capacity
        values = Array(repeating: 0, count: capacity)
    }

    public mutating func record(_ v: Double) {
        values[next] = v
        next = next + 1 == capacity ? 0 : next + 1
        if count < capacity { count += 1 }
    }

    public var sampleCount: Int { count }

    /// Nearest-rank percentile, p in 0...1; nil when empty.
    public func percentile(_ p: Double) -> Double? {
        guard count > 0 else { return nil }
        let sorted = values[0..<count].sorted()
        let rank = Int((p * Double(count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), count - 1)]
    }

    public var p50: Double? { percentile(0.5) }
    public var p95: Double? { percentile(0.95) }

    public mutating func reset() { count = 0; next = 0 }
}
