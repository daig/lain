//! Cursor warps (Swift: `LainHostCore/Session/CursorWarpDetector.swift`).

use lain_platform::PointF;

/// Detects cursor moves the client didn't command (§5.4 warp): the desktop's own mouse, or an app warping
/// the pointer. The session reports every injected input with [`note_input`](Self::note_input), and samples
/// the real cursor ([`DisplayBackend::cursor_location`](lain_platform::DisplayBackend::cursor_location), global
/// logical pixels, nothing clamped) at about 60 Hz with [`sample`](Self::sample). A warp is reported when the
/// real location differs from the last commanded one by more than `tolerance` and no input has been injected
/// for `quiet_ns`, so in-flight injected moves aren't mistaken for warps.
///
/// Before any position is known (a new session) the first quiet sample is reported, which gives the client
/// the desktop's cursor position at startup (§7.5 handshake step 4). Swift: `CursorWarpDetector`.
///
/// On GNOME the platform knows the pointer only while it is on lain's display (L8), so warps elsewhere go
/// unreported: a documented difference from the Mac host, made by the platform, not here.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CursorWarpDetector {
    pub tolerance: f64,
    pub quiet_ns: u64,
    expected: Option<PointF>,
    last_input_ns: Option<u64>,
}

impl Default for CursorWarpDetector {
    fn default() -> Self {
        Self::new(Self::DEFAULT_TOLERANCE, Self::DEFAULT_QUIET_NS)
    }
}

impl CursorWarpDetector {
    pub const DEFAULT_TOLERANCE: f64 = 1.0;
    pub const DEFAULT_QUIET_NS: u64 = 100_000_000;

    pub fn new(tolerance: f64, quiet_ns: u64) -> Self {
        Self { tolerance, quiet_ns, expected: None, last_input_ns: None }
    }

    /// Where the cursor should be: the last commanded or reported position.
    pub fn expected(&self) -> Option<PointF> {
        self.expected
    }

    pub fn last_input_ns(&self) -> Option<u64> {
        self.last_input_ns
    }

    /// Any injected input at `now_ns`; `pointer` is the commanded position for pointer events.
    pub fn note_input(&mut self, pointer: Option<PointF>, now_ns: u64) {
        self.last_input_ns = Some(now_ns);
        if let Some(pointer) = pointer {
            self.expected = Some(pointer);
        }
    }

    /// The real cursor location at `now_ns`. Returns the position to send as `CursorWarp`, if any.
    pub fn sample(&mut self, actual: PointF, now_ns: u64) -> Option<PointF> {
        if let Some(last) = self.last_input_ns
            && now_ns < last.wrapping_add(self.quiet_ns)
        {
            return None;
        }
        if let Some(expected) = self.expected
            && actual.distance(expected) <= self.tolerance
        {
            return None;
        }
        self.expected = Some(actual);
        Some(actual)
    }

    /// The client got a new `DisplayLayout`: a warp it received before it may have been clamped to the old
    /// arrangement, so the next quiet sample reports the cursor again (after the layout).
    pub fn resync(&mut self) {
        self.expected = None;
    }

    /// A new session: nothing is known about the client's cursor.
    pub fn reset(&mut self) {
        self.expected = None;
        self.last_input_ns = None;
    }
}

#[cfg(test)]
mod tests {
    //! Swift: `HostInputTests.swift`, `CursorWarpDetectorTests`, case by case.
    use super::*;

    const MS: u64 = 1_000_000;

    fn p(x: f64, y: f64) -> PointF {
        PointF::new(x, y)
    }

    #[test]
    fn first_quiet_sample_reports_the_starting_position() {
        let mut d = CursorWarpDetector::default();
        assert_eq!(d.sample(p(5.0, 6.0), 1_000 * MS), Some(p(5.0, 6.0)));
        assert_eq!(d.sample(p(5.0, 6.0), 1_016 * MS), None);
    }

    #[test]
    fn no_warp_while_input_is_recent() {
        let mut d = CursorWarpDetector::default();
        d.note_input(Some(p(100.0, 100.0)), 1_000 * MS);
        assert_eq!(d.sample(p(300.0, 300.0), 1_050 * MS), None);
        assert_eq!(d.sample(p(300.0, 300.0), 1_099 * MS), None);
        // A key press also counts as input.
        d.note_input(None, 1_090 * MS);
        assert_eq!(d.sample(p(300.0, 300.0), 1_150 * MS), None);
    }

    #[test]
    fn warp_after_quiet_period_when_moved() {
        let mut d = CursorWarpDetector::default();
        d.note_input(Some(p(100.0, 100.0)), 1_000 * MS);
        assert_eq!(d.sample(p(100.0, 100.0), 1_100 * MS), None);
        assert_eq!(d.sample(p(140.0, 90.0), 1_200 * MS), Some(p(140.0, 90.0)));
        // Reported once; the reported position is now the expected one.
        assert_eq!(d.sample(p(140.0, 90.0), 1_216 * MS), None);
        assert_eq!(d.expected(), Some(p(140.0, 90.0)));
    }

    #[test]
    fn no_warp_for_sub_point_jitter() {
        let mut d = CursorWarpDetector::default();
        d.note_input(Some(p(100.0, 100.0)), 1_000 * MS);
        assert_eq!(d.sample(p(100.7, 99.4), 1_200 * MS), None);
        assert_eq!(d.sample(p(101.0, 100.0), 1_300 * MS), None);
        assert_eq!(d.sample(p(101.1, 100.0), 1_400 * MS), Some(p(101.1, 100.0)));
    }

    #[test]
    fn reset_forgets_the_session() {
        let mut d = CursorWarpDetector::default();
        d.note_input(Some(p(1.0, 1.0)), 1_000 * MS);
        d.reset();
        assert_eq!((d.expected(), d.last_input_ns()), (None, None));
        assert_eq!(d.sample(p(1.0, 1.0), 1_001 * MS), Some(p(1.0, 1.0)));
    }

    /// Not in Swift's suite (its session tests cover it): a new layout makes the next quiet sample report again.
    #[test]
    fn resync_reports_the_cursor_again() {
        let mut d = CursorWarpDetector::default();
        assert!(d.sample(p(5.0, 5.0), 0).is_some());
        d.resync();
        assert_eq!(d.sample(p(5.0, 5.0), 16 * MS), Some(p(5.0, 5.0)));
    }
}
