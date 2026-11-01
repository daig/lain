//! The host's setup state for the client (v4 `HostSetup`; Swift: `HostSetupProbe`).
//!
//! The requirements mirror `HostSetup.Requirement`, which names macOS permissions, and the client words
//! a missing one as a Mac setting to allow. A platform reports only the items that mean something on it.

/// One thing the host may need (Swift: `HostSetup.Requirement`, in its wire order).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Requirement {
    /// Capturing the screen (macOS: Screen Recording).
    ScreenCapture,
    /// Injecting input (macOS: Accessibility).
    InputInjection,
    /// Being reachable on the local network (macOS: Local Network).
    LocalNetwork,
    /// Starting with the session.
    StartAtLogin,
}

/// Whether a requirement is met (Swift: `HostSetup.State`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RequirementState {
    Granted,
    Missing,
    /// The host can't tell.
    Unknown,
}

/// What a platform reports; the core adds why there's no video.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SetupReport {
    pub items: Vec<(Requirement, RequirementState)>,
    /// A physical monitor besides lain's display exists, where the owner can fix the setup.
    pub has_other_display: bool,
}

/// Where the core reads the setup. Cheap: called whenever the core checks for changes.
pub trait SetupSource: Send + Sync + 'static {
    fn setup(&self) -> SetupReport;
}
