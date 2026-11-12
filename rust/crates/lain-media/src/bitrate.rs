//! Adaptive bitrate (M6b): steers the encoder's target to what the link delivers, from the frame acks alone
//! (no protocol change). Swift: `LainMedia/BitrateController.swift`, rule for rule (each came from a device
//! trace over Wi-Fi; see the tests), with the radio-pause fix of 2026-11-01 in both.
//!
//! - **Queueing** is the median of the latest round trips over the best one seen in the last 10 s. A median
//!   over several frames, so one frame caught in a link stall (AWDL's ~270 ms pause once a second) isn't taken
//!   for congestion, while frames that keep arriving late are.
//! - **Down**, quickly: queueing above `congested_ms` lowers the target to 90% of the measured delivery rate
//!   (or by `decrease` if too few acks to measure), at most every `decrease_interval_ns`, never below `floor`.
//!   Both need the link busy ([`BitrateController::is_busy`]: several frames held back lately, and a real
//!   delivery rate), so a quiet link's stalls and tiny frames never lower it. A busy link delivering under 90%
//!   of the target is saturated too: the gate (two frames in flight) holds frames back before the queue grows,
//!   costing frame rate, so the target drops to 90% of the delivery rate. Fluidity first: smaller frames
//!   rather than fewer.
//! - **Up**, slowly: queueing below `clear_ms` on a link that isn't busy, for `increase_interval_ns`, raises it
//!   by `increase`, up to `ceiling` (probing). Frames held back while the acks have stopped (a radio pause) don't
//!   make it busy ([`BitrateController::held_back`]).
//! - Nothing comes down during `warmup_ns` after the first ack, and one step down is at most to `max_step` of
//!   the target.

use std::collections::VecDeque;

/// Tuning (Swift: `BitrateController.Config`).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BitrateConfig {
    pub floor: u32,
    pub ceiling: u32,
    pub congested_ms: f64,
    pub clear_ms: f64,
    /// A decrease without a delivery rate to go by, and the smallest step down.
    pub decrease: f64,
    /// The largest step down: never below this share of the target in one step.
    pub max_step: f64,
    /// No decrease this soon after the first ack (the first keyframe and its burst).
    pub warmup_ns: u64,
    pub increase: f64,
    pub decrease_interval_ns: u64,
    pub increase_interval_ns: u64,
    /// The round trips the median is taken over (and how old they may be).
    pub recent_samples: usize,
    pub recent_window_ns: u64,
    pub delivery_window_ns: u64,
    pub min_rtt_window_ns: u64,
    /// The link is busy (the target may come down) when the gate held back at least `busy_held_back` frames in
    /// the last `held_back_window_ns` and it delivered at least `busy_delivery_bps`.
    pub held_back_window_ns: u64,
    pub busy_held_back: usize,
    pub busy_delivery_bps: u64,
}

impl Default for BitrateConfig {
    fn default() -> Self {
        Self {
            floor: 6_000_000,
            ceiling: 60_000_000,
            congested_ms: 30.0,
            clear_ms: 10.0,
            decrease: 0.9,
            max_step: 0.7,
            warmup_ns: 1_000_000_000,
            increase: 1.15,
            decrease_interval_ns: 250_000_000,
            increase_interval_ns: 500_000_000,
            recent_samples: 8,
            recent_window_ns: 500_000_000,
            delivery_window_ns: 500_000_000,
            min_rtt_window_ns: 10_000_000_000,
            held_back_window_ns: 500_000_000,
            busy_held_back: 3,
            busy_delivery_bps: 3_000_000,
        }
    }
}

/// The controller (Swift: `BitrateController`). Pure: the pipeline feeds it every `FrameAck` and every frame the
/// gate held back for the link, and applies [`target`](Self::target) to the encoder.
#[derive(Debug, Clone)]
pub struct BitrateController {
    config: BitrateConfig,
    target: u32,
    /// (ack time, round trip) of the latest acks, oldest first.
    recent: VecDeque<(u64, u64)>,
    /// (ack time, bytes) within the delivery window.
    delivered: VecDeque<(u64, u64)>,
    /// Per-second minima of the round trip, for the windowed best.
    minima: VecDeque<(u64, u64)>,
    last_change_ns: Option<u64>,
    first_ack_ns: Option<u64>,
    /// When the gate held frames back, within `held_back_window_ns`.
    held_back_at: VecDeque<u64>,
    clear_since_ns: Option<u64>,
}

