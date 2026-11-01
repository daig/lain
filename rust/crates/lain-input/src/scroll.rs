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
//!
//! **How GTK 4 measures its fling** (`gtk/gtkeventcontrollerscroll.c`, read 2026-11-01; to be confirmed live
//! in open spike 4): every smooth scroll event, the stop included, is pushed into a history that keeps only
//! the events of the last `SCROLL_CAPTURE_THRESHOLD_MS` (150 ms) before the newest one; at the stop, the
//! velocity is the history's summed deltas over its time span. So a stop sent right after fast deltas flings
//! fast, and a stop sent more than 150 ms after the last delta finds only itself in the history and doesn't
//! fling at all (Mutter stamps injected events on arrival). [`Momentum::Client`] relies on the second rule.

use lain_platform::{InputAction, ScrollSource};
use lain_proto::{GesturePhase, MomentumPhase, Scroll};

/// Which kinetic continuation follows a scroll gesture. Either way there is only ever one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum Momentum {
    /// The desktop's own: the phase's end (or cancel) becomes a [`InputAction::ScrollStop`] at once, after
    /// which the toolkit flings from the phase's last deltas, and the client's momentum is dropped. The
    /// default (the brief's policy). A cancelled phase flings too, where the Mac's doesn't: Wayland has no
    /// cancel.
    #[default]
    Desktop,
    /// The client's: its momentum is passed through as more scrolls of the same sequence, and the toolkit
    /// must not fling at all. For open spike 4, to compare. Every end of the sequence (the phase's end or
    /// cancel; the momentum's end, whether it decayed or the client cut it short for a new touch, a click, a
    /// wheel notch or a release) holds the stop back until [`ScrollConfig::client_stop_delay_ns`] after the
    /// last delta, so that GTK's velocity window is empty when it arrives (see the module documentation).
    /// Meanwhile:
    /// - the client's momentum (which begins one display frame after the phase ends) continues the sequence;
    /// - a new touch continues it too, with no stop in between, so nothing flings;
    /// - other input (keys, moves, clicks, pinches) goes out inside the still-open sequence;
    /// - the stop goes out from [`InputRouter::poll`](crate::InputRouter::poll) at the deadline, or before
    ///   the first message handled after it. A slow lift, after which the client starts no momentum (under
    ///   150 pt/s), therefore ends without a fling, as on the Mac.
    ///
    /// Two cases send the stop early, so the toolkit may fling from recent fast deltas (spike 4 to check how
    /// much): a wheel notch (a wheel never goes inside a `Finger` sequence) and release-all (nothing may stay
    /// open once the link is gone).
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
    /// [`Momentum::Client`] only: how long after the sequence's last delta its held-back stop goes out. Above
    /// GTK 4's 150 ms velocity window, with a margin for delivery. No Swift counterpart.
    pub client_stop_delay_ns: u64,
}

impl ScrollConfig {
    /// The default [`client_stop_delay_ns`](Self::client_stop_delay_ns): 200 ms.
    pub const DEFAULT_CLIENT_STOP_DELAY_NS: u64 = 200_000_000;
}

impl Default for ScrollConfig {
    fn default() -> Self {
        Self {
            momentum: Momentum::Desktop,
            phased_source: ScrollSource::Finger,
            client_stop_delay_ns: Self::DEFAULT_CLIENT_STOP_DELAY_NS,
        }
    }
}

/// Where a phased scroll sequence is, as the desktop has seen it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Sequence {
    /// Nothing open.
    Idle,
    /// Scrolls sent from the client's phase (fingers down), no stop yet.
    Phase,
    /// [`Momentum::Client`]: the client's momentum continues the sequence.
    Momentum,
    /// [`Momentum::Client`]: the phase or the momentum ended; the stop is due `client_stop_delay_ns` after
    /// the last delta.
    PendingStop,
}

/// The scroll state machine. Swift: `HostInputRouter.noteScroll` plus `InputInjector.scroll`.
#[derive(Debug, Clone)]
pub(crate) struct ScrollPolicy {
    config: ScrollConfig,
    sequence: Sequence,
    /// When the open sequence's last delta was sent.
    last_delta_ns: u64,
}

impl ScrollPolicy {
    pub(crate) fn new(config: ScrollConfig) -> Self {
        Self { config, sequence: Sequence::Idle, last_delta_ns: 0 }
    }

