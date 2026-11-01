//! Starting the host with the desktop session (Swift: `LoginAgent`, `LainHostCore/Service/LoginAgent.swift`).
//!
//! The Mac registers a bundled LaunchAgent with `SMAppService`; here lain installs a systemd user unit,
//! `lain-hostd.service` in `$XDG_CONFIG_HOME/systemd/user`, bound to `graphical-session.target`, and
//! enables or disables it through `org.freedesktop.systemd1`'s `Manager` on the session bus
//! (`EnableUnitFiles`, `DisableUnitFiles`, `Reload`). Like the agent, systemd restarts it after a crash
//! (`Restart=on-failure`), and a clean exit stays exited.
//!
//! Intended differences from Swift:
//! - No `requiresApproval` state: systemd asks no one.
//! - No single-instance logic (`LoginAgent.decide`, `settleInstance`): that is `lain-hostd`'s, which can own
//!   its D-Bus name to stay single.
//! - Enabling doesn't start the unit (Swift's `register` lets launchd start the agent at once): an enabled
//!   unit starts with the next session, so a host already running isn't joined by a second one.

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use lain_platform::{PlatformError, RequirementState, Result};
use tracing::{debug, info};

use crate::paths;

/// The daemon's unit name.
pub const UNIT_NAME: &str = "lain-hostd.service";

/// The target the unit is bound to.
pub const SESSION_TARGET: &str = "graphical-session.target";

/// systemd's `Reload` re-reads every unit, which can take a while.
const CALL_TIMEOUT: Duration = Duration::from_secs(30);

#[zbus::proxy(
    interface = "org.freedesktop.systemd1.Manager",
    default_service = "org.freedesktop.systemd1",
    default_path = "/org/freedesktop/systemd1"
)]
trait SystemdManager {
    fn enable_unit_files(
        &self,
        files: &[&str],
        runtime: bool,
        force: bool,
    ) -> zbus::Result<(bool, Vec<(String, String, String)>)>;
    fn disable_unit_files(&self, files: &[&str], runtime: bool) -> zbus::Result<Vec<(String, String, String)>>;
    fn reload(&self) -> zbus::Result<()>;
    fn get_unit_file_state(&self, file: &str) -> zbus::Result<String>;
}

/// Whether the host starts with the session (Swift: `LoginAgent.State`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AutostartState {
    /// Installed and enabled (Swift: `.enabled`).
    Enabled,
    /// Installed, not enabled (Swift: `.notRegistered`).
    Disabled,
    /// No unit file (Swift: `.notFound`, the plist missing from the bundle).
    NotInstalled,
    /// Another unit-file state (`masked`, `linked`, `static`, …), as systemd words it.
    Other(String),
    /// systemd couldn't be asked.
    Unknown(String),
}

impl AutostartState {
    /// For `HostSetup`'s `startAtLogin`, which `lain-hostd` puts in its `SetupSource` report.
    pub fn requirement_state(&self) -> RequirementState {
        match self {
            AutostartState::Enabled => RequirementState::Granted,
            AutostartState::Disabled | AutostartState::NotInstalled => RequirementState::Missing,
            AutostartState::Other(state) if state == "masked" || state == "masked-runtime" => RequirementState::Missing,
            AutostartState::Other(_) | AutostartState::Unknown(_) => RequirementState::Unknown,
        }
    }
}

/// What the unit runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnitFile {
    pub description: String,
    /// The program (an absolute path) and its arguments.
    pub exec_start: Vec<String>,
}

impl UnitFile {
    /// The daemon's unit running `program` (an absolute path).
    pub fn host(program: &Path) -> UnitFile {
        UnitFile {
            description: "lain host: an iPad as this computer's display".into(),
            exec_start: vec![program.to_string_lossy().into_owned()],
        }
    }

    /// The unit file's text.
    pub fn render(&self) -> String {
        let exec: Vec<String> = self.exec_start.iter().map(|a| quote(a)).collect();
        format!(
            "# Installed by lain; `lain autostart off` disables it.\n\
             [Unit]\n\
             Description={description}\n\
             PartOf={SESSION_TARGET}\n\
             After={SESSION_TARGET}\n\
             Requisite={SESSION_TARGET}\n\
             \n\
             [Service]\n\
             ExecStart={exec}\n\
             Restart=on-failure\n\
             RestartSec=2\n\
             \n\
             [Install]\n\
             WantedBy={SESSION_TARGET}\n",
            description = description(&self.description),
            exec = exec.join(" "),
        )
    }
}

/// The `Description=` value: one line (control characters become spaces), `%` specifiers doubled to stay
/// literal, and no trailing backslash, which `systemd.syntax(7)` would join with the next line (swallowing
/// `PartOf=`).
fn description(text: &str) -> String {
    let line: String = text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    line.trim_end_matches(|c: char| c == '\\' || c.is_whitespace()).replace('%', "%%")
}

