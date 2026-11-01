//! Small pieces the engine shares: cooperative cancellation, the power count, the usbmuxd dialer.

use std::sync::Arc;

use lain_link::{DialError, StreamDialer, TransportError};
use lain_platform::PowerBackend;
use lain_proto::{ConnectionKind, USB_PORT};
use lain_usbmux::UsbMuxClient;
use tokio::sync::watch;

/// Cooperative cancellation (Swift: `Task.cancel()` and `Task.isCancelled`). Cloning shares it.
///
/// Difference from Swift: tasks aren't aborted; each checks this at its await points, so a session's
/// teardown (input release, power) always runs to its end.
#[derive(Debug, Clone)]
pub(crate) struct Cancel(Arc<watch::Sender<bool>>);

impl Cancel {
    pub(crate) fn new() -> Self {
        Self(Arc::new(watch::Sender::new(false)))
    }

    pub(crate) fn cancel(&self) {
        self.0.send_replace(true);
    }

    pub(crate) fn is_cancelled(&self) -> bool {
        *self.0.borrow()
    }

    /// Returns once cancelled.
    pub(crate) async fn cancelled(&self) {
        let mut rx = self.0.subscribe();
        let _ = rx.wait_for(|c| *c).await;
    }

    /// Sleeps for `duration` unless cancelled first. Returns whether the sleep ran out (not cancelled).
    pub(crate) async fn sleep(&self, duration: std::time::Duration) -> bool {
        tokio::select! {
            () = self.cancelled() => false,
            () = tokio::time::sleep(duration) => !self.is_cancelled(),
        }
    }
}

/// Display-sleep prevention, counted (Swift: `PowerAssertionCount` inside `IOPMPowerAssertions`): each
/// session begins once and ends once, and the platform is kept awake while begins outnumber ends. A session
/// taking over (USB from Wi-Fi, or the same iPad's new Wi-Fi link) begins before the one it displaces
/// ends, so a hand-over never lets it lapse. The platform hears only the crossings of zero
/// ([`PowerBackend::set_awake`]).
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct PowerCount {
    count: usize,
}

impl PowerCount {
    pub fn count(&self) -> usize {
        self.count
    }

    /// Returns whether this begin must take the assertion (0 → 1).
    pub fn begin(&mut self) -> bool {
        self.count += 1;
        self.count == 1
    }

    /// Returns whether this end must release the assertion (1 → 0). An unmatched end changes nothing.
    pub fn end(&mut self) -> bool {
        if self.count == 0 {
            return false;
        }
        self.count -= 1;
        self.count == 0
    }
}

/// [`PowerCount`] driving a [`PowerBackend`].
pub(crate) struct Power<B: PowerBackend> {
    backend: B,
    count: std::sync::Mutex<PowerCount>,
}

impl<B: PowerBackend> Power<B> {
    pub(crate) fn new(backend: B) -> Self {
        Self { backend, count: std::sync::Mutex::new(PowerCount::default()) }
    }

    pub(crate) fn begin(&self) {
        let mut c = self.count.lock().unwrap_or_else(|e| e.into_inner());
        if c.begin() {
            self.backend.set_awake(true);
        }
    }

    pub(crate) fn end(&self) {
        let mut c = self.count.lock().unwrap_or_else(|e| e.into_inner());
        if c.end() {
            self.backend.set_awake(false);
        }
    }

    pub(crate) fn user_activity(&self) {
        self.backend.user_activity();
    }
}

/// Dials lain on an attached iPad through usbmuxd: `Connect` to [`USB_PORT`] (Swift: `USBMuxDialer`).
#[derive(Debug, Clone)]
pub(crate) struct UsbMuxDialer {
    pub(crate) client: UsbMuxClient,
    pub(crate) device_id: u32,
}

impl StreamDialer for UsbMuxDialer {
    type Stream = tokio::net::UnixStream;

    async fn dial(&self, _kind: ConnectionKind) -> Result<Self::Stream, TransportError> {
        self.client.connect(self.device_id, USB_PORT).await.map_err(|e| TransportError::Dial(DialError::new(e)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Swift: `PowerAssertionCountTests.theAssertionIsHeldWhileBeginsOutnumberEnds`.
    #[test]
    fn the_assertion_is_held_while_begins_outnumber_ends() {
        let mut count = PowerCount::default();
        let steps = [count.begin(), count.begin(), count.end(), count.end(), count.end(), count.begin()];
        assert_eq!(steps, [true, false, false, true, false, true]);
        assert_eq!(count.count(), 1);
        assert!(count.end());
        assert_eq!(count.count(), 0);
    }
}
