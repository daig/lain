//! The frame gate and idle refinement (Swift: `LainMedia/FrameGate.swift`).

/// Counts kept by a [`FrameGate`] (Swift: `FrameGate.Stats`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GateStats {
    pub offered: u64,
    pub encoded: u64,
    /// Replaced in the slot by a newer frame before they could be encoded.
    pub dropped_before_encode: u64,
    pub peak_in_flight: usize,
    /// Re-offers turned away because a newer frame had already been offered.
    pub stale_rejected: u64,
}

/// Invariant 2 in one place (Swift: `FrameGate`): captured frames go into a **latest-wins slot**, and a
/// frame enters the encoder only when the encoder is idle (one frame in, one out) and fewer than
/// `max_in_flight` encoded frames are unacknowledged. Frames are dropped before encoding, never after.
///
/// Intended difference from Swift: this is a plain state machine its owner drives through `&mut self`.
/// Swift's gate holds a lock and calls an `encode` closure outside it; here every method that may free
/// capacity returns the frame to submit to the encoder instead, and the caller submits it. Swift's
/// `isStale` closure is the `stale` argument of [`offer_unless_stale`](Self::offer_unless_stale), checked
/// at the same point.
#[derive(Debug)]
pub struct FrameGate<F> {
    slot: Option<F>,
    encoder_busy: bool,
    window: AckWindowLite,
    stats: GateStats,
}

impl<F> FrameGate<F> {
    /// Swift's default `max_in_flight` is 2.
    ///
    /// # Panics
    /// If `max_in_flight` is 0 (Swift: a precondition).
    pub fn new(max_in_flight: usize) -> Self {
        Self { slot: None, encoder_busy: false, window: AckWindowLite::new(max_in_flight), stats: GateStats::default() }
    }

    pub fn stats(&self) -> GateStats {
        self.stats
    }

    /// Encoded frames not yet acknowledged.
    pub fn in_flight(&self) -> usize {
        self.window.count()
    }

    pub fn slot_occupied(&self) -> bool {
        self.slot.is_some()
    }

    /// The frame waiting in the slot.
    pub fn slot(&self) -> Option<&F> {
        self.slot.as_ref()
    }

    /// Whether a frame is in the encoder.
    pub fn encoder_busy(&self) -> bool {
        self.encoder_busy
    }

    /// A newly captured (or re-offered) frame. Returns it if it goes into the encoder now; otherwise it
    /// waits in the slot, replacing any older frame there.
    #[must_use = "a returned frame must be submitted to the encoder"]
    pub fn offer(&mut self, frame: F) -> Option<F> {
        self.offer_unless_stale(frame, false)
    }

    /// [`offer`](Self::offer), unless `stale`: a re-offer of an older frame (idle refinement, keyframe)
    /// that races a newer capture must neither replace the newer frame in the slot nor be encoded after it
    /// (Swift: the gate's `isStale`).
    #[must_use = "a returned frame must be submitted to the encoder"]
    pub fn offer_unless_stale(&mut self, frame: F, stale: bool) -> Option<F> {
        if stale {
            self.stats.stale_rejected += 1;
            return None;
        }
        self.stats.offered += 1;
        if !self.encoder_busy && self.window.can_send() {
            self.encoder_busy = true;
            self.stats.encoded += 1;
            return Some(frame);
        }
        if self.slot.is_some() {
            self.stats.dropped_before_encode += 1;
        }
        self.slot = Some(frame);
        None
    }

    /// The encoder emitted `frame_id` and it was sent.
    #[must_use = "a returned frame must be submitted to the encoder"]
    pub fn sent(&mut self, frame_id: u32) -> Option<F> {
        self.encoder_busy = false;
        self.window.sent(frame_id);
        self.stats.peak_in_flight = self.stats.peak_in_flight.max(self.window.count());
        self.pump()
    }

    /// The encoder produced nothing for the frame (dropped or failed).
    #[must_use = "a returned frame must be submitted to the encoder"]
    pub fn encode_failed(&mut self) -> Option<F> {
        self.encoder_busy = false;
        self.pump()
    }

    /// A `FrameAck` arrived.
    #[must_use = "a returned frame must be submitted to the encoder"]
    pub fn acked(&mut self, frame_id: u32) -> Option<F> {
        self.window.acked(frame_id);
        self.pump()
    }

    /// Forgets the frames in flight (reconnect, a client that dropped frames without acking them).
    #[must_use = "a returned frame must be submitted to the encoder"]
    pub fn reset(&mut self) -> Option<F> {
        self.window.reset();
        self.pump()
    }

    /// Takes the frame out of the slot if `discard` says so, counting it as dropped before encoding. Not in
    /// Swift: the pipeline uses it when the encoder has already shown the slot's capture (see
    /// `VideoPipeline`).
    pub fn discard_slot_if(&mut self, discard: impl FnOnce(&F) -> bool) -> bool {
        if self.slot.as_ref().is_some_and(discard) {
            self.slot = None;
            self.stats.dropped_before_encode += 1;
            true
        } else {
            false
        }
    }

