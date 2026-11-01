//! Monotonic time (Swift: `LainTelemetry/MonotonicClock`).
//!
//! The Mac host stamps with `CLOCK_UPTIME_RAW`; Linux uses `CLOCK_MONOTONIC`, which likewise doesn't
//! advance during suspend and is the clock PipeWire timestamps buffers with. The peer's clock is only
//! ever related to ours through Ping/Pong, so the choice of clock is local.

/// Nanoseconds of `CLOCK_MONOTONIC`.
pub fn now_ns() -> u64 {
    let ts = rustix::time::clock_gettime(rustix::time::ClockId::Monotonic);
    // CLOCK_MONOTONIC is never negative.
    (ts.tv_sec as u64) * 1_000_000_000 + ts.tv_nsec as u64
}

/// A source of monotonic nanoseconds, injected so tests can control time (Swift: `Dependencies.now`).
pub trait Clock: Send + Sync + 'static {
    fn now_ns(&self) -> u64;
}

/// The real clock: [`now_ns`].
#[derive(Debug, Clone, Copy, Default)]
pub struct MonotonicClock;

impl Clock for MonotonicClock {
    fn now_ns(&self) -> u64 {
        now_ns()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn monotonic() {
        let a = now_ns();
        let b = MonotonicClock.now_ns();
        assert!(a > 0);
        assert!(b >= a);
    }
}
