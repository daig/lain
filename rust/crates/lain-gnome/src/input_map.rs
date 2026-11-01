//! [`InputAction`]s → Mutter `RemoteDesktop.Session.Notify*` calls (decision L8; spike B §4, §5, §8). Pure, so
//! the coordinate mapping, the scroll flags and the panel-barrier detour are tested without a desktop. Swift's
//! counterpart is the CGEvent injector behind `InputSink`, which posts in global points with no per-monitor
//! streams.

use lain_platform::{InputAction, PointF, RectF, ScrollSource};

/// `NotifyPointerAxis` flags (`org.gnome.Mutter.RemoteDesktop.xml`).
pub const AXIS_FINISH: u32 = 1;
pub const AXIS_WHEEL: u32 = 2;
pub const AXIS_FINGER: u32 = 4;
pub const AXIS_CONTINUOUS: u32 = 8;

/// The axis flag for a scroll source.
pub fn source_flag(source: ScrollSource) -> u32 {
    match source {
        ScrollSource::Wheel => AXIS_WHEEL,
        ScrollSource::Finger => AXIS_FINGER,
        ScrollSource::Continuous => AXIS_CONTINUOUS,
    }
}

/// One call on the input session.
#[derive(Debug, Clone, PartialEq)]
pub enum InputCall {
    /// `NotifyPointerMotionAbsolute(s stream, d x, d y)`: the stream's own pixels from its top-left (for a
    /// `RecordMonitor` stream in logical layout mode, local logical pixels times the monitor's scale).
    MotionAbsolute { stream: String, x: f64, y: f64 },
    /// `NotifyKeyboardKeycode(u keycode, b state)`: an evdev code.
    Key { code: u32, down: bool },
    /// `NotifyPointerButton(i button, b state)`: an evdev button code.
    Button { code: i32, down: bool },
    /// `NotifyPointerAxis(d dx, d dy, u flags)`.
    Axis { dx: f64, dy: f64, flags: u32 },
}

impl InputCall {
    pub fn method(&self) -> &'static str {
        match self {
            InputCall::MotionAbsolute { .. } => "NotifyPointerMotionAbsolute",
            InputCall::Key { .. } => "NotifyKeyboardKeycode",
            InputCall::Button { .. } => "NotifyPointerButton",
            InputCall::Axis { .. } => "NotifyPointerAxis",
        }
    }
}

/// A monitor that input can reach: its global bounds and the path of input's `RecordMonitor` stream of it.
#[derive(Debug, Clone, PartialEq)]
pub struct Target {
    pub bounds: RectF,
    pub stream: String,
    pub primary: bool,
    /// The stream's pixels per global unit: the monitor's scale in logical layout mode, 1 in physical mode.
    /// A `RecordMonitor` stream takes `NotifyPointerMotionAbsolute` in its own (device) pixels and divides them
    /// by the scale whenever stage views are scaled, which is logical layout mode (Mutter 50.1,
    /// `meta_screen_cast_monitor_stream_transform_position`, `meta_backend_is_stage_views_scaled`). Only a
    /// `RecordVirtual` stream adds the coordinates unscaled, which is what spike B measured at scale 2 (review DB1).
    pub scale: f64,
}

/// GNOME Shell's top-panel pointer barrier (spike B, §4): on the primary monitor's right edge, from its top to
/// the panel's height, passing the pointer only in −x. An absolute move in +x whose line crosses it there
/// stops at the edge, and one that starts on the edge in the band sometimes does.
///
/// The detour (untested on the desktop, spike B §4's proposal): such a move goes first straight down to just
/// below the band on its own side, then across below the band, then straight to the target. It is skipped
/// while a button is held, so a drag never passes through a detour point.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Barrier {
    pub detour: bool,
    /// The panel's height in logical pixels. 32 is an estimate (not measured in spike B).
    pub band: f64,
}

impl Default for Barrier {
    fn default() -> Self {
        Self { detour: true, band: 32.0 }
    }
}

/// Maps actions to calls, tracking the pointer it last sent and the buttons held. Every action goes through it,
/// even one that is then dropped for want of a session, so the buttons it tracks stay true.
#[derive(Debug, Default)]
pub struct Mapper {
    targets: Vec<Target>,
    pointer: Option<PointF>,
    held_buttons: Vec<u16>,
    barrier: Barrier,
}

