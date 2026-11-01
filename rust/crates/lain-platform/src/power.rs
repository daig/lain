//! Keeping the desktop awake while an iPad is connected (Swift: `PowerAssertions`).

/// Display-sleep prevention and user activity.
pub trait PowerBackend: Send + Sync + 'static {
    /// Keep the display awake and the machine from idling to sleep (`true`), or stop doing so. The core
    /// counts sessions (a takeover begins before the session it displaces ends, Swift's
    /// `PowerAssertionCount`) and calls this only when the count crosses zero.
    fn set_awake(&self, awake: bool);

    /// Injected input counts as user activity: reset the idle timers. The core throttles the calls.
    fn user_activity(&self);
}
