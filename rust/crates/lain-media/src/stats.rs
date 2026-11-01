//! The ack window with timing, rolling percentiles, the byte-rate meter and the pipeline's stats snapshot
//! (Swift: `LainTransport/FrameAckWindow.swift`, `LainTelemetry/RollingPercentiles.swift`,
//! `LainHostCore/Video/HostVideoPipeline.swift`'s `HostVideoStats` and `RateMeter`).

use std::collections::VecDeque;

use lain_proto::ChromaFormat;

/// One retired frame (Swift: `FrameAckWindow.Ack`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Ack {
    pub frame_id: u32,
    /// Send → ack received, on the host clock.
    pub round_trip_ns: u64,
    pub bytes: usize,
}

/// Frame-ack backpressure with sizes and send times (Swift: `FrameAckWindow`, §7.3): the host encodes a
/// new frame only while fewer than `max_in_flight` frames are unacknowledged. The pipeline uses it for
/// round-trip stats; the [`FrameGate`](crate::FrameGate) keeps its own id-only window for the gating.
#[derive(Debug, Clone)]
pub struct FrameAckWindow {
    pub max_in_flight: usize,
    in_flight: VecDeque<(u32, usize, u64)>,
}

impl FrameAckWindow {
    /// # Panics
    /// If `max_in_flight` is 0 (Swift: a precondition).
    pub fn new(max_in_flight: usize) -> Self {
        assert!(max_in_flight > 0, "max_in_flight must be positive");
        Self { max_in_flight, in_flight: VecDeque::with_capacity(8) }
    }

    pub fn in_flight_count(&self) -> usize {
        self.in_flight.len()
    }

    pub fn can_send(&self) -> bool {
        self.in_flight.len() < self.max_in_flight
    }

    pub fn sent(&mut self, frame_id: u32, bytes: usize, time_ns: u64) {
        self.in_flight.push_back((frame_id, bytes, time_ns));
    }

    /// Records an ack. Acks arrive in order on one TCP stream, so an ack also retires anything older.
    /// `None` for an unknown (stale or duplicate) frame.
    pub fn acked(&mut self, frame_id: u32, time_ns: u64) -> Option<Ack> {
        let i = self.in_flight.iter().position(|f| f.0 == frame_id)?;
        let (_, bytes, sent_ns) = self.in_flight[i];
        self.in_flight.drain(..=i);
        Some(Ack { frame_id, round_trip_ns: time_ns.saturating_sub(sent_ns), bytes })
    }

    /// Forgets everything in flight (reconnect, keyframe restart).
    pub fn reset(&mut self) {
        self.in_flight.clear();
    }
}

impl Default for FrameAckWindow {
    fn default() -> Self {
        Self::new(2)
    }
}

/// A fixed-capacity window of recent values with percentiles on demand (Swift: `RollingPercentiles`).
/// `record` never allocates; `percentile` sorts a copy and is for the control plane.
#[derive(Debug, Clone)]
pub struct RollingPercentiles {
    values: Vec<f64>,
    count: usize,
    next: usize,
}

impl RollingPercentiles {
    /// # Panics
    /// If `capacity` is 0 (Swift: a precondition).
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "capacity must be positive");
        Self { values: vec![0.0; capacity], count: 0, next: 0 }
    }

    pub fn capacity(&self) -> usize {
        self.values.len()
    }

    pub fn record(&mut self, v: f64) {
        self.values[self.next] = v;
        self.next = if self.next + 1 == self.values.len() { 0 } else { self.next + 1 };
        if self.count < self.values.len() {
            self.count += 1;
        }
    }

    pub fn sample_count(&self) -> usize {
        self.count
    }

    /// Nearest-rank percentile, `p` in 0...1; `None` when empty.
    pub fn percentile(&self, p: f64) -> Option<f64> {
        if self.count == 0 {
            return None;
        }
        let mut sorted = self.values[..self.count].to_vec();
        sorted.sort_by(f64::total_cmp);
        let rank = (p * self.count as f64).ceil() as i64 - 1;
        Some(sorted[rank.clamp(0, self.count as i64 - 1) as usize])
    }

    pub fn p50(&self) -> Option<f64> {
        self.percentile(0.5)
    }

    pub fn p95(&self) -> Option<f64> {
        self.percentile(0.95)
    }

    pub fn reset(&mut self) {
        self.count = 0;
        self.next = 0;
    }
}

impl Default for RollingPercentiles {
    fn default() -> Self {
        Self::new(240)
    }
}

/// Bytes per second over a sliding window, from a fixed ring (Swift: `RateMeter`).
#[derive(Debug, Clone)]
pub struct RateMeter {
    times: Vec<u64>,
    bytes: Vec<usize>,
    next: usize,
    count: usize,
}

