//! The iPad's display and the desktop around it (Swift: `StreamedDisplayProvider`, `DisplayProvider`,
//! `ActiveDisplaySource`).

use std::future::Future;

use tokio::sync::watch;

use crate::{PointF, RectF, Result};

/// The mode of the display lain creates for the iPad. The Mac host uses a fixed spec (the 13" iPad Pro's
/// 2752×2064 px at 2× and 120 Hz, `VirtualDisplay.Spec`); the core here derives it from the client's
/// `Hello`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DisplaySpec {
    pub pixel_width: u32,
    pub pixel_height: u32,
    /// Device pixels per logical pixel (2 on an iPad).
    pub scale: u32,
    pub refresh_hz: u32,
}

impl DisplaySpec {
    /// The size in logical pixels: the client's cursor space for this display.
    pub fn logical_size(&self) -> (f64, f64) {
        let scale = f64::from(self.scale.max(1));
        (f64::from(self.pixel_width) / scale, f64::from(self.pixel_height) / scale)
    }
}

/// One monitor of the desktop (Swift: `ActiveDisplay`).
#[derive(Debug, Clone, PartialEq)]
pub struct Monitor {
    /// Stable while the monitor exists, and never reused for another monitor during a host's run. The
    /// core sends it as `DisplayLayout.Display.displayID`.
    pub id: u32,
    /// Global logical pixels. The origin of the global space is the platform's; the core never moves
    /// monitors (Swift §5.1: lain never sets an origin in Extend mode).
    pub bounds: RectF,
    /// The desktop's primary monitor (Swift: the main display).
    pub primary: bool,
    /// lain's own display for the iPad.
    pub lain: bool,
}

/// The display lain created (Swift: `StreamedDisplay`). Its current bounds are its entry in
/// [`DisplayBackend::monitors`]: the owner may move it at any time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamedDisplay {
    /// Its [`Monitor::id`].
    pub id: u32,
    /// The capture and encode size: the display's mode in device pixels.
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub refresh_hz: u32,
}

/// Creates and removes the iPad's display, and reports the desktop around it.
pub trait DisplayBackend: Send + Sync + 'static {
    /// What a video backend captures to stream the display (on GNOME: its PipeWire node).
    type Source: Clone + Send + Sync + 'static;

    /// Creates the display and returns once it is active in `spec`'s mode and listed by
    /// [`monitors`](Self::monitors). One display at a time: creating another before
    /// [`destroy`](Self::destroy) fails. A platform whose display only takes a mode once it is captured
    /// (GNOME's `RecordVirtual`: the PipeWire consumer's format sets the mode) settles that itself before
    /// returning. It also places the display where the owner last arranged it, at the spec's scale.
    ///
    /// Cancel-safe: if the future is dropped before it completes, the backend removes whatever it had
    /// created by then (Swift: `HostVideoPipeline.abandonStart`), and a later `create` isn't refused
    /// for it.
    fn create(&self, spec: DisplaySpec) -> impl Future<Output = Result<(StreamedDisplay, Self::Source)>> + Send;

    /// Removes the display and returns once it has left the monitor list (Swift: `destroy` followed by
    /// `waitUntilRemoved`), so the next session's display can't collide with it. Idempotent. The
    /// removal completes even if this future is dropped.
    fn destroy(&self) -> impl Future<Output = ()> + Send;

    /// Every monitor, updated on each change: arrangement, mode, hotplug, lain's own display.
    fn monitors(&self) -> watch::Receiver<Vec<Monitor>>;

    /// The real cursor in global logical pixels, if the platform can tell (Swift:
    /// `DisplayProvider.cursorLocation`). Sampled about 60 times a second for warp detection; never
    /// blocks. GNOME can tell only while the pointer is on lain's display, from the stream's cursor
    /// metadata, so warps elsewhere go undetected there: a documented difference from the Mac host.
    fn cursor_location(&self) -> Option<PointF>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn logical_size() {
        let spec = DisplaySpec { pixel_width: 2752, pixel_height: 2064, scale: 2, refresh_hz: 120 };
        assert_eq!(spec.logical_size(), (1376.0, 1032.0));
        let unscaled = DisplaySpec { scale: 0, ..spec };
        assert_eq!(unscaled.logical_size(), (2752.0, 2064.0));
    }
}