impl Mapper {
    pub fn new(barrier: Barrier) -> Self {
        Self { barrier, ..Self::default() }
    }

    /// The monitors input can reach now.
    pub fn set_targets(&mut self, targets: Vec<Target>) {
        self.targets = targets;
    }

    pub fn targets(&self) -> &[Target] {
        &self.targets
    }

    /// The calls for `action`. `pointer` is where the pointer really is, if known (on lain's display, from
    /// the cursor metadata); otherwise the mapper uses the last position it sent.
    pub fn map(&mut self, action: &InputAction, pointer: Option<PointF>) -> Vec<InputCall> {
        match *action {
            InputAction::Key { code, down } => vec![InputCall::Key { code: u32::from(code), down }],
            InputAction::Button { code, down } => {
                if down {
                    if !self.held_buttons.contains(&code) {
                        self.held_buttons.push(code);
                    }
                } else {
                    self.held_buttons.retain(|c| *c != code);
                }
                vec![InputCall::Button { code: i32::from(code), down }]
            }
            InputAction::Scroll { dx, dy, source } => vec![InputCall::Axis { dx, dy, flags: source_flag(source) }],
            // Mutter drops a delta sent with the finish flag, so the stop carries none; a wheel has no stop.
            InputAction::ScrollStop { source: ScrollSource::Wheel } => vec![],
            InputAction::ScrollStop { source } => {
                vec![InputCall::Axis { dx: 0.0, dy: 0.0, flags: source_flag(source) | AXIS_FINISH }]
            }
            InputAction::MoveTo(target) => self.move_to(target, pointer),
        }
    }

    fn move_to(&mut self, target: PointF, pointer: Option<PointF>) -> Vec<InputCall> {
        let Some((index, to)) = self.resolve(target) else { return vec![] };
        let from = pointer.or(self.pointer);
        let mut calls = Vec::with_capacity(3);
        if let Some(from) = from
            && self.held_buttons.is_empty()
            && let Some(points) = self.detour(from, to)
        {
            for p in points {
                if let Some((i, p)) = self.resolve(p) {
                    calls.push(self.motion(i, p));
                }
            }
        }
        calls.push(self.motion(index, to));
        self.pointer = Some(to);
        calls
    }

    /// The motion to `p` on target `index`: stream pixels from the monitor's top-left ([`Target::scale`]).
    fn motion(&self, index: usize, p: PointF) -> InputCall {
        let t = &self.targets[index];
        let s = if t.scale > 0.0 { t.scale } else { 1.0 };
        InputCall::MotionAbsolute { stream: t.stream.clone(), x: (p.x - t.bounds.x) * s, y: (p.y - t.bounds.y) * s }
    }

    /// The session that held the buttons is gone (Mutter releases everything with its virtual devices), and
    /// the pointer may have moved meanwhile: forget both (review L3).
    pub fn session_ended(&mut self) {
        self.held_buttons.clear();
        self.pointer = None;
    }

    /// A new session replaced the old one, whose stop released any held button.
    pub fn buttons_released(&mut self) {
        self.held_buttons.clear();
    }

    /// The monitor under `p` (half-open), else the nearest one with `p` clamped into it.
    pub fn resolve(&self, p: PointF) -> Option<(usize, PointF)> {
        if let Some(i) = self.targets.iter().position(|t| t.bounds.contains(p)) {
            return Some((i, p));
        }
        self.targets
            .iter()
            .enumerate()
            .map(|(i, t)| (i, clamp_into(&t.bounds, p)))
            .min_by(|a, b| p.distance(a.1).total_cmp(&p.distance(b.1)))
    }