/// One `ExecStart` word, quoted per `systemd.syntax(7)` and `systemd.service(5)`: `%` specifiers and `$`
/// variables are doubled to stay literal.
fn quote(word: &str) -> String {
    let safe = |c: char| c.is_ascii_alphanumeric() || "/_.,:=+@-".contains(c);
    if !word.is_empty() && word.chars().all(safe) {
        return word.to_owned();
    }
    let mut quoted = String::from("\"");
    for c in word.chars() {
        match c {
            '\\' => quoted.push_str("\\\\"),
            '"' => quoted.push_str("\\\""),
            '%' => quoted.push_str("%%"),
            '$' => quoted.push_str("$$"),
            '\n' => quoted.push_str("\\n"),
            '\t' => quoted.push_str("\\t"),
            c if c.is_control() => quoted.push_str(&format!("\\x{:02x}", c as u32)),
            c => quoted.push(c),
        }
    }
    quoted.push('"');
    quoted
}

/// The host's autostart unit, through the systemd user manager.
#[derive(Debug, Clone)]
pub struct Autostart {
    bus: zbus::Connection,
    unit_dir: PathBuf,
    unit_name: String,
    /// The last state learned, for [`start_at_login`](Self::start_at_login).
    cached: Arc<Mutex<RequirementState>>,
}

impl Autostart {
    /// `lain-hostd.service` in `$XDG_CONFIG_HOME/systemd/user`, on the session bus's systemd user manager.
    ///
    /// The manager looks in its own `$XDG_CONFIG_HOME`; if ours differs, enabling fails with systemd's
    /// "unit file not found".
    pub async fn session() -> Result<Autostart> {
        let bus =
            zbus::Connection::session().await.map_err(|e| PlatformError::Unavailable(format!("session bus: {e}")))?;
        Ok(Autostart::new(bus, &user_unit_dir(&paths::config_home()?), UNIT_NAME))
    }

    /// `unit_name` in `unit_dir`, through the systemd manager on `bus` (tests use their own name and bus).
    pub fn new(bus: zbus::Connection, unit_dir: &Path, unit_name: &str) -> Autostart {
        Autostart {
            bus,
            unit_dir: unit_dir.to_owned(),
            unit_name: unit_name.to_owned(),
            cached: Arc::new(Mutex::new(RequirementState::Unknown)),
        }
    }

    pub fn unit_path(&self) -> PathBuf {
        self.unit_dir.join(&self.unit_name)
    }

    /// The last state [`state`](Self::state), [`enable`](Self::enable) or [`disable`](Self::disable) learned
    /// (`Unknown` before any): cheap and synchronous, for a `SetupSource`.
    pub fn start_at_login(&self) -> RequirementState {
        *self.cached.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn remember(&self, state: &AutostartState) {
        *self.cached.lock().unwrap_or_else(|p| p.into_inner()) = state.requirement_state();
    }

    async fn manager(&self) -> Result<SystemdManagerProxy<'static>> {
        SystemdManagerProxy::new(&self.bus).await.map_err(|e| systemd_error("connecting", e))
    }

    /// Writes the unit file if its text differs (atomically, 0644), then reloads systemd if it changed.
    async fn install(&self, unit: &UnitFile) -> Result<bool> {
        let (path, text) = (self.unit_path(), unit.render());
        let changed = blocking(move || {
            if fs::read_to_string(&path).is_ok_and(|current| current == text) {
                return Ok(false);
            }
            let dir = path.parent().unwrap_or(Path::new("."));
            fs::create_dir_all(dir).map_err(|e| paths::io_error("creating", dir, e))?;
            paths::replace_atomically(&path, text.as_bytes(), 0o644)
                .map_err(|e| paths::io_error("writing", &path, e))?;
            Ok(true)
        })
        .await?;
        if changed {
            info!(path = %self.unit_path().display(), "installed the autostart unit");
            self.reload().await?;
        }
        Ok(changed)
    }

    async fn reload(&self) -> Result<()> {
        timed(self.manager().await?.reload()).await.map_err(|e| systemd_error("Reload", e))
    }

    /// Installs (or updates) the unit and enables it, so it starts with the next session. Doesn't start it.
    ///
    /// Our copy, in `$XDG_CONFIG_HOME/systemd/user`, takes precedence over one of the same name elsewhere
    /// on the search path (a package's); systemd refuses (`force` is false) if the target's `.wants` link
    /// already points at that other copy. Which unit is canonical is open (see the crate report).
    pub async fn enable(&self, unit: &UnitFile) -> Result<()> {
        self.install(unit).await?;
        let manager = self.manager().await?;
        let (_, changes) = timed(manager.enable_unit_files(&[self.unit_name.as_str()], false, false))
            .await
            .map_err(|e| systemd_error("EnableUnitFiles", e))?;
        debug!(?changes, "enabled the autostart unit");
        self.reload().await?;
        self.remember(&AutostartState::Enabled);
        Ok(())
    }

