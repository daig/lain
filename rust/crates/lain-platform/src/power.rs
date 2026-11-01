//! Keeping the desktop awake while an iPad is connected (Swift: `PowerAssertions`).

/// Display-sleep prevention and user activity.
pub trait PowerBackend: Send + Sync + 'static {
    /// Keep the display awake and the machine from idling to sleep (`true`), or stop doing so. The core
    /// counts sessions (a takeover begins before the session it displaces ends, Swift's
    /// `PowerAssertionCount`) and calls this only when the count crosses zero.
    fn set_awake(&self, awake: bool);

    /// Injected input counts as user activity: reset the idle timers. The core throttles the calls. A
    /// platform where injected input already resets them may do nothing here (GNOME: Mutter's idle monitor
    /// resets on injected motion, scrolling and keys, observed 2026-10-31).
    fn user_activity(&self);
}