impl BitrateController {
    pub fn new(config: BitrateConfig, start: u32) -> Self {
        Self {
            config,
            target: start.clamp(config.floor, config.ceiling.max(config.floor)),
            recent: VecDeque::with_capacity(config.recent_samples + 1),
            delivered: VecDeque::new(),
            minima: VecDeque::new(),
            last_change_ns: None,
            first_ack_ns: None,
            held_back_at: VecDeque::new(),
            clear_since_ns: None,
        }
    }

    pub fn config(&self) -> &BitrateConfig {
        &self.config
    }

    /// Bits per second for the encoder.
    pub fn target(&self) -> u32 {
        self.target
    }

    /// The best round trip of the last `min_rtt_window_ns`, if any.
    pub fn min_rtt_ns(&self) -> Option<u64> {
        self.minima.iter().map(|m| m.1).min()
    }

    /// The median recent round trip above the best (ms), if there are enough samples.
    pub fn queueing_ms(&self, now: u64) -> Option<f64> {
        let mut fresh: Vec<u64> =
            self.recent.iter().filter(|r| now.wrapping_sub(r.0) <= self.config.recent_window_ns).map(|r| r.1).collect();
        if fresh.len() < 3 {
            return None;
        }
        let best = self.min_rtt_ns()?;
        fresh.sort_unstable();
        let median = fresh[fresh.len() / 2];
        Some((median - best.min(median)) as f64 / 1e6)
    }

    /// Bits per second acknowledged over the delivery window, if it holds enough acks to say. Measured over the
    /// time the link was delivering: a silence between acks longer than three times the window's median gap is
    /// a stall and counts as one median gap, so a link stall doesn't read as a slow link, while a slow link's
    /// steady acks still do.
    pub fn delivery_bps(&self, now: u64) -> Option<u64> {
        let window: Vec<(u64, u64)> = self
            .delivered
            .iter()
            .copied()
            .filter(|d| now.wrapping_sub(d.0) <= self.config.delivery_window_ns)
            .collect();
        if window.len() < 5 {
            return None;
        }
        let mut gaps: Vec<u64> = window.windows(2).map(|w| w[1].0.wrapping_sub(w[0].0)).collect();
        let span: u64 = {
            let mut sorted = gaps.clone();
            sorted.sort_unstable();
            let median = sorted[sorted.len() / 2];
            gaps.iter_mut().map(|g| if *g > 3 * median { median } else { *g }).sum()
        };
        if span == 0 {
            return None;
        }
        let bytes: u64 = window[1..].iter().map(|d| d.1).sum();
        Some((bytes as f64 * 8.0 / (span as f64 / 1e9)) as u64)
    }

    /// The gate held a frame back for the link (two already in flight): more to send than the link takes,
    /// unless the acks have stopped: a frame held back in a silence longer than twice the median gap between
    /// acks is a link stall's (a radio pause), which says nothing about capacity, and is not counted. A slow
    /// link keeps acking while it holds frames back. (Not in Swift, which counts every one: seen from the
    /// Linux host, the iPad's radio pauses held a fast link's target at the floor.)
    pub fn held_back(&mut self, now: u64) {
        if let (Some(&(last, _)), Some(gap)) = (self.delivered.back(), self.median_ack_gap(now))
            && now.wrapping_sub(last) > 2 * gap
        {
            return;
        }
        self.held_back_at.push_back(now);
        let window = self.config.held_back_window_ns;
        self.held_back_at.retain(|&t| now.wrapping_sub(t) <= window);
    }

    /// The median gap between the acks of the delivery window, if it holds at least three.
    fn median_ack_gap(&self, now: u64) -> Option<u64> {
        let times: Vec<u64> = self
            .delivered
            .iter()
            .filter(|d| now.wrapping_sub(d.0) <= self.config.delivery_window_ns)
            .map(|d| d.0)
            .collect();
        let mut gaps: Vec<u64> = times.windows(2).map(|w| w[1].wrapping_sub(w[0])).collect();
        if gaps.len() < 2 {
            return None;
        }
        gaps.sort_unstable();
        Some(gaps[gaps.len() / 2])
    }

    /// More to send than the link takes, and the link really carrying it.
    pub fn is_busy(&self, now: u64) -> bool {
        let held =
            self.held_back_at.iter().filter(|&&t| now.wrapping_sub(t) <= self.config.held_back_window_ns).count();
        held >= self.config.busy_held_back && self.delivery_bps(now).unwrap_or(0) >= self.config.busy_delivery_bps
    }

