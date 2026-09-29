import Darwin
import LainProtocol

/// Scroll momentum (§6.4). iPadOS delivers no momentum after a trackpad fling, and `.ended` often
/// reports zero velocity, so the fling velocity comes from the last few `.changed` samples. Momentum
/// then decays exponentially and is emitted as began → changed… → ended scroll events. Any new touch
/// cancels it. Constants are placeholders until S11 tunes them.
public struct MomentumSynthesizer: Sendable {
    public struct Config: Sendable, Equatable {
        /// Decay time constant. UIScrollView's normal deceleration (0.998 per ms) is ≈ 0.5 s.
        public var timeConstant: Double = 0.5
        /// Only samples this close to the lift count toward the fling velocity.
        public var sampleWindowNs: UInt64 = 60_000_000
        /// No momentum below this lift speed (points/s).
        public var minimumStartSpeed: Double = 150
        /// Momentum ends when speed falls below this (points/s).
        public var stopSpeed: Double = 12
        public init() {}
    }

    public var config: Config
    private var samples: [(dx: Double, dy: Double, dtNs: UInt64, timeNs: UInt64)] = []
    private var lastChangeNs: UInt64?
    private var velocity: (x: Double, y: Double)?
    private var lastTickNs: UInt64 = 0
    private var started = false

    public init(config: Config = Config()) {
        self.config = config
        samples.reserveCapacity(16)
    }

    public var isActive: Bool { velocity != nil }

    /// One 120 Hz frame.
    static let frameNs: UInt64 = 8_333_333

    /// A new touch (pan began). Returns a momentum-ended event if momentum was running.
    public mutating func touchBegan(at timeNs: UInt64) -> Scroll? {
        samples.removeAll(keepingCapacity: true)
        lastChangeNs = timeNs
        return cancel()
    }

    /// A `.changed` sample: the scroll delta in points since the previous one.
    public mutating func changed(dx: Double, dy: Double, at timeNs: UInt64) {
        let dt = lastChangeNs.map { timeNs > $0 ? timeNs - $0 : 0 } ?? Self.frameNs
        lastChangeNs = timeNs
        // The first sample after touch-down is the translation the pan carried at `.began`, built up over
        // at least one frame but stamped right after `touchBegan`: count it as one frame, not ~0.
        let minimum: UInt64 = samples.isEmpty ? Self.frameNs : 1_000_000
        samples.append((dx, dy, max(dt, minimum), timeNs))
        if samples.count > 16 { samples.removeFirst(samples.count - 16) }
    }

    /// Fingers lifted. Starts momentum if the recent samples were fast enough; returns the fling
    /// velocity (points/s) or nil.
    @discardableResult
    public mutating func ended(at timeNs: UInt64) -> (x: Double, y: Double)? {
        defer { samples.removeAll(keepingCapacity: true); lastChangeNs = nil }
        let recent = samples.filter { timeNs >= $0.timeNs && timeNs - $0.timeNs <= config.sampleWindowNs }
        guard !recent.isEmpty else { return nil }
        let span = Double(recent.reduce(0) { $0 + $1.dtNs }) / 1e9
        let v = (x: recent.reduce(0) { $0 + $1.dx } / span, y: recent.reduce(0) { $0 + $1.dy } / span)
        guard (v.x * v.x + v.y * v.y).squareRoot() >= config.minimumStartSpeed else { return nil }
        velocity = v
        lastTickNs = timeNs
        started = false
        return v
    }

    /// Advances momentum to `timeNs` (call on each display-link tick). Returns the next event, if any.
    public mutating func tick(at timeNs: UInt64) -> Scroll? {
        guard var v = velocity, timeNs > lastTickNs else { return nil }
        let dt = Double(timeNs - lastTickNs) / 1e9
        lastTickNs = timeNs
        let decay = exp(-dt / config.timeConstant)
        // Distance travelled during dt under exponential decay: v·τ·(1 − e^(−dt/τ)).
        let k = config.timeConstant * (1 - decay)
        let delta = (x: v.x * k, y: v.y * k)
        v = (v.x * decay, v.y * decay)
        if (v.x * v.x + v.y * v.y).squareRoot() < config.stopSpeed {
            velocity = nil
            defer { started = false }
            return started ? Scroll(dx: 0, dy: 0, phase: .none, momentumPhase: .ended) : nil
        }
        velocity = v
        let phase: MomentumPhase = started ? .changed : .began
        started = true
        return Scroll(dx: Float(delta.x), dy: Float(delta.y), phase: .none, momentumPhase: phase)
    }

    /// Stops momentum; returns a momentum-ended event if it was running.
    public mutating func cancel() -> Scroll? {
        guard velocity != nil else { return nil }
        velocity = nil
        started = false
        return Scroll(dx: 0, dy: 0, phase: .none, momentumPhase: .ended)
    }
}
