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
///   quiet link's stalls and tiny frames never lower it. A busy link delivering under 90% of the target is
///   saturated too (whatever the queueing: with big frames, each one's transfer time is in the best round trip): the host's gate (two frames in flight) holds frames back before the
///   queue grows, costing frame rate, so the target drops to 90% of the delivery rate. Fluidity first:
///   smaller frames rather than fewer. Without held-back frames a low delivery rate only means there was
///   little to send.
/// - **Up**, slowly: queueing below `clearMs` on a link that isn't busy, for `increaseIntervalNs`, raises it by
///   `increase`, up to `ceiling` (see `decide`). Frames held back while the acks have stopped (a radio pause)
///   don't make it busy (`heldBack`).
/// - Nothing comes down during `warmupNs` after the first ack, or while the link isn't busy, and one step
///   down is at most to `maxStep` of the target.
public struct BitrateController: Sendable {
    public struct Config: Sendable, Equatable {
        public var floor = 6_000_000
        public var ceiling = 60_000_000
        public var congestedMs = 30.0
        public var clearMs = 10.0
        /// A decrease without a delivery rate to go by, and the smallest step down.
        public var decrease = 0.9
        /// The largest step down: never below this share of the target in one step.
        public var maxStep = 0.7
        /// No decrease this soon after the first ack (the first keyframe and its burst).
        public var warmupNs: UInt64 = 1_000_000_000
        public var increase = 1.15
        public var decreaseIntervalNs: UInt64 = 250_000_000
        public var increaseIntervalNs: UInt64 = 500_000_000
        /// The round trips the median is taken over (and how old they may be).
        public var recentSamples = 8
        public var recentWindowNs: UInt64 = 500_000_000
        public var deliveryWindowNs: UInt64 = 500_000_000
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
    private var firstAckNs: UInt64?
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

    /// Bits per second acknowledged over the delivery window, if it holds enough acks to say. Measured over
    /// the time the link was delivering: a silence between acks longer than three times the window's median
    /// gap is a stall and counts as one median gap, so a link stall (no acks for ~270 ms) doesn't read as a
    /// slow link, while a slow link's steady acks still do.
    public func deliveryBps(at now: UInt64) -> Int? {
        let window = delivered.filter { now &- $0.at <= config.deliveryWindowNs }
        guard window.count >= 5 else { return nil }
        let gaps = (1..<window.count).map { window[$0].at &- window[$0 - 1].at }
        let median = gaps.sorted()[gaps.count / 2]
        let span = gaps.reduce(UInt64(0)) { $0 + ($1 > 3 * median ? median : $1) }
        guard span > 0 else { return nil }
        let bytes = window.dropFirst().reduce(0) { $0 + $1.bytes }
        return Int(Double(bytes) * 8 / (Double(span) / 1e9))
    }

    /// The host's gate held a frame back (two already in flight): there's more to send than the link takes,
    /// unless the acks have stopped. A frame held back in a silence longer than twice the median gap between
    /// acks is a link stall's (a radio pause), which says nothing about capacity, and isn't counted; a slow
    /// link keeps acking while it holds frames back. (Seen from the Linux host, 2026-11-01: the iPad's radio
    /// pauses, ~100 ms several times a second, held a fast link's target at the floor.)
    public mutating func heldBack(at now: UInt64) {
        if let last = delivered.last?.at, let gap = medianAckGap(at: now), now &- last > 2 * gap { return }
        heldBackAt.append(now)
        heldBackAt.removeAll { now &- $0 > config.heldBackWindowNs }
    }

    /// The median gap between the acks of the delivery window, if it holds at least three.
    func medianAckGap(at now: UInt64) -> UInt64? {
        let times = delivered.filter { now &- $0.at <= config.deliveryWindowNs }.map(\.at)
        guard times.count >= 3 else { return nil }
        let gaps = (1..<times.count).map { times[$0] &- times[$0 - 1] }.sorted()
        return gaps[gaps.count / 2]
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
        if firstAckNs == nil { firstAckNs = now }
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
        let warm = firstAckNs.map { now &- $0 >= config.warmupNs } ?? false
        let delivery = deliveryBps(at: now)
        // Saturated: frames held back while the link delivers under 90% of the target. Not from the round
        // trips alone: when every frame is big, each one's transfer time is in the best round trip too, so
        // a link carrying a fifth of the target can show no queueing at all.
        let busy = isBusy(at: now)
        let saturated = busy && (delivery.map { Double($0) < Double(target) * 0.9 } ?? false)
        if saturated || (busy && queueing > config.congestedMs) {
            clearSinceNs = nil
            // Down only once warm: the session's first keyframe burst isn't the link's capacity.
            guard warm, since >= config.decreaseIntervalNs else { return nil }
            // To 90% of what the link delivered, but at most `maxStep` lower per step (a delivery rate
            // diluted by an idle moment mustn't crash it).
            let byDelivery = delivery.map { Int(Double($0) * 0.9) } ?? Int(Double(target) * config.decrease)
            let lowered = max(byDelivery, Int(Double(target) * config.maxStep))
            return set(max(config.floor, min(lowered, Int(Double(target) * config.decrease))), at: now)
        }
        // Up while nothing queues and the link isn't busy (probing, as congestion control does): a quiet link
        // at a low target makes small frames that never fill it, so waiting for it to be busy would trap the
        // target low. A target too high comes down once frames back up. Not "nothing held back lately": a
        // radio pause's first frame or two are held while their acks are still due.
        guard queueing < config.clearMs, !busy else {
            clearSinceNs = nil
            return nil
        }
        let clearSince = clearSinceNs ?? now
        clearSinceNs = clearSince
        guard now &- clearSince >= config.increaseIntervalNs, since >= config.increaseIntervalNs else { return nil }
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