    /// Disables the unit (it no longer starts with the session); leaves the file. Succeeds if systemd has no
    /// such unit.
    ///
    /// systemd is always asked, by unit name, so a unit installed anywhere on the manager's search path
    /// (`~/.local/share/systemd/user`, `/usr/lib/systemd/user`, …), not only in our unit directory, is
    /// disabled too.
    pub async fn disable(&self) -> Result<()> {
        let manager = self.manager().await?;
        match timed(manager.disable_unit_files(&[self.unit_name.as_str()], false)).await {
            Ok(changes) => {
                debug!(?changes, "disabled the autostart unit");
                self.reload().await?;
                self.remember(&AutostartState::Disabled);
                Ok(())
            }
            Err(e) if is_no_such_unit(&e) => {
                debug!(error = %e, "no autostart unit to disable");
                self.remember(&AutostartState::NotInstalled);
                Ok(())
            }
            Err(e) => Err(systemd_error("DisableUnitFiles", e)),
        }
    }

    /// Disables the unit and removes its file from our unit directory. A copy installed elsewhere (by a
    /// package, say) stays, disabled; [`state`](Self::state) then reads `Disabled`.
    pub async fn uninstall(&self) -> Result<()> {
        self.disable().await?;
        let path = self.unit_path();
        let removed = blocking(move || match fs::remove_file(&path) {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(paths::io_error("removing", &path, e)),
        })
        .await?;
        if removed {
            self.reload().await?;
        }
        // Asked again rather than assumed: another copy of the unit may remain.
        self.state().await;
        Ok(())
    }

    /// The unit's state, from systemd (and so the cache for [`start_at_login`](Self::start_at_login)).
    ///
    /// Asked by unit name (Swift reads `SMAppService.status` live too), so a unit installed anywhere on the
    /// manager's search path counts, not only one in our unit directory. `NotInstalled` is systemd's own
    /// answer that it has no such unit file.
    pub async fn state(&self) -> AutostartState {
        let state = match self.manager().await {
            Err(e) => AutostartState::Unknown(e.to_string()),
            Ok(manager) => match timed(manager.get_unit_file_state(&self.unit_name)).await {
                Ok(state) => match state.as_str() {
                    "enabled" | "enabled-runtime" => AutostartState::Enabled,
                    "disabled" => AutostartState::Disabled,
                    _ => AutostartState::Other(state),
                },
                Err(e) if is_no_such_unit(&e) => AutostartState::NotInstalled,
                Err(e) => AutostartState::Unknown(systemd_error("GetUnitFileState", e).to_string()),
            },
        };
        self.remember(&state);
        state
    }
}

/// `$XDG_CONFIG_HOME/systemd/user`.
pub fn user_unit_dir(config_home: &Path) -> PathBuf {
    config_home.join("systemd/user")
}

async fn timed<T>(call: impl Future<Output = zbus::Result<T>>) -> zbus::Result<T> {
    tokio::time::timeout(CALL_TIMEOUT, call).await.unwrap_or_else(|_| Err(zbus::Error::Failure("timed out".into())))
}

async fn blocking<T: Send + 'static>(f: impl FnOnce() -> Result<T> + Send + 'static) -> Result<T> {
    tokio::task::spawn_blocking(f).await.map_err(|e| PlatformError::Failed(format!("file task: {e}")))?
}

/// systemd's answer that it has no unit file of that name: `GetUnitFileState` replies
/// `org.freedesktop.DBus.Error.FileNotFound` (seen with systemd 259, 2026-11-01); `DisableUnitFiles` replies
/// `org.freedesktop.systemd1.NoSuchUnit` ("Unit file … does not exist.", from systemd's
/// `install_changes_dump`; not run here, since it is a write) or the same `FileNotFound`.
fn is_no_such_unit(e: &zbus::Error) -> bool {
    matches!(e, zbus::Error::MethodError(name, _, _)
        if matches!(name.as_str(), "org.freedesktop.DBus.Error.FileNotFound" | "org.freedesktop.systemd1.NoSuchUnit"))
}

fn systemd_error(what: &str, e: zbus::Error) -> PlatformError {
    match &e {
        zbus::Error::MethodError(name, _, _)
            if matches!(
                name.as_str(),
                "org.freedesktop.DBus.Error.ServiceUnknown" | "org.freedesktop.DBus.Error.NameHasNoOwner"
            ) =>
        {
            PlatformError::Unavailable(format!("no systemd user manager: {e}"))
        }
        zbus::Error::MethodError(name, _, _) if name.as_str() == "org.freedesktop.DBus.Error.AccessDenied" => {
            PlatformError::Denied(format!("systemd {what}: {e}"))
        }
        _ => PlatformError::Failed(format!("systemd {what}: {e}")),
    }
}

#[cfg(test)]
mod tests;