    /// One `FrameAck`: the frame's size and its send → ack round trip, acknowledged at `now`. Returns the new
    /// target when it changed.
    pub fn acked(&mut self, bytes: u64, rtt_ns: u64, now: u64) -> Option<u32> {
        self.first_ack_ns.get_or_insert(now);
        self.recent.push_back((now, rtt_ns));
        while self.recent.len() > self.config.recent_samples {
            self.recent.pop_front();
        }
        self.delivered.push_back((now, bytes));
        let window = self.config.delivery_window_ns;
        self.delivered.retain(|d| now.wrapping_sub(d.0) <= window);
        let second = now / 1_000_000_000;
        match self.minima.back_mut() {
            Some(last) if last.0 == second => last.1 = last.1.min(rtt_ns),
            _ => self.minima.push_back((second, rtt_ns)),
        }
        let window = self.config.min_rtt_window_ns;
        self.minima.retain(|m| second.wrapping_sub(m.0).saturating_mul(1_000_000_000) <= window);
        self.decide(now)
    }

    fn decide(&mut self, now: u64) -> Option<u32> {
        let queueing = self.queueing_ms(now)?;
        let c = self.config;
        let since = self.last_change_ns.map_or(u64::MAX, |t| now.wrapping_sub(t));
        let warm = self.first_ack_ns.is_some_and(|t| now.wrapping_sub(t) >= c.warmup_ns);
        let delivery = self.delivery_bps(now);
        let target = f64::from(self.target);
        // Saturated: frames held back while the link delivers under 90% of the target. Not from the round trips
        // alone: when every frame is big, each one's transfer time is in the best round trip too.
        let busy = self.is_busy(now);
        let saturated = busy && delivery.is_some_and(|d| (d as f64) < target * 0.9);
        if saturated || (busy && queueing > c.congested_ms) {
            self.clear_since_ns = None;
            // Down only once warm: the session's first keyframe burst isn't the link's capacity.
            if !warm || since < c.decrease_interval_ns {
                return None;
            }
            // To 90% of what the link delivered, but at most `max_step` lower per step.
            let by_delivery = delivery.map_or(target * c.decrease, |d| d as f64 * 0.9);
            let lowered = by_delivery.max(target * c.max_step).min(target * c.decrease);
            return self.set((lowered as u32).max(c.floor), now);
        }
        // Up while nothing queues and nothing was held back lately, busy or not (probing): a quiet link at a low
        // target makes small frames that never fill it. A target too high comes down once frames back up.
        // (Swift waits for no frame held back at all; a pause's first frame or two are held while the acks
        // are still due, so here: not busy.)
        if queueing >= c.clear_ms || busy {
            self.clear_since_ns = None;
            return None;
        }
        let clear_since = *self.clear_since_ns.get_or_insert(now);
        if now.wrapping_sub(clear_since) < c.increase_interval_ns || since < c.increase_interval_ns {
            return None;
        }
        self.set(((target * c.increase) as u32).min(c.ceiling), now)
    }

    fn set(&mut self, new: u32, now: u64) -> Option<u32> {
        if new == self.target {
            return None;
        }
        self.target = new;
        self.last_change_ns = Some(now);
        self.clear_since_ns = None;
        Some(new)
    }
}

#[cfg(test)]
mod tests {
    //! Swift: `BitrateControllerTests`: traces of acks through simulated links.
    use super::*;

    const MS: u64 = 1_000_000;

    #[derive(Default)]
    struct Counts {
        sent: usize,
        held: usize,
    }

    /// A simulated link (Swift: `run`).
    struct Link {
        seconds: f64,
        capacity_bps: f64,
        base_ms: f64,
        fps: f64,
        start: u64,
        stall_every_ms: Option<f64>,
        stall_ms: f64,
        max_in_flight: usize,
        trace: bool,
    }

    impl Link {
        fn new(seconds: f64, capacity_bps: f64) -> Self {
            Self {
                seconds,
                capacity_bps,
                base_ms: 8.0,
                fps: 60.0,
                start: 0,
                stall_every_ms: None,
                stall_ms: 270.0,
                max_in_flight: 2,
                trace: false,
            }
        }

