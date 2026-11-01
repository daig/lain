/// Adaptive bitrate (M6b): steers the encoder's target to what the link delivers, from the frame acks alone
/// (no protocol change). Pure: the pipeline feeds it every `FrameAck` (round trip and size) and applies
/// `target` to the encoder.
///
/// - **Queueing** is the median of the latest round trips over the best one seen in the last 10 s. A median
///   over several frames, so one frame caught in a link stall (AWDL's ~270 ms pause once a second) isn't
///   taken for congestion, while frames that keep arriving late are.
/// - **Down**, quickly: queueing above `congestedMs` lowers the target to 90% of the measured delivery rate
///   (or by `decrease` if too few acks to measure), at most every `decreaseIntervalNs`, never below `floor`.
///   Both need the link busy (`isBusy`: several frames held back lately, and a real delivery rate), so a
///   quiet link's stalls and tiny frames never lower it. With some queueing (above `clearMs`), a link delivering under
///   90% of the target is saturated too: the host's gate (two frames in flight) holds frames back before the
///   queue grows, costing frame rate, so the target drops to 90% of the delivery rate. Fluidity first:
///   smaller frames rather than fewer. Without held-back frames a low delivery rate only means there was
///   little to send.
/// - **Up**, slowly: queueing below `clearMs` for `increaseIntervalNs` while the link is actually busy
///   (delivering at least half the target) raises it by `increase`, up to `ceiling`. An idle link teaches
///   nothing, so the target stays where the last busy period left it.
public struct BitrateController: Sendable {
    public struct Config: Sendable, Equatable {
        public var floor = 6_000_000
        public var ceiling = 60_000_000
        public var congestedMs = 30.0
        public var clearMs = 10.0
        public var decrease = 0.8
        public var increase = 1.1
        public var decreaseIntervalNs: UInt64 = 250_000_000
        public var increaseIntervalNs: UInt64 = 500_000_000
        /// The round trips the median is taken over (and how old they may be).
        public var recentSamples = 8
        public var recentWindowNs: UInt64 = 500_000_000
        public var deliveryWindowNs: UInt64 = 1_000_000_000
        public var minRttWindowNs: UInt64 = 10_000_000_000
        /// The link is busy (the target may come down) when the gate held back at least `busyHeldBack` frames
        /// in the last `heldBackWindowNs` and it delivered at least `busyDeliveryBps`. At rest a link stall
        /// holds back one frame, and tiny frames deliver almost nothing: neither says anything about capacity.
        public var heldBackWindowNs: UInt64 = 500_000_000
        public var busyHeldBack = 3
        public var busyDeliveryBps = 3_000_000
        public init() {}
    }

    public let config: Config
    /// Bits per second for the encoder.
    public private(set) var target: Int

    /// (ack time, round trip) of the latest acks, oldest first.
    private var recent: [(at: UInt64, rttNs: UInt64)] = []
    /// (ack time, bytes) within the delivery window.
    private var delivered: [(at: UInt64, bytes: Int)] = []
    /// Per-second minima of the round trip, for the windowed best.
    private var minima: [(second: UInt64, rttNs: UInt64)] = []
    private var lastChangeNs: UInt64?
    /// When the gate held frames back, within `heldBackWindowNs`.
    private var heldBackAt: [UInt64] = []
    private var clearSinceNs: UInt64?

    public init(config: Config = Config(), start: Int) {
        self.config = config
        target = min(max(start, config.floor), config.ceiling)
        recent.reserveCapacity(config.recentSamples + 1)
    }

    /// The best round trip of the last `minRttWindowNs` (ns), if any.
    public var minRttNs: UInt64? { minima.map(\.rttNs).min() }

    /// The median recent round trip above the best (ms), if there are enough samples.
    public func queueingMs(at now: UInt64) -> Double? {
        let fresh = recent.filter { now &- $0.at <= config.recentWindowNs }.map(\.rttNs).sorted()
        guard fresh.count >= 3, let best = minRttNs else { return nil }
        return Double(fresh[fresh.count / 2] &- min(best, fresh[fresh.count / 2])) / 1e6
    }

    /// Bits per second acknowledged over the delivery window, if it holds enough acks to say.
    public func deliveryBps(at now: UInt64) -> Int? {
        let window = delivered.filter { now &- $0.at <= config.deliveryWindowNs }
        guard window.count >= 5, let first = window.first else { return nil }
        let span = max(now &- first.at, config.deliveryWindowNs / 2)
        return Int(Double(window.reduce(0) { $0 + $1.bytes }) * 8 / (Double(span) / 1e9))
    }

    /// The host's gate held a frame back (two already in flight): there's more to send than the link takes.
    public mutating func heldBack(at now: UInt64) {
        heldBackAt.append(now)
        heldBackAt.removeAll { now &- $0 > config.heldBackWindowNs }
    }

    /// More to send than the link takes, and the link really carrying it.
    public func isBusy(at now: UInt64) -> Bool {
        heldBackAt.filter { now &- $0 <= config.heldBackWindowNs }.count >= config.busyHeldBack
            && (deliveryBps(at: now) ?? 0) >= config.busyDeliveryBps
    }

    /// One `FrameAck`: the frame's size and its send → ack round trip, acknowledged at `now`. Returns the new
    /// target when it changed.
    @discardableResult
    public mutating func acked(bytes: Int, rttNs: UInt64, at now: UInt64) -> Int? {
        recent.append((now, rttNs))
        if recent.count > config.recentSamples { recent.removeFirst(recent.count - config.recentSamples) }
        delivered.append((now, bytes))
        delivered.removeAll { now &- $0.at > config.deliveryWindowNs }
        let second = now / 1_000_000_000
        if let last = minima.last, last.second == second {
            minima[minima.count - 1].rttNs = min(last.rttNs, rttNs)
        } else {
            minima.append((second, rttNs))
        }
        minima.removeAll { (second &- $0.second) * 1_000_000_000 > config.minRttWindowNs }
        return decide(at: now)
    }

    private mutating func decide(at now: UInt64) -> Int? {
        guard let queueing = queueingMs(at: now) else { return nil }
        let since = lastChangeNs.map { now &- $0 } ?? .max
        if queueing > config.congestedMs {
            clearSinceNs = nil
            guard since >= config.decreaseIntervalNs, isBusy(at: now) else { return nil }
            let byDelivery = deliveryBps(at: now).map { Int(Double($0) * 0.9) }
            let lowered = min(Int(Double(target) * config.decrease), byDelivery ?? .max)
            return set(max(config.floor, min(lowered, target)), at: now)
        }
        guard queueing < config.clearMs else {
            clearSinceNs = nil
            guard since >= config.decreaseIntervalNs, isBusy(at: now),
                  let delivery = deliveryBps(at: now), Double(delivery) < Double(target) * 0.9 else { return nil }
            return set(max(config.floor, Int(Double(delivery) * 0.9)), at: now)
        }
        let clearSince = clearSinceNs ?? now
        clearSinceNs = clearSince
        guard now &- clearSince >= config.increaseIntervalNs, since >= config.increaseIntervalNs,
              let delivery = deliveryBps(at: now), delivery * 2 >= target else { return nil }
        return set(min(config.ceiling, Int(Double(target) * config.increase)), at: now)
    }

    private mutating func set(_ new: Int, at now: UInt64) -> Int? {
        guard new != target else { return nil }
        target = new
        lastChangeNs = now
        clearSinceNs = nil
        return new
    }
}
