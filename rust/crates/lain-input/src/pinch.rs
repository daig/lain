//! Pinch → zoom steps. Swift: `PinchZoomMapper`.

/// Turns the client's `Gesture(magnify)` values into zoom steps. Swift: `PinchZoomMapper`, ported as is.
///
/// The client sends scale deltas (the change in `UIPinchGestureRecognizer.scale` since the previous event), so
/// the gesture's cumulative scale is 1 + Σ deltas. Each time that scale crosses another factor of `threshold`
/// (up or down) relative to the last step, one zoom step is emitted. Steps are counted from the last emitted
/// step, so reversing direction needs a full factor before zooming back (natural hysteresis).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PinchZoomMapper {
    threshold: f64,
    scale: f64,
    anchor: f64,
}

impl PinchZoomMapper {
    /// Swift: `PinchZoomMapper.defaultThreshold`.
    pub const DEFAULT_THRESHOLD: f64 = 1.25;

    /// # Panics
    /// If `threshold` isn't above 1 (Swift: a precondition).
    pub fn new(threshold: f64) -> Self {
        assert!(threshold > 1.0, "a pinch threshold must be above 1, not {threshold}");
        Self { threshold, scale: 1.0, anchor: 1.0 }
    }

    pub fn threshold(&self) -> f64 {
        self.threshold
    }

    /// The gesture's cumulative scale (1 at the start of each gesture).
    pub fn scale(&self) -> f64 {
        self.scale
    }

    /// The scale at which the last step fired.
    pub fn anchor(&self) -> f64 {
        self.anchor
    }

    /// Adds one scale delta. Returns the zoom steps it triggers: positive zooms in, negative zooms out, 0 is
    /// none. A non-finite delta is ignored. Allocation-free (realtime path).
    pub fn add(&mut self, delta: f64) -> i32 {
        if !delta.is_finite() {
            return 0;
        }
        self.scale = (self.scale + delta).max(0.01);
        let mut steps = 0;
        while self.scale >= self.anchor * self.threshold {
            self.anchor *= self.threshold;
            steps += 1;
        }
        while self.scale <= self.anchor / self.threshold {
            self.anchor /= self.threshold;
            steps -= 1;
        }
        steps
    }

    /// Gesture end or cancel: the next gesture starts from 1.
    pub fn reset(&mut self) {
        self.scale = 1.0;
        self.anchor = 1.0;
    }
}

impl Default for PinchZoomMapper {
    fn default() -> Self {
        Self::new(Self::DEFAULT_THRESHOLD)
    }
}

/// Swift: `PinchZoomMapperTests` (`HostInputTests.swift`), every test.
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zooms_in_once_each_factor_crossed() {
        let mut m = PinchZoomMapper::new(1.25);
        assert_eq!(m.add(0.1), 0); // 1.10
        assert_eq!(m.add(0.1), 0); // 1.20
        assert_eq!(m.add(0.06), 1); // 1.26 ≥ 1.25
        assert_eq!(m.anchor(), 1.25);
        assert_eq!(m.add(0.25), 0); // 1.51 < 1.5625
        assert_eq!(m.add(0.06), 1); // 1.57 ≥ 1.5625
    }

    #[test]
    fn zooms_out_below_the_inverse_factor() {
        let mut m = PinchZoomMapper::new(1.25);
        assert_eq!(m.add(-0.1), 0); // 0.90
        assert_eq!(m.add(-0.11), -1); // 0.79 ≤ 0.8
        assert_eq!(m.add(-0.14), 0); // 0.65 > 0.64
        assert_eq!(m.add(-0.02), -1); // 0.63 ≤ 0.64
    }

    #[test]
    fn one_big_delta_can_cross_several_factors() {
        let mut m = PinchZoomMapper::new(1.25);
        assert_eq!(m.add(1.0), 3); // 2.0: 1.25, 1.5625, 1.953
        let mut n = PinchZoomMapper::new(1.25);
        assert_eq!(n.add(-0.5), -3); // 0.5: 0.8, 0.64, 0.512
    }

    #[test]
    fn reversing_needs_a_full_factor_from_the_last_step() {
        let mut m = PinchZoomMapper::new(1.25);
        assert_eq!(m.add(0.3), 1); // 1.30, anchor 1.25
        assert_eq!(m.add(-0.25), 0); // 1.05 > 1.0
        assert_eq!(m.add(-0.06), -1); // 0.99 ≤ 1.0
        assert_eq!(m.anchor(), 1.0);
    }

    #[test]
    fn reset_starts_the_next_gesture_from_one() {
        let mut m = PinchZoomMapper::new(1.25);
        m.add(0.2);
        m.reset();
        assert!(m.scale() == 1.0 && m.anchor() == 1.0);
        assert_eq!(m.add(0.2), 0); // would have fired without the reset (1.4)
    }

    #[test]
    fn ignores_non_finite_deltas() {
        let mut m = PinchZoomMapper::default();
        assert_eq!(m.add(f64::NAN), 0);
        assert_eq!(m.add(f64::INFINITY), 0);
        assert_eq!(m.scale(), 1.0);
    }

    #[test]
    fn the_scale_never_reaches_zero() {
        let mut m = PinchZoomMapper::default();
        let steps = m.add(-5.0);
        assert_eq!(m.scale(), 0.01);
        assert!(steps < 0);
        assert_eq!(m.add(-1.0), 0);
    }

    #[test]
    #[should_panic(expected = "above 1")]
    fn a_threshold_of_one_is_refused() {
        PinchZoomMapper::new(1.0);
    }
}