    /// The intermediate points of the barrier detour for a move `from` → `to`, if it needs one.
    pub fn detour(&self, from: PointF, to: PointF) -> Option<[PointF; 2]> {
        if !self.barrier.detour || to.x <= from.x {
            return None;
        }
        let primary = self.targets.iter().find(|t| t.primary)?;
        let edge = primary.bounds.max_x();
        let top = primary.bounds.y;
        let below = top + self.barrier.band;
        // Only where a monitor continues past the edge within the band.
        let beyond = self.targets.iter().any(|t| t.bounds.x == edge && t.bounds.y < below && t.bounds.max_y() > top);
        if !beyond {
            return None;
        }
        let in_band = |y: f64| y >= top && y < below;
        let crosses = from.x < edge && to.x >= edge && {
            let y = from.y + (edge - from.x) * (to.y - from.y) / (to.x - from.x);
            in_band(y)
        };
        // Starting on the edge's column (lain's first logical pixel) inside the band.
        let starts_on = from.x >= edge && from.x < edge + 1.0 && in_band(from.y);
        if !(crosses || starts_on) {
            return None;
        }
        Some([PointF::new(from.x, below), PointF::new(to.x, below)])
    }
}

/// `p` clamped into `r`, just inside its right and bottom edges (which belong to the next rectangle).
pub fn clamp_into(r: &RectF, p: PointF) -> PointF {
    const IN: f64 = 1.0 / 256.0;
    PointF::new(p.x.clamp(r.x, (r.max_x() - IN).max(r.x)), p.y.clamp(r.y, (r.max_y() - IN).max(r.y)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const HDMI: &str = "/org/gnome/Mutter/ScreenCast/Stream/1";
    const LAIN: &str = "/org/gnome/Mutter/ScreenCast/Stream/2";

    /// HDMI-1 at scale 1 and lain's 2752×2064 display at `lain` (1376 wide at scale 2, 2752 at scale 1).
    fn mapper(lain: RectF) -> Mapper {
        let mut m = Mapper::new(Barrier::default());
        m.set_targets(vec![
            Target { bounds: RectF::new(0.0, 0.0, 3840.0, 2160.0), stream: HDMI.into(), primary: true, scale: 1.0 },
            Target { bounds: lain, stream: LAIN.into(), primary: false, scale: 2752.0 / lain.width },
        ]);
        m
    }

    fn motion(stream: &str, x: f64, y: f64) -> InputCall {
        InputCall::MotionAbsolute { stream: stream.into(), x, y }
    }

    /// Review DB1: a `RecordMonitor` stream takes its own pixels, which Mutter divides by the scale.
    #[test]
    fn global_to_stream_pixels_at_scale_two() {
        // lain's display right of HDMI-1 at scale 2: 1376×1032 logical at (3840, 0), a 2752×2064 stream.
        let mut m = mapper(RectF::new(3840.0, 0.0, 1376.0, 1032.0));
        let centre = InputAction::MoveTo(PointF::new(3840.0 + 688.0, 516.0));
        assert_eq!(m.map(&centre, None), vec![motion(LAIN, 1376.0, 1032.0)]);
        // Fractions pass through, scaled.
        let frac = InputAction::MoveTo(PointF::new(3840.0 + 100.5, 200.25));
        assert_eq!(m.map(&frac, None), vec![motion(LAIN, 201.0, 400.5)]);
        assert_eq!(m.map(&InputAction::MoveTo(PointF::new(100.0, 1564.0)), None), vec![motion(HDMI, 100.0, 1564.0)]);
    }

    #[test]
    fn a_fractionally_scaled_physical_monitor_takes_its_device_pixels() {
        // A HiDPI laptop panel at 1.5: 2560×1600 logical, a 3840×2400 stream.
        let mut m = Mapper::new(Barrier::default());
        let panel =
            Target { bounds: RectF::new(0.0, 0.0, 2560.0, 1600.0), stream: HDMI.into(), primary: true, scale: 1.5 };
        m.set_targets(vec![panel]);
        assert_eq!(m.map(&InputAction::MoveTo(PointF::new(1280.0, 800.0)), None), vec![motion(HDMI, 1920.0, 1200.0)]);
    }

    #[test]
    fn global_to_stream_local_at_scale_one_and_below() {
        // Scale 1 (2752×2064 logical) below HDMI-1, centred.
        let mut m = mapper(RectF::new(544.0, 2160.0, 2752.0, 2064.0));
        assert_eq!(m.map(&InputAction::MoveTo(PointF::new(600.0, 2200.0)), None), vec![motion(LAIN, 56.0, 40.0)]);
        // The boundary row belongs to the monitor below (half-open).
        assert_eq!(m.map(&InputAction::MoveTo(PointF::new(600.0, 2160.0)), None), vec![motion(LAIN, 56.0, 0.0)]);
    }

    #[test]
    fn outside_every_monitor_clamps_to_the_nearest() {
        let mut m = mapper(RectF::new(3840.0, 0.0, 1376.0, 1032.0));
        // Below lain's display, right of HDMI-1's bottom: nearer lain's display.
        let calls = m.map(&InputAction::MoveTo(PointF::new(5000.0, 1100.0)), None);
        let InputCall::MotionAbsolute { stream, x, y } = &calls[0] else { panic!() };
        assert_eq!((stream.as_str(), *x), (LAIN, 2320.0));
        assert!(*y < 2064.0 && *y > 2063.9);
        // Negative coordinates: onto HDMI-1's corner.
        assert_eq!(m.map(&InputAction::MoveTo(PointF::new(-50.0, -50.0)), None), vec![motion(HDMI, 0.0, 0.0)]);
        // No monitors, no calls.
        m.set_targets(vec![]);
        assert!(m.map(&InputAction::MoveTo(PointF::new(1.0, 1.0)), None).is_empty());
    }

    #[test]
    fn crossing_the_panel_band_into_lains_display_takes_the_detour() {
        let mut m = mapper(RectF::new(3840.0, 0.0, 1376.0, 1032.0));
        // Spike B's stuck move: from (391, 1564) to lain's (10, 10), crossing x = 3840 at y ≈ 14.
        m.map(&InputAction::MoveTo(PointF::new(391.0, 1564.0)), None);
        let calls = m.map(&InputAction::MoveTo(PointF::new(3850.0, 10.0)), None);
        assert_eq!(calls, vec![motion(HDMI, 391.0, 32.0), motion(LAIN, 20.0, 64.0), motion(LAIN, 20.0, 20.0)]);
        // The move that went through (crossing at y ≈ 440) goes straight.
        m.map(&InputAction::MoveTo(PointF::new(821.0, 101.0)), None);
        let calls = m.map(&InputAction::MoveTo(PointF::new(3840.0 + 688.0, 516.0)), None);
        assert_eq!(calls, vec![motion(LAIN, 1376.0, 1032.0)]);
    }

    #[test]
    fn starting_on_the_edge_in_the_band_takes_the_detour() {
        let mut m = mapper(RectF::new(3840.0, 0.0, 1376.0, 1032.0));
        // From lain's (0, 0) to its centre (spike B: stuck at x = 0 in one run).
        let calls = m.map(&InputAction::MoveTo(PointF::new(3840.0 + 688.0, 516.0)), Some(PointF::new(3840.0, 0.0)));
        assert_eq!(calls, vec![motion(LAIN, 0.0, 64.0), motion(LAIN, 1376.0, 64.0), motion(LAIN, 1376.0, 1032.0)]);
        // Below the band, or moving left (out of lain's display): straight.
        let calls = m.map(&InputAction::MoveTo(PointF::new(3843.0, 516.0)), Some(PointF::new(3840.0, 516.0)));
        assert_eq!(calls, vec![motion(LAIN, 6.0, 1032.0)]);
        let calls = m.map(&InputAction::MoveTo(PointF::new(3000.0, 5.0)), Some(PointF::new(3845.0, 5.0)));
        assert_eq!(calls, vec![motion(HDMI, 3000.0, 5.0)]);
    }

    #[test]
    fn no_detour_while_a_button_is_held_or_without_a_monitor_beyond_the_edge() {
        let mut m = mapper(RectF::new(3840.0, 0.0, 1376.0, 1032.0));
        m.map(&InputAction::MoveTo(PointF::new(3800.0, 10.0)), None);
        m.map(&InputAction::Button { code: 0x110, down: true }, None);
        let calls = m.map(&InputAction::MoveTo(PointF::new(3850.0, 10.0)), None);
        assert_eq!(calls, vec![motion(LAIN, 20.0, 20.0)]);
        m.map(&InputAction::Button { code: 0x110, down: false }, None);
        assert_eq!(m.map(&InputAction::MoveTo(PointF::new(3800.0, 10.0)), None).len(), 1);
        assert_eq!(m.map(&InputAction::MoveTo(PointF::new(3850.0, 10.0)), None).len(), 3);
        // lain's display below HDMI-1: nothing beyond the panel's edge.
        let mut below = mapper(RectF::new(1232.0, 2160.0, 1376.0, 1032.0));
        below.map(&InputAction::MoveTo(PointF::new(3800.0, 10.0)), None);
        assert_eq!(below.map(&InputAction::MoveTo(PointF::new(3900.0, 10.0)), None).len(), 1);
        // Turned off.
        let mut off = mapper(RectF::new(3840.0, 0.0, 1376.0, 1032.0));
        off.barrier.detour = false;
        off.map(&InputAction::MoveTo(PointF::new(3800.0, 10.0)), None);
        assert_eq!(off.map(&InputAction::MoveTo(PointF::new(3850.0, 10.0)), None).len(), 1);
        // No known start: no detour.
        let mut fresh = mapper(RectF::new(3840.0, 0.0, 1376.0, 1032.0));
        assert_eq!(fresh.map(&InputAction::MoveTo(PointF::new(3850.0, 10.0)), None).len(), 1);
    }

    /// Review L3: the session that held a button ended (its release was dropped, or Mutter released it): the
    /// mapper must not think it is still held, or the detour is off for good.
    #[test]
    fn a_held_button_is_forgotten_when_its_session_ends() {
        let mut m = mapper(RectF::new(3840.0, 0.0, 1376.0, 1032.0));
        m.map(&InputAction::Button { code: 0x110, down: true }, None);
        m.session_ended();
        m.map(&InputAction::MoveTo(PointF::new(3800.0, 10.0)), None);
        assert_eq!(m.map(&InputAction::MoveTo(PointF::new(3850.0, 10.0)), None).len(), 3);
        // Replaced by a new session: the old one's stop released it.
        m.map(&InputAction::Button { code: 0x110, down: true }, None);
        m.buttons_released();
        m.map(&InputAction::MoveTo(PointF::new(3800.0, 10.0)), None);
        assert_eq!(m.map(&InputAction::MoveTo(PointF::new(3850.0, 10.0)), None).len(), 3);
        // An ended session also forgets where the pointer was: no detour without a known start.
        m.session_ended();
        assert_eq!(m.map(&InputAction::MoveTo(PointF::new(3850.0, 10.0)), None).len(), 1);
    }

    #[test]
    fn keys_buttons_and_scrolls() {
        let mut m = mapper(RectF::new(3840.0, 0.0, 1376.0, 1032.0));
        assert_eq!(
            m.map(&InputAction::Key { code: 42, down: true }, None),
            vec![InputCall::Key { code: 42, down: true }]
        );
        assert_eq!(
            m.map(&InputAction::Button { code: 0x111, down: false }, None),
            vec![InputCall::Button { code: 0x111, down: false }]
        );
        let s = |source| InputAction::Scroll { dx: 1.5, dy: -10.0, source };
        assert_eq!(m.map(&s(ScrollSource::Finger), None), vec![InputCall::Axis { dx: 1.5, dy: -10.0, flags: 4 }]);
        assert_eq!(m.map(&s(ScrollSource::Continuous), None), vec![InputCall::Axis { dx: 1.5, dy: -10.0, flags: 8 }]);
        assert_eq!(m.map(&s(ScrollSource::Wheel), None), vec![InputCall::Axis { dx: 1.5, dy: -10.0, flags: 2 }]);
        let stop = |source| InputAction::ScrollStop { source };
        assert_eq!(m.map(&stop(ScrollSource::Finger), None), vec![InputCall::Axis { dx: 0.0, dy: 0.0, flags: 5 }]);
        assert_eq!(m.map(&stop(ScrollSource::Continuous), None), vec![InputCall::Axis { dx: 0.0, dy: 0.0, flags: 9 }]);
        assert_eq!(m.map(&stop(ScrollSource::Wheel), None), vec![]);
        assert_eq!(InputCall::Axis { dx: 0.0, dy: 0.0, flags: 0 }.method(), "NotifyPointerAxis");
    }
}
