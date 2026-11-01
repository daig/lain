//! The setup report's GNOME part (v4 `HostSetup`; Swift: `HostSetupProbe`).
//!
//! **Difference from Swift:** Swift reports Screen Recording, Accessibility and Start at Login. On GNOME none
//! of the first two applies: Mutter's ScreenCast and RemoteDesktop take no consent from a process in the
//! user's session (decision L2), so there's nothing for the owner to allow, and a capture or injection that
//! fails is a video or input failure, reported as `videoProblem` by the core. Start at Login belongs to
//! `lain-linux-system` (its systemd unit), and the daemon adds it. So this reports no items, only
//! `has_other_display`.

use std::sync::Arc;

use lain_platform::{SetupReport, SetupSource};
use tokio::sync::watch;

use crate::desktop::Desktop;

/// The setup source: cheap, from the desktop the monitor task keeps current.
#[derive(Debug, Clone)]
pub struct GnomeSetup {
    desktop: watch::Receiver<Arc<Desktop>>,
}

impl GnomeSetup {
    /// Reads `has_other_display` from the desktop that `monitors::spawn` publishes.
    pub fn new(desktop: watch::Receiver<Arc<Desktop>>) -> Self {
        Self { desktop }
    }
}

impl SetupSource for GnomeSetup {
    fn setup(&self) -> SetupReport {
        SetupReport { items: Vec::new(), has_other_display: self.desktop.borrow().has_other_display() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop::{IdMap, build};
    use crate::display_config::{parse_state, tests::reference_raw};

    #[test]
    fn reports_only_whether_a_real_monitor_exists() {
        let mut state = parse_state(reference_raw(2.0));
        let d = build(&state, Some("Meta-0"), &mut IdMap::default());
        let (tx, rx) = watch::channel(Arc::new(d));
        let setup = GnomeSetup::new(rx);
        assert_eq!(setup.setup(), SetupReport { items: vec![], has_other_display: true });
        state.logical.remove(0);
        tx.send_replace(Arc::new(build(&state, Some("Meta-0"), &mut IdMap::default())));
        assert!(!setup.setup().has_other_display);
    }
}
