/// Pinch → Cmd +/− (§5.5, gestures v1). The client sends `Gesture(.magnify)` values as scale deltas
/// (the change in `UIPinchGestureRecognizer.scale` since the previous event), so the gesture's
/// cumulative scale is 1 + Σ deltas. Each time that scale crosses another factor of `threshold`
/// (up or down) relative to the last step, one zoom step is emitted. Steps are counted from the last
/// emitted step, so reversing direction needs a full factor before zooming back (natural hysteresis).
public struct PinchZoomMapper: Sendable {
    public static let defaultThreshold = 1.25

    public let threshold: Double
    /// The gesture's cumulative scale (1 at the start of each gesture).
    public private(set) var scale = 1.0
    /// The scale at which the last step fired.
    public private(set) var anchor = 1.0

    public init(threshold: Double = PinchZoomMapper.defaultThreshold) {
        precondition(threshold > 1)
        self.threshold = threshold
    }

    /// Adds one scale delta. Returns the zoom steps it triggers: positive = zoom in (Cmd =),
    /// negative = zoom out (Cmd −), 0 = none. Allocation-free (realtime path).
    public mutating func add(_ delta: Double) -> Int {
        guard delta.isFinite else { return 0 }
        scale = max(scale + delta, 0.01)
        var steps = 0
        while scale >= anchor * threshold {
            anchor *= threshold
            steps += 1
        }
        while scale <= anchor / threshold {
            anchor /= threshold
            steps -= 1
        }
        return steps
    }

    /// Gesture end or cancel: the next gesture starts from 1.
    public mutating func reset() {
        scale = 1
        anchor = 1
    }
}
