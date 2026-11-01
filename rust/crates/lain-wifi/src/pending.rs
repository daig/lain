//! The listener's handshake caps and drop reports. Swift: `PendingHandshakes`, `DropReports`
//! (`NetworkStream.swift`).

use std::collections::VecDeque;
use std::time::Duration;

/// A listener's handshakes in progress, oldest first, within `limit` in total and `per_host` per remote
/// address. Admitting one past a cap evicts the oldest from the same address, else the oldest overall: a
/// flood of idle connections evicts its own, and a real client, done in milliseconds, goes only if a flood
/// outpaces its handshake. (Refusing the newest instead would let a few idle connections a second keep
/// everyone out.) Keys are admission numbers, never reused. Swift: `PendingHandshakes`.
#[derive(Debug)]
pub(crate) struct PendingHandshakes<T> {
    limit: usize,
    per_host: usize,
    entries: VecDeque<(u64, String, T)>,
    last_key: u64,
}

impl<T> PendingHandshakes<T> {
    /// Caps of 0 are raised to 1: they must admit something (Swift: a precondition).
    pub fn new(limit: usize, per_host: usize) -> Self {
        Self { limit: limit.max(1), per_host: per_host.max(1), entries: VecDeque::new(), last_key: 0 }
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn count_from(&self, host: &str) -> usize {
        self.entries.iter().filter(|(_, h, _)| h == host).count()
    }

    /// The key [`admit`](Self::admit) gives next.
    pub fn next_key(&self) -> u64 {
        self.last_key + 1
    }

    /// Admits `item` from `host`: its key, and what it evicted, oldest first.
    pub fn admit(&mut self, item: T, host: &str) -> (u64, Vec<T>) {
        let mut evicted = Vec::new();
        while self.count_from(host) >= self.per_host || self.entries.len() >= self.limit {
            let index = self.entries.iter().position(|(_, h, _)| h == host).unwrap_or(0);
            match self.entries.remove(index) {
                Some((_, _, item)) => evicted.push(item),
                None => break,
            }
        }
        self.last_key += 1;
        self.entries.push_back((self.last_key, host.to_owned(), item));
        (self.last_key, evicted)
    }

    /// The item admitted under `key`; `None` once evicted or removed.
    pub fn remove(&mut self, key: u64) -> Option<T> {
        let index = self.entries.iter().position(|(k, _, _)| *k == key)?;
        self.entries.remove(index).map(|(_, _, item)| item)
    }

    pub fn remove_all(&mut self) -> Vec<T> {
        self.entries.drain(..).map(|(_, _, item)| item).collect()
    }
}

/// What a listener says about the connections it drops before handover, so that a flood can't flood the
/// log or the event consumer: at most [`LIMIT`](Self::LIMIT) failed handshakes a [`WINDOW`](Self::WINDOW)
/// are reported one by one; the rest, like every eviction, are only counted, and one summary follows a
/// window after the first of them. Swift: `DropReports`.
#[derive(Debug, Default)]
pub(crate) struct DropReports {
    window_start: Option<u64>,
    reported: usize,
    unreported: usize,
    evicted: usize,
    summary_scheduled: bool,
}

impl DropReports {
    pub const LIMIT: usize = 5;
    pub const WINDOW: Duration = Duration::from_secs(1);

    /// A handshake failed at `now` (ns): whether to report it, and whether to schedule the summary.
    pub fn rejected(&mut self, now: u64) -> (bool, bool) {
        if self.window_start.is_none_or(|start| now.wrapping_sub(start) >= Self::WINDOW.as_nanos() as u64) {
            self.window_start = Some(now);
            self.reported = 0;
        }
        if self.reported < Self::LIMIT {
            self.reported += 1;
            return (true, false);
        }
        self.unreported += 1;
        (false, self.summary_due())
    }

    /// `count` pending handshakes were evicted: whether to schedule the summary.
    pub fn evicted(&mut self, count: usize) -> bool {
        if count == 0 {
            return false;
        }
        self.evicted += count;
        self.summary_due()
    }

    /// The counts since the last summary (unreported, evicted), reset.
    pub fn take_summary(&mut self) -> (usize, usize) {
        let counts = (self.unreported, self.evicted);
        (self.unreported, self.evicted, self.summary_scheduled) = (0, 0, false);
        counts
    }

