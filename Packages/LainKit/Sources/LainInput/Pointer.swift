import Darwin
import LainProtocol

/// A macOS-like pointer acceleration curve over GCMouse deltas (§6.3). Tunable; the
/// constants are placeholders until they're tuned side by side with a real Mac trackpad (M2).
public struct AccelerationCurve: Sendable, Equatable {
    /// Points per count at low speed.
    public var sensitivity: Double = 0.75
    /// 0 = linear. Scales how quickly gain rises above `threshold`.
    public var acceleration: Double = 1.0
    /// Speed (counts/s) where acceleration starts.
    public var threshold: Double = 400
    public var exponent: Double = 0.8
    public var maxGain: Double = 5

    public init() {}

    public init(sensitivity: Double, acceleration: Double, threshold: Double = 400, exponent: Double = 0.8,
                maxGain: Double = 5) {
        self.sensitivity = sensitivity
        self.acceleration = acceleration
        self.threshold = threshold
        self.exponent = exponent
        self.maxGain = maxGain
    }

    /// Gain multiplier (≥ 1) for a speed in counts per second.
    public func gain(speed: Double) -> Double {
        guard acceleration > 0, speed > threshold else { return 1 }
        let x = (speed - threshold) / threshold
        return min(maxGain, 1 + acceleration * pow(x, exponent))
    }
}

/// The client-authoritative cursor (§6.3, invariant 1): applies the curve to raw deltas, clamps to
/// the Mac display (points), and produces `PointerMove`s.
public struct PointerTracker: Sendable {
    public var curve: AccelerationCurve
    /// Mac display size in points (`HelloAck.displayPoint*`).
    public private(set) var width: Double
    public private(set) var height: Double
    public private(set) var x: Double
    public private(set) var y: Double
    private var lastEventNs: UInt64?

    /// Nominal GCMouse interval (120 Hz), used after idle.
    static let nominalIntervalNs: UInt64 = 8_333_333
    static let minIntervalNs: UInt64 = 4_166_666
    static let maxIntervalNs: UInt64 = 33_333_333

    public init(width: Double, height: Double, curve: AccelerationCurve = AccelerationCurve()) {
        self.curve = curve
        self.width = width
        self.height = height
        x = width / 2
        y = height / 2
    }

    /// The largest reachable coordinate: the hotspot can sit on the last point column/row.
    public var maxX: Double { max(0, width - 1) }
    public var maxY: Double { max(0, height - 1) }

    public mutating func resize(width: Double, height: Double) {
        self.width = width
        self.height = height
        clamp()
    }

    /// `CursorWarp` from the Mac overwrites the position.
    public mutating func warp(x: Double, y: Double) {
        self.x = x
        self.y = y
        clamp()
    }

    /// Applies one GCMouse delta (y up-positive). Deltas were integers on iPadOS 26.7 and are
    /// fractional on 27 (§13). Returns nil for zero deltas, which iPadOS sends while fingers rest.
    public mutating func move(dx: Double, dy: Double, at timeNs: UInt64, buttons: UInt8) -> PointerMove? {
        guard dx != 0 || dy != 0 else { return nil }
        // GCMouse reports every ~8.3 ms while moving, so after a pause the first delta covers about one
        // frame of motion, not the whole pause.
        var interval = Self.nominalIntervalNs
        if let last = lastEventNs, timeNs > last, timeNs - last <= Self.maxIntervalNs {
            interval = max(timeNs - last, Self.minIntervalNs)
        }
        lastEventNs = timeNs
        let counts = (dx * dx + dy * dy).squareRoot()
        let speed = counts / (Double(interval) / 1e9)
        let scale = curve.sensitivity * curve.gain(speed: speed)
        let mx = dx * scale
        let my = -dy * scale   // GCMouse y is up-positive; the Mac's is down-positive
        x += mx
        y += my
        clamp()
        return PointerMove(x: x, y: y, dx: Float(mx), dy: Float(my), buttons: buttons)
    }

    private mutating func clamp() {
        x = min(max(x, 0), maxX)
        y = min(max(y, 0), maxY)
    }
}

/// Click counting with the Mac's double-click interval (§5.5): a press continues the sequence if it
/// is the same button, within the interval of the previous press, and within `maxDistance` points.
public struct ClickCounter: Sendable {
    public var intervalNs: UInt64
    public var maxDistance: Double
    private var last: (button: MouseButton, timeNs: UInt64, x: Double, y: Double, count: UInt8)?

    public init(intervalMs: UInt32 = 500, maxDistance: Double = 4) {
        intervalNs = UInt64(intervalMs) * 1_000_000
        self.maxDistance = maxDistance
    }

    /// The click count for a button-down.
    public mutating func down(_ button: MouseButton, x: Double, y: Double, at timeNs: UInt64) -> UInt8 {
        var count: UInt8 = 1
        if let l = last, l.button == button, timeNs >= l.timeNs, timeNs - l.timeNs <= intervalNs,
           ((x - l.x) * (x - l.x) + (y - l.y) * (y - l.y)).squareRoot() <= maxDistance {
            count = l.count == .max ? l.count : l.count + 1
        }
        last = (button, timeNs, x, y, count)
        return count
    }

    /// The count to report on the matching button-up.
    public func upCount(_ button: MouseButton) -> UInt8 {
        guard let l = last, l.button == button else { return 1 }
        return l.count
    }

    public mutating func reset() { last = nil }
}

/// Buttons held on the Mac, for `ReleaseAll` (invariant 4) and `PointerMove.buttons`.
public struct HeldButtons: Sendable, Equatable {
    public private(set) var mask: UInt8 = 0

    public init() {}

    /// Returns false for a duplicate down or an orphan up (drop the event).
    public mutating func set(_ button: MouseButton, down: Bool) -> Bool {
        let bit: UInt8 = 1 << button.rawValue
        if down {
            guard mask & bit == 0 else { return false }
            mask |= bit
        } else {
            guard mask & bit != 0 else { return false }
            mask &= ~bit
        }
        return true
    }

    /// Button-ups for everything held, at the given position.
    public mutating func releaseAll(x: Double, y: Double, modifiers: ModifierFlags = []) -> [PointerButton] {
        let ups = MouseButton.allCases.filter { mask & (1 << $0.rawValue) != 0 }.map {
            PointerButton(button: $0, isDown: false, clickCount: 1, x: x, y: y, modifiers: modifiers)
        }
        mask = 0
        return ups
    }
}