impl RateMeter {
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "capacity must be positive");
        Self { times: vec![0; capacity], bytes: vec![0; capacity], next: 0, count: 0 }
    }

    pub fn record(&mut self, bytes: usize, time_ns: u64) {
        self.times[self.next] = time_ns;
        self.bytes[self.next] = bytes;
        self.next = (self.next + 1) % self.times.len();
        self.count = (self.count + 1).min(self.times.len());
    }

    /// The bytes recorded in the `window_ns` up to `now_ns`, per second of that window.
    pub fn bytes_per_second(&self, now_ns: u64, window_ns: u64) -> f64 {
        let n = self.times.len();
        let mut sum = 0usize;
        for i in 0..self.count {
            let j = (self.next + n - 1 - i) % n;
            if now_ns < self.times[j] || now_ns - self.times[j] > window_ns {
                break;
            }
            sum += self.bytes[j];
        }
        sum as f64 * 1e9 / window_ns as f64
    }
}

impl Default for RateMeter {
    fn default() -> Self {
        Self::new(512)
    }
}

/// A snapshot of the host video path for status and the HUD (Swift: `HostVideoStats`). Counters are
/// `u64` where Swift has `Int`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct HostVideoStats {
    pub chroma: Option<ChromaFormat>,
    pub pixel_width: u32,
    pub pixel_height: u32,
    /// Captures announced by the session.
    pub captured: u64,
    /// Offered to the latest-wins slot: captures plus idle refinements and keyframe re-offers.
    pub offered: u64,
    /// Submitted to the encoder.
    pub encoded: u64,
    /// Replaced in the slot before they could be encoded (invariant 2: drops happen only here).
    pub dropped_before_encode: u64,
    /// `EncodeFailed` results, and access units the pipeline couldn't send (malformed, or no parameter sets
    /// yet). Swift counts only the encoder's failures.
    pub encode_failures: u64,
    /// Frames put on the video connection.
    pub sent: u64,
    pub keyframes: u64,
    pub refinements: u64,
    pub in_flight: usize,
    pub peak_in_flight: usize,
    pub bytes_sent: u64,
    /// Over the last second.
    pub bytes_per_second: f64,
    /// Submit → encoded, over the last 240 frames.
    pub encode_ms_p50: Option<f64>,
    pub encode_ms_p95: Option<f64>,
    /// Frame sent → `FrameAck` received, on the host clock.
    pub ack_rtt_ms_p50: Option<f64>,
    pub ack_rtt_ms_p95: Option<f64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    // Swift: StreamTests `ackWindow…`.
    #[test]
    fn ack_window_gates_and_measures() {
        let mut w = FrameAckWindow::new(2);
        assert!(w.can_send());
        w.sent(1, 100, 0);
        w.sent(2, 200, 10);
        assert!(!w.can_send());
        assert_eq!(w.acked(1, 50), Some(Ack { frame_id: 1, round_trip_ns: 50, bytes: 100 }));
        assert!(w.can_send() && w.in_flight_count() == 1);
    }

    #[test]
    fn ack_retires_older_frames_and_ignores_unknown() {
        let mut w = FrameAckWindow::new(3);
        for i in 1..=3 {
            w.sent(i, 1, 0);
        }
        assert_eq!(w.acked(3, 9).map(|a| a.frame_id), Some(3));
        assert_eq!(w.in_flight_count(), 0);
        assert_eq!(w.acked(2, 10), None);
        w.sent(4, 1, 0);
        w.reset();
        assert_eq!(w.in_flight_count(), 0);
    }

    #[test]
    fn a_clock_behind_the_send_gives_zero_round_trip() {
        let mut w = FrameAckWindow::new(2);
        w.sent(1, 1, 100);
        assert_eq!(w.acked(1, 50).unwrap().round_trip_ns, 0);
    }

    #[test]
    fn percentiles_are_nearest_rank_over_the_window() {
        let mut r = RollingPercentiles::new(4);
        assert_eq!(r.p50(), None);
        for v in [4.0, 1.0, 3.0, 2.0] {
            r.record(v);
        }
        assert_eq!(r.p50(), Some(2.0));
        assert_eq!(r.p95(), Some(4.0));
        assert_eq!(r.percentile(0.0), Some(1.0));
        r.record(10.0); // evicts 4.0
        assert_eq!(r.sample_count(), 4);
        assert_eq!(r.p95(), Some(10.0));
        assert_eq!(r.p50(), Some(2.0));
        r.reset();
        assert_eq!(r.p50(), None);
    }

    #[test]
    fn rate_meter_counts_the_last_window() {
        let mut m = RateMeter::new(4);
        assert_eq!(m.bytes_per_second(0, 1_000_000_000), 0.0);
        m.record(100, 0);
        m.record(200, 600_000_000);
        m.record(300, 1_200_000_000);
        assert_eq!(m.bytes_per_second(1_200_000_000, 1_000_000_000), 500.0);
        assert_eq!(m.bytes_per_second(1_200_000_000, 2_000_000_000), 300.0);
        for t in 0..4 {
            m.record(1, 2_000_000_000 + t);
        }
        assert_eq!(m.bytes_per_second(2_000_000_010, 1_000_000_000), 4.0, "the ring holds four");
    }
}
