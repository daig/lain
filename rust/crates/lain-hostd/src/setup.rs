//! The daemon's `SetupSource` (Swift: `HostController.probeSetup`): the platform's report (on GNOME,
//! `lain_gnome::GnomeSetup`'s `has_other_display`) plus Start at Login from the autostart unit.

use std::future::Future;

use lain_linux_system::Autostart;
use lain_platform::{Requirement, RequirementState, SetupReport, SetupSource};

/// Whether the host starts with the session, as a cache refreshed on demand. Swift reads `LoginAgent.state`
/// live on every probe; asking systemd is a D-Bus call, so the daemon polls instead.
pub trait LoginItem: Clone + Send + Sync + 'static {
    /// The last state learned (cheap, synchronous).
    fn cached(&self) -> RequirementState;
    /// Asks again, updating the cache.
    fn refresh(&self) -> impl Future<Output = ()> + Send;
}

impl LoginItem for Autostart {
    fn cached(&self) -> RequirementState {
        self.start_at_login()
    }

    async fn refresh(&self) {
        self.state().await;
    }
}

/// What the daemon polls before comparing the setup (every [`DaemonOptions::setup_poll`]).
///
/// [`DaemonOptions::setup_poll`]: crate::DaemonOptions::setup_poll
pub trait SetupRefresh: SetupSource {
    fn refresh(&self) -> impl Future<Output = ()> + Send;
}

/// The platform's report with a Start at Login item added.
///
/// Intended difference from Swift: an autostart unit that isn't installed is `Missing` (the owner can run
/// `lain autostart on`), where Swift's `.notFound` (the agent missing from the app bundle) is `unknown`; that
/// is `lain-linux-system`'s `AutostartState::requirement_state`. Swift also reports Screen Recording and
/// Accessibility, which don't apply on GNOME (`lain_gnome::setup`).
#[derive(Debug, Clone)]
pub struct DaemonSetup<S, L> {
    pub base: S,
    pub login: L,
}

impl<S, L> DaemonSetup<S, L> {
    pub fn new(base: S, login: L) -> Self {
        Self { base, login }
    }
}

impl<S: SetupSource, L: LoginItem> SetupSource for DaemonSetup<S, L> {
    fn setup(&self) -> SetupReport {
        let mut report = self.base.setup();
        report.items.retain(|(r, _)| *r != Requirement::StartAtLogin);
        report.items.push((Requirement::StartAtLogin, self.login.cached()));
        report
    }
}

impl<S: SetupSource, L: LoginItem> SetupRefresh for DaemonSetup<S, L> {
    async fn refresh(&self) {
        self.login.refresh().await
    }
}
