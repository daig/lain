//! Input injection (Swift: `InputSink`).
//!
//! The Swift sink received the client's input messages and decided itself what macOS saw. Here
//! `lain-input` decides (key mapping, explicit modifier keys, repeats, scroll and pinch policy) and
//! tracks what is held; the backend only performs [`InputAction`]s.

/// Which kind of device a scroll comes from. It decides whether the desktop adds kinetic scrolling of its
/// own after a [`InputAction::ScrollStop`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ScrollSource {
    /// A notched wheel.
    Wheel,
    /// A touchpad: toolkits may continue the scroll kinetically after the stop.
    Finger,
    /// Smooth scrolling with no kinetic continuation by the desktop.
    Continuous,
}

/// One thing for the desktop to do.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum InputAction {
    /// An evdev key code (`KEY_*` in `linux/input-event-codes.h`) pressed or released.
    Key { code: u16, down: bool },
    /// Move the pointer to a global position in logical pixels.
    MoveTo(crate::PointF),
    /// An evdev button code (`BTN_LEFT`, `BTN_RIGHT`, `BTN_MIDDLE`, …) pressed or released.
    Button { code: u16, down: bool },
    /// Scroll by logical pixels, in Wayland's axis convention: positive `dy` scrolls down (towards the
    /// end of a document), positive `dx` right.
    Scroll { dx: f64, dy: f64, source: ScrollSource },
    /// The end of a scroll sequence on both axes (Wayland's `axis_stop`).
    ScrollStop { source: ScrollSource },
}

/// Performs input on the desktop.
pub trait InputBackend: Send + Sync + 'static {
    /// Performs `actions` in order. Called from the realtime connection's reader: never blocks or waits
    /// (queue internally if the platform call can).
    fn apply(&self, actions: &[InputAction]);
}
