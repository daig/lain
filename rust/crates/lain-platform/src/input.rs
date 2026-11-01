//! Input injection (Swift: `InputSink`).
//!
//! The Swift sink received the client's input messages and decided itself what macOS saw. Here
//! `lain-input` decides (key mapping, explicit modifier keys, repeats, scroll and pinch policy) and
//! tracks what is held; the backend only performs [`InputAction`]s.

/// Which kind of device a scroll comes from. It decides how toolkits treat the deltas, and whether they add
/// kinetic scrolling of their own after an [`InputAction::ScrollStop`]. Which source `lain-input` sends for the
/// client's scrolls (and whether it forwards the client's synthesized momentum) is open spike 4's question.
///
/// Observed with GTK 4 on GNOME 50 through Mutter's `NotifyPointerAxis` (spike B, 2026-10-31).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScrollSource {
    /// A notched wheel: 10 logical pixels are one detent. No begin, no end, no kinetic continuation; a
    /// stop is ignored.
    Wheel,
    /// A touchpad: toolkits begin a scroll gesture, take the deltas 1:1, and continue the scroll kinetically
    /// after the stop.
    Finger,
    /// Smooth scrolling from a device that isn't a touchpad (a trackpoint). GTK 4 takes the deltas 1:1 and,
    /// like `Finger`, still continues kinetically after the stop.
    Continuous,
}

/// One thing for the desktop to do.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum InputAction {
    /// An evdev key code (`KEY_*` in `linux/input-event-codes.h`) pressed or released.
    Key { code: u16, down: bool },
    /// Move the pointer to a global position in logical pixels, on any monitor. Getting there despite the
    /// desktop's own obstacles (GNOME Shell's panel barrier on the primary monitor's edge) is the backend's
    /// business.
    MoveTo(crate::PointF),
    /// An evdev button code (`BTN_LEFT`, `BTN_RIGHT`, `BTN_MIDDLE`, …) pressed or released.
    Button { code: u16, down: bool },
    /// Scroll by logical pixels, in Wayland's axis convention: positive `dy` scrolls down (towards the
    /// end of a document), positive `dx` right.
    Scroll { dx: f64, dy: f64, source: ScrollSource },
    /// The end of a scroll sequence on both axes (Wayland's `axis_stop`), carrying no delta: a backend sends
    /// it as its own event (Mutter drops a delta sent together with its finish flag).
    ScrollStop { source: ScrollSource },
}

/// Performs input on the desktop.
///
/// Input must keep working whether or not lain's display exists: a session whose video failed, or whose
/// capture the owner stopped, goes on with input only (Swift: `HostSession`'s input-only session). A
/// backend whose injection depends on a display (GNOME's per-stream absolute motion) keeps its own
/// streams, independent of [`DisplayBackend::create`](crate::DisplayBackend::create) and `destroy`.
pub trait InputBackend: Send + Sync + 'static {
    /// Performs `actions` in order. Called from the realtime connection's reader: never blocks or waits
    /// (queue internally if the platform call can).
    fn apply(&self, actions: &[InputAction]);
}