        /// A frame offered every 1/fps, as the host's gate sends them: at most `max_in_flight` unacknowledged,
        /// the others held back. Each frame is target / fps bytes. Returns the end time.
        fn run(&self, c: &mut BitrateController, counts: &mut Counts) -> u64 {
            let mut t = self.start;
            let mut link_free_at = self.start;
            let mut in_flight: Vec<(u64, u64, u64)> = Vec::new(); // ack at, bytes, sent at
            let interval = (1000.0 / self.fps * MS as f64) as u64;
            let end = self.start + (self.seconds * 1000.0) as u64 * MS;
            let mut next_trace = self.start;
            while t < end {
                if self.trace && t >= next_trace {
                    next_trace += 250 * MS;
                    println!(
                        "{:.2}s target {:.1} q {:?} d {:?} busy {} sent {} held {}",
                        t as f64 / 1e9,
                        c.target() as f64 / 1e6,
                        c.queueing_ms(t).map(|q| q.round()),
                        c.delivery_bps(t).map(|d| d / 100_000),
                        c.is_busy(t),
                        counts.sent,
                        counts.held
                    );
                }
                in_flight.sort_by_key(|f| f.0);
                while in_flight.first().is_some_and(|f| f.0 <= t) {
                    let (ack_at, bytes, sent_at) = in_flight.remove(0);
                    c.acked(bytes, ack_at - sent_at, ack_at);
                }
                if in_flight.len() >= self.max_in_flight {
                    counts.held += 1;
                    c.held_back(t);
                    t += interval;
                    continue;
                }
                counts.sent += 1;
                let bytes = u64::from(c.target()) / 8 / self.fps as u64;
                let mut send_start = t.max(link_free_at);
                if let Some(every) = self.stall_every_ms {
                    let phase = (send_start % (every * MS as f64) as u64) as f64 / MS as f64;
                    if phase < self.stall_ms {
                        send_start += ((self.stall_ms - phase) * MS as f64) as u64;
                    }
                }
                let transfer = ((bytes * 8) as f64 / self.capacity_bps * 1e9) as u64;
                link_free_at = send_start + transfer;
                let ack_at = link_free_at + (self.base_ms * MS as f64) as u64;
                in_flight.push((ack_at, bytes, t));
                t += interval;
            }
            t
        }
    }

    fn controller(start: u32) -> BitrateController {
        BitrateController::new(BitrateConfig::default(), start)
    }

    #[test]
    fn a_slow_link_brings_the_target_under_its_capacity() {
        let mut c = controller(60_000_000);
        Link::new(4.0, 12e6).run(&mut c, &mut Counts::default());
        assert!(c.target() <= 14_000_000, "around the capacity, probing: {}", c.target());
        assert!(c.target() >= 7_000_000, "not crushed to the floor: {}", c.target());
    }

    /// Fluidity first: once settled on a slow link (with or without a stall once a second), most frames go out.
    #[test]
    fn a_slow_link_keeps_the_frame_rate() {
        for stall in [None, Some(1000.0)] {
            let mut c = controller(60_000_000);
            let t = Link { stall_every_ms: stall, ..Link::new(6.0, 12e6) }.run(&mut c, &mut Counts::default());
            let mut last = Counts::default();
            Link { stall_every_ms: stall, start: t, ..Link::new(2.0, 12e6) }.run(&mut c, &mut last);
            let share = last.sent as f64 / (last.sent + last.held) as f64;
            let want = if stall.is_none() { 0.85 } else { 0.6 };
            assert!(share >= want, "stall {stall:?}: sent {}, held {}, target {}", last.sent, last.held, c.target());
            assert!(c.target() >= c.config().floor);
        }
    }

    #[test]
    fn a_fast_link_lets_it_climb_back_to_the_ceiling() {
        let mut c = controller(10_000_000);
        Link::new(12.0, 200e6).run(&mut c, &mut Counts::default());
        assert_eq!(c.target(), 60_000_000);
    }

    #[test]
    fn a_stall_once_a_second_isnt_congestion() {
        let mut c = controller(40_000_000);
        Link { stall_every_ms: Some(1000.0), ..Link::new(6.0, 200e6) }.run(&mut c, &mut Counts::default());
        assert!(c.target() >= 40_000_000, "{}", c.target());
    }

    /// At 6 Mb/s the encoder makes tiny frames that never fill the link: a clear link climbs anyway.
    #[test]
    fn a_quiet_clear_link_climbs_off_the_floor() {
        let mut c = controller(6_000_000);
        for i in 0..150 {
            c.acked(1_500, 9 * MS, i * 67 * MS);
        }
        assert!(c.target() >= 30_000_000, "{}", c.target());
    }

