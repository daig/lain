//! The display keep-alive: lain's display outlives a session that ended because its link went away, for
//! [`HostConfig::display_keep_alive`](crate::HostConfig::display_keep_alive), so the next session of the same
//! size takes it back instead of rebuilding it.
//!
//! **Intended difference from Swift**, asked for at the bring-up (2026-11-01): when lain on the iPad leaves the
//! screen (the owner switches apps), iPadOS drops its connections at once. The Mac host then removes its
//! display at once (`HostSession.swift` has no grace), so the desktop re-lays out twice: windows jump to another
//! monitor and don't come back, and a headless desktop is left with no screen. Kept, the display stays where it
//! is, and the picture returns as soon as the iPad reconnects. It also bridges a switch between USB and Wi-Fi.
//!
//! Only a video that was stopped (the link ended, or a takeover) hands its display here. One whose capture ended
//! on its own (`StoppedByUser`, `Failed`) or whose client explicitly quit (`ReleaseAll(.disconnect)`) removes it,
//! and so does everything once the host stops. Nothing captures or encodes while the display is kept, and input
//! was already released by the session's end; power is held while a display is kept so the machine stays awake
//! during brief client app-switches, and released as soon as the display is taken, expires, or is cleared/closed.
//! At most one display exists: a kept one is either taken back or destroyed before any other is created.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use lain_platform::{DisplayBackend, DisplaySpec, PowerBackend, StreamedDisplay};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use tracing::info;

use crate::util::Power;

struct Kept<S> {
    spec: DisplaySpec,
    streamed: StreamedDisplay,
    source: S,
    generation: u64,
    expiry: JoinHandle<()>,
}

pub(crate) struct DisplayKeeper<D: DisplayBackend, P: PowerBackend> {
    display: D,
    power: Arc<Power<P>>,
    /// In milliseconds; changeable at run time (`HostSession::set_display_keep_alive`).
    keep_for: AtomicU64,
    slot: Mutex<Option<Kept<D::Source>>>,
    /// Synchronous mirror of `slot.is_some()` for `HostSession::has_kept_display()`.
    holding: AtomicBool,
    /// Set when the host stops: nothing is kept from then on.
    closed: AtomicBool,
    generation: AtomicU64,
}

impl<D: DisplayBackend, P: PowerBackend> Drop for DisplayKeeper<D, P> {
    fn drop(&mut self) {
        if let Some(kept) = self.slot.get_mut().take() {
            kept.expiry.abort();
            self.holding.store(false, Ordering::Release);
            self.power.end();
        }
    }
}

impl<D: DisplayBackend + Clone, P: PowerBackend> DisplayKeeper<D, P> {
    pub(crate) fn new(display: D, power: Arc<Power<P>>, keep_for: Duration) -> Arc<Self> {
        Arc::new(Self {
            display,
            power,
            keep_for: AtomicU64::new(keep_for.as_millis().try_into().unwrap_or(u64::MAX)),
            slot: Mutex::new(None),
            holding: AtomicBool::new(false),
            closed: AtomicBool::new(false),
            generation: AtomicU64::new(0),
        })
    }

    pub(crate) fn is_holding(&self) -> bool {
        self.holding.load(Ordering::Acquire)
    }

    /// The kept display if it was made for `spec` (the same iPad geometry and mode); any other kept display is
    /// removed first (awaited), so the caller may create one.
    pub(crate) async fn take(&self, spec: DisplaySpec) -> Option<(StreamedDisplay, D::Source)> {
        let kept = {
            let mut slot = self.slot.lock().await;
            let kept = slot.take()?;
            self.holding.store(false, Ordering::Release);
            kept
        };
        self.power.end();
        kept.expiry.abort();
        if kept.spec == spec && !self.closed.load(Ordering::Acquire) {
            info!(display = kept.streamed.id, "reusing the kept display");
            return Some((kept.streamed, kept.source));
        }
        info!(display = kept.streamed.id, "removing the kept display: the new session wants another");
        self.display.destroy().await;
        None
    }

    /// Keeps a display whose session's link went away. `false`: not kept (keep-alive off, or the host is
    /// stopping), and the caller removes it.
    pub(crate) async fn keep(
        self: &Arc<Self>,
        spec: DisplaySpec,
        streamed: StreamedDisplay,
        source: D::Source,
    ) -> bool {
        let keep_for = self.keep_for();
        if keep_for.is_zero() {
            return false;
        }
        let mut slot = self.slot.lock().await;
        // Checked under the lock `clear` takes after setting it: either this sees it, or `clear` sees the kept
        // display.
        if self.closed.load(Ordering::Acquire) {
            return false;
        }
        let had_old = if let Some(old) = slot.take() {
            // Not expected (one display at a time), but never lose track of one.
            old.expiry.abort();
            self.display.destroy().await;
            true
        } else {
            false
        };
        let generation = self.generation.fetch_add(1, Ordering::Relaxed) + 1;
        let this = Arc::downgrade(self);
        let expiry = tokio::spawn(async move {
            tokio::time::sleep(keep_for).await;
            if let Some(this) = this.upgrade() {
                this.expire(generation).await;
            }
        });
        info!(display = streamed.id, seconds = keep_for.as_secs_f64(), "keeping lain's display for the iPad's return");
        *slot = Some(Kept { spec, streamed, source, generation, expiry });
        self.holding.store(true, Ordering::Release);
        if !had_old {
            self.power.begin();
        }
        true
    }

    async fn expire(&self, generation: u64) {
        let kept = {
            let mut slot = self.slot.lock().await;
            if slot.as_ref().is_some_and(|k| k.generation == generation) {
                self.holding.store(false, Ordering::Release);
                slot.take()
            } else {
                None
            }
        };
        if let Some(kept) = kept {
            self.power.end();
            info!(display = kept.streamed.id, "the iPad didn't come back in time; removing lain's display");
            self.display.destroy().await;
        }
    }

    pub(crate) fn keep_for(&self) -> Duration {
        Duration::from_millis(self.keep_for.load(Ordering::Relaxed))
    }

    /// A new keep-alive, for the next display kept (one kept now keeps its time).
    pub(crate) fn set_keep_for(&self, keep_for: Duration) {
        self.keep_for.store(keep_for.as_millis().try_into().unwrap_or(u64::MAX), Ordering::Relaxed);
    }

    /// The host is stopping: nothing is kept from now on (synchronous, for `stop` and `Drop`).
    pub(crate) fn close(&self) {
        self.closed.store(true, Ordering::Release);
    }

    /// Removes a kept display, if any (awaited).
    pub(crate) async fn clear(&self) {
        let kept = {
            let mut slot = self.slot.lock().await;
            let kept = slot.take();
            if kept.is_some() {
                self.holding.store(false, Ordering::Release);
            }
            kept
        };
        if let Some(kept) = kept {
            self.power.end();
            kept.expiry.abort();
            self.display.destroy().await;
        }
    }
}
