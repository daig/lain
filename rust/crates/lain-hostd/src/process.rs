//! The process's own setup, before the runtime exists: the video environment re-exec and the open-file limit.
//! The decisions are pure functions, so that they are tested; `main` applies them.

/// Set in the re-exec'd process's environment, so that the re-exec happens once only.
pub const REEXEC_MARKER: &str = "LAIN_HOSTD_REEXECED";

/// What to do about the video environment pin (`lain_linux_video::check_environment`). No Swift counterpart:
/// macOS has one GPU stack.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnvironmentPlan {
    /// The pins hold: go on.
    Ready,
    /// Re-exec `/proc/self/exe` with the same arguments and these variables added (and [`REEXEC_MARKER`]).
    Reexec(Vec<(String, String)>),
    /// Go on without the pins, logging this warning: video will refuse to start with the check's own text,
    /// which `lain-host` reports to the iPad as `HostSetup.videoProblem`.
    GoOn(String),
}

/// The decision, from the check's result, whether this process is already the re-exec, and what
/// `LinuxVideo::required_environment()` says to set.
pub fn environment_plan(
    check: Result<(), String>,
    reexeced: bool,
    required: impl FnOnce() -> Result<Vec<(String, String)>, String>,
) -> EnvironmentPlan {
    let Err(why) = check else { return EnvironmentPlan::Ready };
    if reexeced {
        return EnvironmentPlan::GoOn(format!("the video environment is still wrong after re-executing: {why}"));
    }
    match required() {
        Ok(pairs) if !pairs.is_empty() => EnvironmentPlan::Reexec(pairs),
        Ok(_) => EnvironmentPlan::GoOn(format!("{why} (and nothing is known to set)")),
        Err(e) => EnvironmentPlan::GoOn(format!("{why}; the pins can't be set: {e}")),
    }
}

/// The soft `RLIMIT_NOFILE` to set, if it should be raised: `wanted`, or the hard limit if lower, never lowering
/// the current one. `None` (in a limit) is unlimited. Swift: `LainHostEntry.raiseOpenFileLimit` (4096).
pub fn raised_open_file_limit(soft: Option<u64>, hard: Option<u64>, wanted: u64) -> Option<u64> {
    let target = hard.map_or(wanted, |h| h.min(wanted));
    match soft {
        Some(current) if current < target => Some(target),
        _ => None,
    }
}

/// What Swift raises the limit to.
pub const OPEN_FILES_WANTED: u64 = 4096;

/// Raises this process's open-file limit as [`raised_open_file_limit`] says. Returns the new soft limit, `Ok(None)`
/// when nothing needed changing. Every USB dial opens a socket to usbmuxd and every Wi-Fi connection one of
/// its own, so a flood of unauthenticated Wi-Fi handshakes mustn't starve the USB path (Swift's reason).
pub fn raise_open_file_limit() -> std::io::Result<Option<u64>> {
    use rustix::process::{Resource, getrlimit, setrlimit};
    let limit = getrlimit(Resource::Nofile);
    let Some(target) = raised_open_file_limit(limit.current, limit.maximum, OPEN_FILES_WANTED) else {
        return Ok(None);
    };
    setrlimit(Resource::Nofile, rustix::process::Rlimit { current: Some(target), maximum: limit.maximum })?;
    Ok(Some(target))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pins() -> Result<Vec<(String, String)>, String> {
        Ok(vec![("__EGL_VENDOR_LIBRARY_FILENAMES".into(), "/x/50_mesa.json".into())])
    }

    #[test]
    fn the_reexec_happens_once_and_only_when_needed() {
        assert_eq!(environment_plan(Ok(()), false, || panic!("not asked")), EnvironmentPlan::Ready);
        assert_eq!(environment_plan(Ok(()), true, || panic!("not asked")), EnvironmentPlan::Ready);
        assert_eq!(environment_plan(Err("unset".into()), false, pins), EnvironmentPlan::Reexec(pins().unwrap()));
        let EnvironmentPlan::GoOn(why) = environment_plan(Err("unset".into()), true, || panic!("not asked")) else {
            panic!()
        };
        assert!(why.contains("still wrong after re-executing: unset"), "{why}");
        let EnvironmentPlan::GoOn(why) = environment_plan(Err("unset".into()), false, || Err("no Mesa".into())) else {
            panic!()
        };
        assert!(why.contains("unset") && why.contains("no Mesa"), "{why}");
        assert!(matches!(environment_plan(Err("x".into()), false, || Ok(vec![])), EnvironmentPlan::GoOn(_)));
    }

    #[test]
    fn the_open_file_limit_only_rises() {
        // systemd's default soft limit is 1024 under a hard limit of 524288.
        assert_eq!(raised_open_file_limit(Some(1024), Some(524_288), 4096), Some(4096));
        assert_eq!(raised_open_file_limit(Some(256), Some(2048), 4096), Some(2048), "capped by the hard limit");
        assert_eq!(raised_open_file_limit(Some(8192), Some(524_288), 4096), None, "never lowered");
        assert_eq!(raised_open_file_limit(Some(4096), None, 4096), None);
        assert_eq!(raised_open_file_limit(None, None, 4096), None, "unlimited stays");
        assert_eq!(raised_open_file_limit(Some(100), None, 4096), Some(4096));
        assert_eq!(raised_open_file_limit(Some(2048), Some(2048), 4096), None);
    }

    #[test]
    fn raising_works_here() {
        // Only raises, so it is harmless in the test process.
        let before = rustix::process::getrlimit(rustix::process::Resource::Nofile);
        raise_open_file_limit().unwrap();
        let after = rustix::process::getrlimit(rustix::process::Resource::Nofile);
        assert_eq!(after.maximum, before.maximum);
        // (`None`, unlimited, stays `None`; a finite limit only rises.)
        assert_eq!(after.current.is_none(), before.current.is_none());
        assert!(after.current >= before.current);
    }
}