    /// Whether a sequence is open on the desktop (a stop is owed).
    pub(crate) fn is_open(&self) -> bool {
        self.sequence != Sequence::Idle
    }

    /// When a held-back stop is due ([`Momentum::Client`] only).
    pub(crate) fn deadline(&self) -> Option<u64> {
        (self.sequence == Sequence::PendingStop)
            .then(|| self.last_delta_ns.saturating_add(self.config.client_stop_delay_ns))
    }

    /// Sends a held-back stop whose deadline has passed. Returns whether it did.
    pub(crate) fn poll(&mut self, now_ns: u64, out: &mut Vec<InputAction>) -> bool {
        match self.deadline() {
            Some(deadline) if now_ns >= deadline => {
                self.stop(out);
                true
            }
            _ => false,
        }
    }

    /// One client scroll at `now_ns`. Returns whether it did anything on the desktop.
    pub(crate) fn scroll(&mut self, s: &Scroll, now_ns: u64, out: &mut Vec<InputAction>) -> bool {
        let start = out.len();
        let (dx, dy) = wayland_delta(s);
        let moved = dx != 0.0 || dy != 0.0;
        let client = self.config.momentum == Momentum::Client;
        match (s.phase, s.momentum_phase) {
            // A wheel: no phase, no momentum. It ends any open sequence first (the client ends its own
            // momentum before a wheel notch), so a wheel never goes inside a `Finger` sequence.
            (GesturePhase::None, MomentumPhase::None) => {
                if moved {
                    self.end(out);
                    out.push(InputAction::Scroll { dx, dy, source: ScrollSource::Wheel });
                }
            }
            // The phase: deltas while the fingers are down. A new touch while a stop is held back or the
            // client's momentum runs continues the same sequence (no stop, so no fling in between).
            (GesturePhase::Began | GesturePhase::Changed, _) => {
                if moved {
                    self.delta(dx, dy, now_ns, out);
                    self.sequence = Sequence::Phase;
                }
            }
            // A touch that hasn't moved: nothing to scroll yet.
            (GesturePhase::MayBegin, _) => {}
            (GesturePhase::Ended, _) => {
                if moved {
                    self.delta(dx, dy, now_ns, out);
                    self.sequence = Sequence::Phase;
                }
                if self.sequence != Sequence::Idle {
                    self.ended(out);
                }
            }
            // The system cancelled the pan; the client starts no momentum after it. Wayland has no cancel, so
            // this ends the sequence like an end.
            (GesturePhase::Cancelled, _) => {
                if self.sequence != Sequence::Idle {
                    self.ended(out);
                }
            }
            // The client's momentum, continuing a sequence the phase left open.
            (GesturePhase::None, MomentumPhase::Began | MomentumPhase::Changed) => {
                if client && matches!(self.sequence, Sequence::PendingStop | Sequence::Momentum) {
                    self.sequence = Sequence::Momentum;
                    if moved {
                        self.delta(dx, dy, now_ns, out);
                    }
                }
            }
            // The momentum's end, natural or cut short by the client. Its stop is held back like the phase's:
            // after a cut, the momentum's last deltas are fast, and the new touch that usually follows
            // continues the sequence.
            (GesturePhase::None, MomentumPhase::Ended) => {
                if client && self.sequence == Sequence::Momentum {
                    self.sequence = Sequence::PendingStop;
                }
            }
        }
        out.len() > start
    }

    /// Ends whatever is open, at once (Swift: `HostInputRouter.releaseAll`, which ends an open phase and
    /// momentum).
    pub(crate) fn end(&mut self, out: &mut Vec<InputAction>) {
        if self.sequence != Sequence::Idle {
            self.stop(out);
        }
    }

    fn delta(&mut self, dx: f64, dy: f64, now_ns: u64, out: &mut Vec<InputAction>) {
        out.push(InputAction::Scroll { dx, dy, source: self.config.phased_source });
        self.last_delta_ns = now_ns;
    }

    /// The end of the phase: a stop now, or one held back.
    fn ended(&mut self, out: &mut Vec<InputAction>) {
        match self.config.momentum {
            Momentum::Desktop => self.stop(out),
            Momentum::Client => self.sequence = Sequence::PendingStop,
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