    fn pump(&mut self) -> Option<F> {
        if self.encoder_busy || !self.window.can_send() {
            return None;
        }
        let frame = self.slot.take()?;
        self.encoder_busy = true;
        self.stats.encoded += 1;
        Some(frame)
    }
}

/// In-flight frame ids (Swift: `FrameAckWindowLite`; [`FrameAckWindow`](crate::FrameAckWindow) also tracks
/// bytes and timing for stats).
#[derive(Debug)]
struct AckWindowLite {
    max_in_flight: usize,
    ids: Vec<u32>,
}

impl AckWindowLite {
    fn new(max_in_flight: usize) -> Self {
        assert!(max_in_flight > 0, "max_in_flight must be positive");
        Self { max_in_flight, ids: Vec::with_capacity(max_in_flight + 1) }
    }

    fn count(&self) -> usize {
        self.ids.len()
    }

    fn can_send(&self) -> bool {
        self.ids.len() < self.max_in_flight
    }

    fn sent(&mut self, id: u32) {
        self.ids.push(id);
    }

    /// Acks arrive in order; an ack retires older frames too.
    fn acked(&mut self, id: u32) {
        if let Some(i) = self.ids.iter().position(|&x| x == id) {
            self.ids.drain(..=i);
        }
    }

    fn reset(&mut self) {
        self.ids.clear();
    }
}

/// Idle refinement (Swift: `IdleRefiner`, §5.3): after `idle_ms` (150) without a new frame, re-submit the
/// last frame, up to `max_refinements` (2) times, so static text sharpens. Each refinement waits another
/// `idle_ms`.
#[derive(Debug, Clone)]
pub struct IdleRefiner {
    pub idle_ns: u64,
    pub max_refinements: u32,
    last_new_frame_ns: Option<u64>,
    done: u32,
}

impl Default for IdleRefiner {
    fn default() -> Self {
        Self::new(150, 2)
    }
}

impl IdleRefiner {
    pub fn new(idle_ms: u64, max_refinements: u32) -> Self {
        Self { idle_ns: idle_ms * 1_000_000, max_refinements, last_new_frame_ns: None, done: 0 }
    }

    pub fn new_frame(&mut self, time_ns: u64) {
        self.last_new_frame_ns = Some(time_ns);
        self.done = 0;
    }

    /// True when the last frame should be re-submitted now; counts the refinement.
    pub fn should_refine(&mut self, time_ns: u64) -> bool {
        match self.next_due() {
            Some(due) if time_ns >= due => {
                self.done += 1;
                true
            }
            _ => false,
        }
    }