    /// True for the first count since the last summary.
    fn summary_due(&mut self) -> bool {
        !std::mem::replace(&mut self.summary_scheduled, true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Swift: `NetworkStreamPolicy.pendingHandshakesEvictTheOldestOfTheSameAddressFirst`.
    #[test]
    fn pending_handshakes_evict_the_oldest_of_the_same_address_first() {
        let mut pending = PendingHandshakes::new(4, 2);
        let one = pending.admit(1, "a");
        let two = pending.admit(2, "a");
        assert!(one.1.is_empty() && two.1.is_empty() && two.0 > one.0);
        let three = pending.admit(3, "a");
        let four = pending.admit(4, "b");
        let five = pending.admit(5, "c");
        assert_eq!(three.1, vec![1]); // a at its cap: a's oldest goes
        assert!(four.1.is_empty() && five.1.is_empty() && pending.len() == 4);
        let six = pending.admit(6, "c");
        let seven = pending.admit(7, "d");
        assert_eq!(six.1, vec![5]); // at the total cap: the same address first
        assert_eq!(seven.1, vec![2]); // an address with none waiting: the oldest overall
        assert!(pending.len() == 4 && pending.count_from("a") == 1 && pending.count_from("d") == 1);
        let removed: Vec<_> = [one.0, five.0, seven.0, seven.0].iter().map(|&k| pending.remove(k)).collect();
        assert_eq!(removed, vec![None, None, Some(7), None]); // evicted or removed: gone for good
        let eight = pending.admit(8, "d");
        assert!(eight.1.is_empty() && eight.0 > seven.0); // keys are never reused
        assert_eq!(pending.remove_all(), vec![3, 4, 6, 8]);
        assert_eq!(pending.len(), 0);
    }

    /// Swift: `NetworkStreamPolicy.aFloodEvictsItsOwnConnectionsFirst`.
    #[test]
    fn a_flood_evicts_its_own_connections_first() {
        let mut pending = PendingHandshakes::new(32, 8);
        pending.admit("iPad", "fe80::1%wlan0");
        // One address, or a few that each keep connections waiting, only ever evict their own.
        let evicted: Vec<_> = (0..1_000).flat_map(|i| pending.admit("idle", &format!("attacker{}", i % 4)).1).collect();
        assert!(evicted.len() == 1_000 - 31 && !evicted.contains(&"iPad"));
        assert!(pending.len() == 32 && pending.count_from("fe80::1%wlan0") == 1);
        // A fresh address per connection reaches the oldest overall, but only after the total cap's worth of
        // newer connections: a real client is done long before.
        let mut fresh = PendingHandshakes::new(32, 8);
        fresh.admit("iPad", "fe80::1%wlan0");
        let early: Vec<_> = (0..31).flat_map(|i| fresh.admit("idle", &format!("fresh{i}")).1).collect();
        let late = fresh.admit("idle", "fresh31").1;
        assert!(early.is_empty() && late == vec!["iPad"]);
    }

    /// Swift: `NetworkStreamPolicy.dropReportsAreRateLimitedAndSummedUp`.
    #[test]
    fn drop_reports_are_rate_limited_and_summed_up() {
        let mut reports = DropReports::default();
        let window = DropReports::WINDOW.as_nanos() as u64;
        let first: Vec<_> = (0..DropReports::LIMIT as u64).map(|i| reports.rejected(1_000 + i)).collect();
        assert!(first.iter().all(|&(report, summarize)| report && !summarize));
        let over = reports.rejected(2_000);
        let again = reports.rejected(3_000);
        assert_eq!(over, (false, true)); // counted; the first count schedules the one summary
        assert_eq!(again, (false, false));
        assert_eq!([reports.evicted(3), reports.evicted(0)], [false, false]); // into the scheduled summary
        assert_eq!(reports.take_summary(), (2, 3));
        // The next window reports again; the next count schedules the next summary.
        let next_window = reports.rejected(1_000 + window);
        let next_eviction = reports.evicted(1);
        assert!(next_window.0 && next_eviction);
        assert_eq!(reports.take_summary(), (0, 1));
    }
}
