//! The client's scrolls as desktop scrolls. Swift: the scroll half of `HostInputRouter` (which tracks open
//! phases for `releaseAll`) and `InputInjector.scroll` (which posts phases and momentum as they come).
//!
//! **Units and sign.** The client's `Scroll` deltas are UIKit pan-translation deltas in points (the content
//! follows the fingers: a positive `dy` moves the content down, towards the top of the document), and Swift
//! posts them as they are as `CGEvent` pixel deltas, whose positive values scroll up. Wayland's convention
//! is the opposite (positive `dy` scrolls down), so both axes are negated; points equal logical pixels (L8).
//! The client's own "invert scroll" setting has already been applied.
//!
//! **Kinetic scrolling.** macOS takes the client's synthesized momentum as the fling. GTK 4 flings by itself
//! after a stop from a `Finger` or `Continuous` source, so the client's momentum and GTK's fling must never
//! both happen; [`Momentum`] picks which one does.

use lain_platform::{InputAction, ScrollSource};
use lain_proto::{GesturePhase, MomentumPhase, Scroll};

/// Which kinetic continuation follows a scroll gesture. Either way there is only ever one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Momentum {
    /// The desktop's own: the phase's end becomes a [`InputAction::ScrollStop`], after which the toolkit
    /// flings, and the client's momentum is dropped. The default (the brief's policy).
    #[default]
    Desktop,
    /// The client's: its momentum is passed through as more scrolls of the same sequence, and the stop is sent
    /// only when the momentum ends (when the toolkit's fling, from the momentum's last and slowest deltas, is
    /// negligible). For open spike 4, to compare. Because the router can't wait for the client's momentum to
    /// begin (one display frame after the phase ends), the phase's stop is held back until the next message:
    /// if that is momentum, the momentum continues the sequence; if it is anything else, the stop is sent then,
    /// and momentum arriving later is dropped (the toolkit is already flinging).
    Client,
}

/// How scrolls go to the desktop.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ScrollConfig {
    pub momentum: Momentum,
    /// The source of the client's phased (trackpad) scrolls. `Finger` by default: GTK 4 takes the deltas 1:1
    /// and flings after the stop. `Continuous` behaves the same in GTK 4; `Wheel` would turn each delta into
    /// detents (10 pixels each) with no fling. Open spike 4 decides.
    pub phased_source: ScrollSource,
}

impl Default for ScrollConfig {
    fn default() -> Self {
        Self { momentum: Momentum::Desktop, phased_source: ScrollSource::Finger }
    }
}

/// Where a phased scroll sequence is, as the desktop has seen it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Sequence {
    /// Nothing open.
    Idle,
    /// Scrolls sent from the client's phase (fingers down), no stop yet.
    Phase,
    /// [`Momentum::Client`]: the phase ended, and its stop waits for the next message.
    PendingStop,
    /// [`Momentum::Client`]: the client's momentum continues the sequence.
    Momentum,
}

/// The scroll state machine. Swift: `HostInputRouter.noteScroll` plus `InputInjector.scroll`.
#[derive(Debug, Clone)]
pub(crate) struct ScrollPolicy {
    config: ScrollConfig,
    sequence: Sequence,
}

impl ScrollPolicy {
    pub(crate) fn new(config: ScrollConfig) -> Self {
        Self { config, sequence: Sequence::Idle }
    }

    /// Whether a sequence is open on the desktop (a stop is owed).
    pub(crate) fn is_open(&self) -> bool {
        self.sequence != Sequence::Idle
    }

    /// One client scroll. Returns whether it did anything on the desktop.
    pub(crate) fn scroll(&mut self, s: &Scroll, out: &mut Vec<InputAction>) -> bool {
        let start = out.len();
        let (dx, dy) = wayland_delta(s);
        let source = self.config.phased_source;
        match (s.phase, s.momentum_phase) {
            // A wheel: no phase, no momentum. It ends any open sequence first (the client ends its own
            // momentum before a wheel notch).
            (GesturePhase::None, MomentumPhase::None) => {
                if dx != 0.0 || dy != 0.0 {
                    self.end(out);
                    out.push(InputAction::Scroll { dx, dy, source: ScrollSource::Wheel });
                }
            }
            // The phase: deltas while the fingers are down. A new touch after a pending stop or the client's
            // momentum continues the same sequence (no stop, so no fling in between).
            (GesturePhase::Began | GesturePhase::Changed, _) => {
                if dx != 0.0 || dy != 0.0 {
                    out.push(InputAction::Scroll { dx, dy, source });
                    self.sequence = Sequence::Phase;
                }
            }
            // A touch that hasn't moved: nothing to scroll yet.
            (GesturePhase::MayBegin, _) => {}
            (GesturePhase::Ended, _) => {
                if dx != 0.0 || dy != 0.0 {
                    out.push(InputAction::Scroll { dx, dy, source });
                    self.sequence = Sequence::Phase;
                }
                if self.sequence == Sequence::Phase {
                    match self.config.momentum {
                        Momentum::Desktop => self.stop(out),
                        Momentum::Client => self.sequence = Sequence::PendingStop,
                    }
                }
            }
            // The system cancelled the pan; the client starts no momentum after it. Wayland has no cancel, so
            // this is a stop too (and the toolkit may fling: a difference from the Mac, where a cancelled phase
            // has none).
            (GesturePhase::Cancelled, _) => self.end(out),
            // The client's momentum.
            (GesturePhase::None, MomentumPhase::Began | MomentumPhase::Changed) => {
                if self.config.momentum == Momentum::Client
                    && matches!(self.sequence, Sequence::PendingStop | Sequence::Momentum)
                {
                    self.sequence = Sequence::Momentum;
                    if dx != 0.0 || dy != 0.0 {
                        out.push(InputAction::Scroll { dx, dy, source });
                    }
                }
            }
            (GesturePhase::None, MomentumPhase::Ended) => {
                if matches!(self.sequence, Sequence::PendingStop | Sequence::Momentum) {
                    self.stop(out);
                }
            }
        }
        out.len() > start
    }

    /// Any input message other than a scroll: a stop held back for the client's momentum is sent now, since
    /// the momentum, which would have come first, isn't coming.
    pub(crate) fn before_other_input(&mut self, out: &mut Vec<InputAction>) {
        if self.sequence == Sequence::PendingStop {
            self.stop(out);
        }
    }

    /// Ends whatever is open (Swift: `HostInputRouter.releaseAll`, which ends an open phase and momentum).
    pub(crate) fn end(&mut self, out: &mut Vec<InputAction>) {
        if self.sequence != Sequence::Idle {
            self.stop(out);
        }
    }

    fn stop(&mut self, out: &mut Vec<InputAction>) {
        out.push(InputAction::ScrollStop { source: self.config.phased_source });
        self.sequence = Sequence::Idle;
    }
}

/// The client's deltas in Wayland's convention (see the module documentation). A non-finite delta is 0.
fn wayland_delta(s: &Scroll) -> (f64, f64) {
    // 0 − v rather than −v, so a zero axis stays +0.
    let axis = |v: f32| if v.is_finite() { 0.0 - f64::from(v) } else { 0.0 };
    (axis(s.dx), axis(s.dy))
}