    /// When [`should_refine`](Self::should_refine) next returns true, if ever (no frame yet, or all
    /// refinements done). Not in Swift, whose pipeline polls every 10 ms: the sans-IO pipeline arms a timer
    /// for exactly this time.
    pub fn next_due(&self) -> Option<u64> {
        let last = self.last_new_frame_ns?;
        if self.done >= self.max_refinements {
            return None;
        }
        Some(last.saturating_add(self.idle_ns.saturating_mul(u64::from(self.done) + 1)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A gate whose encoder submissions are recorded (Swift: `Submissions`).
    struct Harness {
        gate: FrameGate<u32>,
        subs: Vec<u32>,
    }

    impl Harness {
        fn new(max_in_flight: usize) -> Self {
            Self { gate: FrameGate::new(max_in_flight), subs: Vec::new() }
        }
        fn record(&mut self, f: Option<u32>) {
            self.subs.extend(f);
        }
        fn offer(&mut self, f: u32) {
            let r = self.gate.offer(f);
            self.record(r);
        }
        fn offer_unless_stale(&mut self, f: u32, newest: u32) {
            let r = self.gate.offer_unless_stale(f, f < newest);
            self.record(r);
        }
        fn sent(&mut self, id: u32) {
            let r = self.gate.sent(id);
            self.record(r);
        }
        fn acked(&mut self, id: u32) {
            let r = self.gate.acked(id);
            self.record(r);
        }
        fn failed(&mut self) {
            let r = self.gate.encode_failed();
            self.record(r);
        }
    }

    #[test]
    fn encodes_immediately_when_idle() {
        let mut h = Harness::new(2);
        h.offer(1);
        assert_eq!(h.subs, [1]);
        assert!(!h.gate.slot_occupied());
    }

    #[test]
    fn one_frame_in_the_encoder_and_latest_wins() {
        let mut h = Harness::new(2);
        h.offer(1); // encoding
        h.offer(2); // slot
        h.offer(3); // replaces 2
        assert_eq!(h.subs, [1]);
        assert_eq!(h.gate.stats().dropped_before_encode, 1);
        h.sent(1); // encoder free → 3 goes in
        assert_eq!(h.subs, [1, 3]);
        assert!(!h.gate.slot_occupied());
    }

    #[test]
    fn stale_reoffer_never_replaces_or_follows_a_newer_frame() {
        let mut h = Harness::new(2);
        h.offer_unless_stale(1, 1); // encoding
        let newest = 2;
        h.offer_unless_stale(2, newest); // slot
        h.offer_unless_stale(1, newest); // an idle refinement of 1 built just before 2 arrived
        assert_eq!(h.gate.stats().stale_rejected, 1);
        assert_eq!(h.gate.stats().dropped_before_encode, 0);
        h.sent(1);
        assert_eq!(h.subs, [1, 2]);
        h.sent(2);
        h.acked(2);
        h.offer_unless_stale(1, newest); // encoder idle: still not encoded after 2
        assert_eq!(h.subs, [1, 2]);
        h.offer_unless_stale(2, newest); // a refinement of the newest frame is fine
        assert_eq!(h.subs, [1, 2, 2]);
    }

    #[test]
    fn unacked_frames_hold_the_slot() {
        let mut h = Harness::new(2);
        h.offer(1);
        h.sent(1);
        h.offer(2);
        h.sent(2);
        h.offer(3); // 2 in flight: waits
        h.offer(4); // latest wins
        assert_eq!(h.subs, [1, 2]);
        assert_eq!(h.gate.in_flight(), 2);
        h.acked(1);
        assert_eq!(h.subs, [1, 2, 4]);
        assert_eq!(
            h.gate.stats(),
            GateStats { offered: 4, encoded: 3, dropped_before_encode: 1, peak_in_flight: 2, stale_rejected: 0 }
        );
    }

    #[test]
    fn cumulative_acks_and_failures() {
        let mut h = Harness::new(2);
        h.offer(1);
        h.sent(1);
        h.offer(2);
        h.sent(2);
        h.acked(2); // retires 1 and 2
        assert_eq!(h.gate.in_flight(), 0);
        h.offer(3);
        h.offer(4);
        h.failed(); // 3 produced nothing; 4 goes in
        assert_eq!(h.subs, [1, 2, 3, 4]);
    }

    /// Swift's `concurrentOffersNeverExceedLimits` races four offering tasks against a sender/acker. The
    /// gate here has no lock to race, so this drives the same mix of calls in a deterministic pseudo-random
    /// interleaving and checks the same invariants after every step.
    #[test]
    fn interleaved_offers_never_exceed_limits() {
        let mut h = Harness::new(2);
        let mut seed: u32 = 0x1234_5678;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed
        };
        let mut offered = 0;
        let mut acked_up_to = 0;
        while offered < 2000 {
            match next() % 4 {
                0 | 1 => {
                    offered += 1;
                    h.offer(offered);
                }
                2 if h.gate.encoder_busy() => {
                    let last = *h.subs.last().unwrap();
                    h.sent(last);
                }
                _ => {
                    if let Some(&last) = h.subs.last()
                        && last > acked_up_to
                    {
                        acked_up_to = last;
                        h.acked(last);
                    }
                }
            }
            assert!(h.gate.in_flight() <= 2);
            let s = h.gate.stats();
            assert_eq!(s.encoded + s.dropped_before_encode + u64::from(h.gate.slot_occupied()), s.offered);
        }
        assert_eq!(h.gate.stats().offered, 2000);
        assert!(h.gate.stats().peak_in_flight <= 2);
    }

    #[test]
    fn discard_slot_counts_as_dropped() {
        let mut h = Harness::new(2);
        h.offer(1);
        h.offer(2);
        assert!(!h.gate.discard_slot_if(|&f| f == 1));
        assert!(h.gate.discard_slot_if(|&f| f == 2));
        assert!(!h.gate.slot_occupied());
        let s = h.gate.stats();
        assert_eq!((s.offered, s.encoded, s.dropped_before_encode), (2, 1, 1));
        h.sent(1);
        assert_eq!(h.subs, [1]);
    }

    #[test]
    #[should_panic(expected = "max_in_flight")]
    fn zero_in_flight_is_refused() {
        let _ = FrameGate::<u32>::new(0);
    }

    const MS: u64 = 1_000_000;

    #[test]
    fn refines_twice_after_idle() {
        let mut r = IdleRefiner::new(150, 2);
        assert!(!r.should_refine(0)); // nothing captured yet
        assert_eq!(r.next_due(), None);
        r.new_frame(0);
        assert_eq!(r.next_due(), Some(150 * MS));
        assert!(!r.should_refine(149 * MS));
        assert!(r.should_refine(150 * MS));
        assert_eq!(r.next_due(), Some(300 * MS));
        assert!(!r.should_refine(200 * MS));
        assert!(r.should_refine(300 * MS));
        assert!(!r.should_refine(900 * MS)); // at most two
        assert_eq!(r.next_due(), None);
        r.new_frame(1000 * MS); // motion resets
        assert!(!r.should_refine(1100 * MS));
        assert!(r.should_refine(1150 * MS));
    }

    #[test]
    fn a_clock_before_the_last_frame_never_refines() {
        let mut r = IdleRefiner::new(150, 2);
        r.new_frame(500 * MS);
        assert!(!r.should_refine(100 * MS));
    }
}