    /// The session's first keyframe and the burst behind it hold frames back and queue for a moment.
    #[test]
    fn the_startup_burst_isnt_taken_for_a_slow_link() {
        let mut c = controller(20_000_000);
        c.acked(209_000, 150 * MS, 150 * MS);
        for i in 0..20 {
            c.held_back((150 + i * 10) * MS);
        }
        for i in 1..=12 {
            c.acked(40_000, 60 * MS, (150 + i * 40) * MS);
        }
        assert_eq!(c.target(), 20_000_000);
    }

    /// Tiny frames at a few per second, one caught in a stall: nothing is held back, so it isn't saturated.
    #[test]
    fn a_quiet_link_with_a_stall_isnt_saturated() {
        let mut c = controller(20_000_000);
        for i in 0..60u64 {
            let rtt = if i % 7 == 0 {
                120
            } else if i % 3 == 0 {
                25
            } else {
                10
            };
            c.acked(1_200, rtt * MS, i * 70 * MS);
        }
        assert_eq!(c.target(), 20_000_000);
    }

    /// At rest, ~14 tiny frames a second, a stall once a second holding one frame back, round trips between
    /// 8 and 25 ms. Not saturated either.
    #[test]
    fn rest_with_a_stall_holding_a_frame_back_isnt_saturated() {
        let mut c = controller(20_000_000);
        for i in 0..140u64 {
            let at = i * 71 * MS;
            if i % 14 == 0 {
                c.held_back(at);
            }
            let rtt = if i % 14 == 1 { 240 } else { [8, 25, 12, 21, 9][(i % 5) as usize] };
            c.acked(1_500, rtt * MS, at + rtt * MS);
        }
        assert_eq!(c.target(), 20_000_000);
    }

    /// Seen from the Linux host (2026-11-01, both ends on Wi-Fi): a fast link whose radio pauses ~100 ms
    /// 2–4 times a second. The pauses hold frames back (two in flight), so delivery reads under the target,
    /// but the round trips stay flat: that is no slow link, and the target must not sit at the floor.
    #[test]
    fn radio_pauses_on_a_fast_link_dont_pin_the_target_to_the_floor() {
        for every in [250.0, 300.0, 500.0] {
            let mut c = controller(6_000_000);
            let link = Link {
                fps: 120.0,
                base_ms: 10.0,
                stall_every_ms: Some(every),
                stall_ms: 100.0,
                ..Link::new(10.0, 200e6)
            };
            let mut counts = Counts::default();
            link.run(&mut c, &mut counts);
            println!("pause every {every} ms: target {}, sent {}, held {}", c.target(), counts.sent, counts.held);
            assert!(c.target() >= 30_000_000, "pause every {every} ms: {}", c.target());
        }
    }

    /// The same pauses on a link that really is slow: the target still comes down to about its capacity.
    #[test]
    fn radio_pauses_on_a_slow_link_still_bring_the_target_down() {
        let mut c = controller(60_000_000);
        let link =
            Link { fps: 120.0, base_ms: 10.0, stall_every_ms: Some(300.0), stall_ms: 100.0, ..Link::new(8.0, 12e6) };
        let mut counts = Counts::default();
        link.run(&mut c, &mut counts);
        println!("slow with pauses: target {}, sent {}, held {}", c.target(), counts.sent, counts.held);
        assert!(c.target() <= 14_000_000, "{}", c.target());
    }

    #[test]
    fn it_never_leaves_the_floor_and_ceiling() {
        let mut c = controller(1);
        assert_eq!(c.target(), c.config().floor);
        Link::new(3.0, 1e6).run(&mut c, &mut Counts::default());
        assert_eq!(c.target(), c.config().floor);
        let high = controller(u32::MAX);
        assert_eq!(high.target(), high.config().ceiling);
    }

    #[test]
    fn queueing_and_delivery_are_measured() {
        let mut c = controller(20_000_000);
        for i in 0..10 {
            c.acked(50_000, (10 + (i % 2) * 40) * MS, i * 50 * MS);
        }
        let now = 9 * 50 * MS;
        assert_eq!(c.min_rtt_ns(), Some(10 * MS));
        assert_eq!(c.queueing_ms(now).map(|q| q.round() as i64), Some(40));
        assert_eq!(c.delivery_bps(now).map(|d| d / 1_000_000), Some(8)); // 10 × 50 KB over 500 ms
    }
}
