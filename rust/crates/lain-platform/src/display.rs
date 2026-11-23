//! The iPad's display and the desktop around it (Swift: `StreamedDisplayProvider`, `DisplayProvider`,
//! `ActiveDisplaySource`).

use std::future::Future;

use tokio::sync::watch;

use crate::{PointF, RectF, Result};

/// How the host places the streamed display (v8 `Hello.desiredDisplayMode` / `HelloAck.displayMode`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum DisplayMode {
    /// Virtual display alongside any physical monitors.
    #[default]
    Extend,
    /// Virtual display at the client's size/scale taking over from physical monitors (Swift: mirroring physical
    /// displays onto lain's virtual display; GNOME: temporarily disabling physical monitors until teardown).
    Primary,
    /// Stream the host's own configured primary physical display as-is (falls back to `Extend` when headless).
    CaptureExisting,
}

/// The maximum pixel dimension on the long side when capturing an existing physical display (Swift:
/// `VirtualDisplay.Spec.maxBackingPixels`). Monitors at or below this stream 1:1; larger monitors (e.g.
/// dual-4K ultrawides or 5K displays) are downscaled proportionally with even sides.
pub const MAX_CAPTURE_SIDE: u32 = 3840;

/// Caps a physical display's pixel dimensions to [`MAX_CAPTURE_SIDE`] on the long side, preserving aspect ratio
/// with even sides (Swift: `VirtualDisplay.cappedCaptureSize`).
pub fn capped_capture_size(pixel_width: u32, pixel_height: u32) -> (u32, u32) {
    let max_side = pixel_width.max(pixel_height);
    if max_side == 0 {
        return (2, 2);
    }
    if max_side <= MAX_CAPTURE_SIDE {
        return ((pixel_width & !1).max(2), (pixel_height & !1).max(2));
    }
    let ratio = f64::from(MAX_CAPTURE_SIDE) / f64::from(max_side);
    let even = |v: f64| ((v.round() as u32) & !1).max(2);
    (even(f64::from(pixel_width) * ratio), even(f64::from(pixel_height) * ratio))
}

/// The mode of the display lain creates for the iPad. The Mac host uses a fixed spec (the 13" iPad Pro's
/// 2752×2064 px at 2× and 120 Hz, `VirtualDisplay.Spec`); the core here derives it from the client's
/// `Hello`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DisplaySpec {
    pub pixel_width: u32,
    pub pixel_height: u32,
    /// Device pixels per logical pixel when the client asks for no scale: 2, the host's own (the owner's
    /// scale setting, where the platform has one, replaces it).
    pub scale: u32,
    /// The scale the client chose (v7 `Hello.desiredScale`), in hundredths, exactly as the display must be
    /// made (the core sizes the display so the desktop can apply it); 0: none, `scale` (or the owner's setting)
    /// applies. Part of the spec, so a display kept for one scale isn't reused for another.
    pub desired_scale: u16,
    pub refresh_hz: u32,
    /// How the display is placed on the host (v8 `Hello.desiredDisplayMode`). Part of the spec, so a display
    /// kept for one mode isn't reused for another.
    pub mode: DisplayMode,
}

impl DisplaySpec {
    /// The size in logical pixels: the client's cursor space for this display.
    pub fn logical_size(&self) -> (f64, f64) {
        let scale =
            if self.desired_scale > 0 { f64::from(self.desired_scale) / 100.0 } else { f64::from(self.scale.max(1)) };
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

/// The display lain streams (Swift: `StreamedDisplay`). Its current bounds are its entry in
/// [`DisplayBackend::monitors`]: the owner may move it at any time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamedDisplay {
    /// Its [`Monitor::id`].
    pub id: u32,
    /// The encode size in pixels (the display's mode, or capped by [`capped_capture_size`] for `CaptureExisting`).
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub refresh_hz: u32,
    /// How this display is placed on the host (v8 `HelloAck.displayMode`).
    pub mode: DisplayMode,
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
    /// for it. An `Err` likewise leaves nothing behind, so the caller doesn't `destroy` after one.
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

    /// lain's display's scale now (device pixels per logical pixel), if it exists and the platform scales it
    /// (v7 `HelloAck.displayScale`). `None` by default: the platform makes its display at the spec's scale only.
    fn applied_scale(&self) -> Option<f64> {
        None
    }

    /// Restores any physical host displays hidden or mirrored by lain (Swift: `VirtualDisplay.restoreHostDisplays`).
    /// Idempotent; safe on quit or emergency "Return to Host Display".
    fn restore_host_displays(&self) -> impl Future<Output = ()> + Send {
        async {}
    }

    /// True if physical host displays are currently hidden or mirrored for lain (Swift:
    /// `VirtualDisplay.hasMirroredHostDisplay`).
    fn has_hidden_host_displays(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn logical_size() {
        let spec = DisplaySpec {
            pixel_width: 2752,
            pixel_height: 2064,
            scale: 2,
            desired_scale: 0,
            refresh_hz: 120,
            mode: DisplayMode::Extend,
        };
        assert_eq!(spec.logical_size(), (1376.0, 1032.0));
        let unscaled = DisplaySpec { scale: 0, ..spec };
        assert_eq!(unscaled.logical_size(), (2752.0, 2064.0));
        let chosen = DisplaySpec { pixel_width: 2850, pixel_height: 2004, desired_scale: 300, ..spec };
        assert_eq!(chosen.logical_size(), (950.0, 668.0));
    }

    #[test]
    fn capped_capture_size_scales_above_max_with_even_sides() {
        assert_eq!(capped_capture_size(3840, 2160), (3840, 2160));
        assert_eq!(capped_capture_size(2560, 1440), (2560, 1440));
        assert_eq!(capped_capture_size(1921, 1081), (1920, 1080));
        assert_eq!(capped_capture_size(7680, 2160), (3840, 1080));
        assert_eq!(capped_capture_size(5120, 2880), (3840, 2160));
        assert_eq!(capped_capture_size(2160, 5120), (1620, 3840));
        assert_eq!(capped_capture_size(0, 0), (2, 2));
    }
}
