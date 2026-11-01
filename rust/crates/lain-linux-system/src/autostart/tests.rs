//! The unit text, and the manager calls against a fake systemd on a private bus; one live test.

use std::collections::BTreeMap;

use super::*;
use crate::testbus::TestBus;

#[test]
fn words_are_quoted_for_exec_start() {
    assert_eq!(quote("/usr/bin/lain-hostd"), "/usr/bin/lain-hostd");
    assert_eq!(quote("--flag=1"), "--flag=1");
    assert_eq!(quote(""), "\"\"");
    assert_eq!(quote("/home/a b/lain"), "\"/home/a b/lain\"");
    assert_eq!(quote("100%"), "\"100%%\"");
    assert_eq!(quote("$HOME"), "\"$$HOME\"");
    assert_eq!(quote("a\"b\\c"), "\"a\\\"b\\\\c\"");
    assert_eq!(quote("a\nb"), "\"a\\nb\"");
}

#[test]
fn the_unit_is_bound_to_the_graphical_session() {
    let text = UnitFile::host(Path::new("/home/dai/.local/bin/lain-hostd")).render();
    assert_eq!(
        text,
        "# Installed by lain; `lain autostart off` disables it.\n\
         [Unit]\n\
         Description=lain host: an iPad as this computer's display\n\
         PartOf=graphical-session.target\n\
         After=graphical-session.target\n\
         Requisite=graphical-session.target\n\
         \n\
         [Service]\n\
         ExecStart=/home/dai/.local/bin/lain-hostd\n\
         Restart=on-failure\n\
         RestartSec=2\n\
         RestartPreventExitStatus=2\n\
         \n\
         [Install]\n\
         WantedBy=graphical-session.target\n"
    );
    let unit = UnitFile { description: "a\nb 50%".into(), exec_start: vec!["/bin/x y".into(), "-v".into()] };
    let text = unit.render();
    assert!(text.contains("Description=a b 50%%\n"), "{text}");
    assert!(text.contains("ExecStart=\"/bin/x y\" -v\n"), "{text}");
}

/// Review S6: a trailing backslash would continue `Description=` onto `PartOf=`.
#[test]
fn a_description_ending_in_a_backslash_does_not_swallow_the_next_line() {
    for odd in ["x\\", "x\\\\", "x\\ ", "x\\\n", "x\t\\\r"] {
        let text = UnitFile { description: odd.into(), exec_start: vec!["/bin/true".into()] }.render();
        assert!(text.contains("Description=x\nPartOf=graphical-session.target\n"), "{odd:?}: {text}");
    }
    // A backslash inside the line is literal and stays.
    let text = UnitFile { description: "a\\b\u{7}c".into(), exec_start: vec!["/bin/true".into()] }.render();
    assert!(text.contains("Description=a\\b c\n"), "{text}");
}

#[test]
fn states_map_to_start_at_login() {
    assert_eq!(AutostartState::Enabled.requirement_state(), RequirementState::Granted);
    assert_eq!(AutostartState::Disabled.requirement_state(), RequirementState::Missing);
    assert_eq!(AutostartState::NotInstalled.requirement_state(), RequirementState::Missing);
    assert_eq!(AutostartState::Other("masked".into()).requirement_state(), RequirementState::Missing);
    assert_eq!(AutostartState::Other("linked".into()).requirement_state(), RequirementState::Unknown);
    assert_eq!(AutostartState::Unknown("x".into()).requirement_state(), RequirementState::Unknown);
}

#[test]
fn the_unit_dir_is_under_the_config_home() {
    assert_eq!(user_unit_dir(Path::new("/x/cfg")), PathBuf::from("/x/cfg/systemd/user"));
}

/// A systemd manager that records its calls and keeps each unit's enablement. Like systemd, it refuses to
/// enable a unit whose file isn't in its unit directory.
#[derive(Debug, Default)]
struct FakeState {
    calls: Vec<String>,
    enabled: BTreeMap<String, bool>,
}

/// systemd's `(type, file name, destination)` change entries.
type Change = (String, String, String);

/// The manager's unit directory stands for its whole search path.
struct FakeManager {
    unit_dir: PathBuf,
    state: Arc<Mutex<FakeState>>,
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.systemd1")]
enum FakeError {
    #[zbus(error)]
    ZBus(zbus::Error),
    NoSuchUnit(String),
}

#[zbus::interface(name = "org.freedesktop.systemd1.Manager")]
impl FakeManager {
    fn enable_unit_files(
        &self,
        files: Vec<String>,
        runtime: bool,
        force: bool,
    ) -> zbus::fdo::Result<(bool, Vec<Change>)> {
        let mut state = self.state.lock().unwrap();
        state.calls.push(format!("EnableUnitFiles {files:?} {runtime} {force}"));
        for file in &files {
            if !self.unit_dir.join(file).exists() {
                return Err(zbus::fdo::Error::FileNotFound(format!("Unit file {file} does not exist.")));
            }
            state.enabled.insert(file.clone(), true);
        }
        Ok((true, vec![]))
    }

    /// Like systemd's `install_changes_dump`, a unit it can't find is `NoSuchUnit`.
    fn disable_unit_files(&self, files: Vec<String>, runtime: bool) -> Result<Vec<Change>, FakeError> {
        let mut state = self.state.lock().unwrap();
        state.calls.push(format!("DisableUnitFiles {files:?} {runtime}"));
        for file in files {
            if !self.unit_dir.join(&file).exists() {
                return Err(FakeError::NoSuchUnit(format!("Unit file {file} does not exist.")));
            }
            state.enabled.insert(file, false);
        }
        Ok(vec![])
    }

    fn reload(&self) {
        self.state.lock().unwrap().calls.push("Reload".into());
    }

    fn get_unit_file_state(&self, file: String) -> zbus::fdo::Result<String> {
        let state = self.state.lock().unwrap();
        match state.enabled.get(&file) {
            _ if !self.unit_dir.join(&file).exists() => Err(zbus::fdo::Error::FileNotFound("No such file".into())),
            Some(true) => Ok("enabled".into()),
            _ => Ok("disabled".into()),
        }
    }
}

struct Fixture {
    _bus: TestBus,
    _systemd: zbus::Connection,
    _dir: tempfile::TempDir,
    state: Arc<Mutex<FakeState>>,
    autostart: Autostart,
}

impl Fixture {
    fn calls(&self) -> Vec<String> {
        std::mem::take(&mut self.state.lock().unwrap().calls)
    }
}

async fn fixture() -> Option<Fixture> {
    fixture_in(None).await
}

/// With `systemd_dir`, the manager finds its units there rather than in the autostart's own unit directory
/// (a unit installed elsewhere on its search path).
async fn fixture_in(systemd_dir: Option<&Path>) -> Option<Fixture> {
    let bus = TestBus::start().await?;
    let dir = tempfile::tempdir().unwrap();
    let unit_dir = user_unit_dir(dir.path());
    let state = Arc::new(Mutex::new(FakeState::default()));
    let systemd = bus.connect().await;
    let manager = FakeManager {
        unit_dir: systemd_dir.map_or_else(|| unit_dir.clone(), Path::to_owned),
        state: Arc::clone(&state),
    };
    systemd.object_server().at("/org/freedesktop/systemd1", manager).await.unwrap();
    systemd.request_name("org.freedesktop.systemd1").await.unwrap();
    let autostart = Autostart::new(bus.connect().await, &unit_dir, UNIT_NAME);
    Some(Fixture { _bus: bus, _systemd: systemd, _dir: dir, state, autostart })
}

#[tokio::test(flavor = "multi_thread")]
async fn enable_installs_reloads_and_enables_and_disable_keeps_the_file() {
    let Some(f) = fixture().await else { return };
    let a = &f.autostart;
    assert_eq!(a.start_at_login(), RequirementState::Unknown);
    assert_eq!(a.state().await, AutostartState::NotInstalled);
    assert_eq!(a.start_at_login(), RequirementState::Missing);
    assert!(f.calls().is_empty());

    let unit = UnitFile::host(Path::new("/usr/bin/lain-hostd"));
    a.enable(&unit).await.unwrap();
    assert_eq!(fs::read_to_string(a.unit_path()).unwrap(), unit.render());
    assert_eq!(f.calls(), ["Reload", "EnableUnitFiles [\"lain-hostd.service\"] false false", "Reload"]);
    assert_eq!(a.start_at_login(), RequirementState::Granted);
    assert_eq!(a.state().await, AutostartState::Enabled);

    // The same unit again: the file is unchanged, so no reload before enabling.
    a.enable(&unit).await.unwrap();
    assert_eq!(f.calls(), ["EnableUnitFiles [\"lain-hostd.service\"] false false", "Reload"]);

    a.disable().await.unwrap();
    assert_eq!(f.calls(), ["DisableUnitFiles [\"lain-hostd.service\"] false", "Reload"]);
    assert!(a.unit_path().exists());
    assert_eq!(a.start_at_login(), RequirementState::Missing);
    assert_eq!(a.state().await, AutostartState::Disabled);

    a.uninstall().await.unwrap();
    assert!(!a.unit_path().exists());
    assert_eq!(a.state().await, AutostartState::NotInstalled);
    // Uninstalled: disabling again succeeds on systemd's "no such unit", and reloads nothing.
    f.calls();
    a.disable().await.unwrap();
    a.uninstall().await.unwrap();
    assert_eq!(f.calls(), ["DisableUnitFiles [\"lain-hostd.service\"] false"; 2]);
    assert_eq!(a.start_at_login(), RequirementState::Missing);
}

/// Review S1/R2: a unit systemd finds outside our unit directory (installed by a package or a script) is
/// reported and disabled through systemd, not taken for missing.
#[tokio::test(flavor = "multi_thread")]
async fn a_unit_installed_elsewhere_is_reported_and_disabled() {
    let systemd_dir = tempfile::tempdir().unwrap();
    fs::write(systemd_dir.path().join(UNIT_NAME), "[Service]\nExecStart=/usr/bin/lain-hostd\n").unwrap();
    let Some(f) = fixture_in(Some(systemd_dir.path())).await else { return };
    f.state.lock().unwrap().enabled.insert(UNIT_NAME.into(), true);
    let a = &f.autostart;
    assert!(!a.unit_path().exists());
    assert_eq!(a.state().await, AutostartState::Enabled);
    assert_eq!(a.start_at_login(), RequirementState::Granted);

    a.disable().await.unwrap();
    assert_eq!(f.calls(), ["DisableUnitFiles [\"lain-hostd.service\"] false", "Reload"]);
    assert_eq!(f.state.lock().unwrap().enabled.get(UNIT_NAME), Some(&false));
    assert_eq!(a.state().await, AutostartState::Disabled);

    // Uninstalling removes only our own file: the other copy stays, disabled, and is reported so.
    a.uninstall().await.unwrap();
    assert_eq!(a.start_at_login(), RequirementState::Missing);
    assert_eq!(a.state().await, AutostartState::Disabled);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_changed_unit_is_rewritten() {
    let Some(f) = fixture().await else { return };
    let a = &f.autostart;
    a.enable(&UnitFile::host(Path::new("/old/lain-hostd"))).await.unwrap();
    let new = UnitFile::host(Path::new("/new/lain-hostd"));
    f.calls();
    a.enable(&new).await.unwrap();
    assert_eq!(fs::read_to_string(a.unit_path()).unwrap(), new.render());
    assert_eq!(f.calls()[0], "Reload");
}

#[tokio::test(flavor = "multi_thread")]
async fn without_systemd_the_state_is_unknown_and_enabling_fails() {
    let Some(bus) = TestBus::start().await else { return };
    let dir = tempfile::tempdir().unwrap();
    let a = Autostart::new(bus.connect().await, &user_unit_dir(dir.path()), UNIT_NAME);
    assert!(matches!(a.enable(&UnitFile::host(Path::new("/bin/true"))).await, Err(PlatformError::Unavailable(_))));
    assert!(matches!(a.state().await, AutostartState::Unknown(_)));
    assert_eq!(a.start_at_login(), RequirementState::Unknown);
}

/// Installs, enables, disables and removes `lain-test.service` (`ExecStart=/bin/true`) in the real user
/// manager. Enabling never starts a unit, and this one isn't started. The name is fixed, and the unit is
/// removed first and last, even after a failed assertion, so no run leaves it behind for the next login.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "enables and disables a test unit in the systemd user manager"]
async fn live_enable_and_disable_a_test_unit() {
    use futures::FutureExt;

    let name = "lain-test.service";
    let bus = zbus::Connection::session().await.unwrap();
    let a = Autostart::new(bus, &user_unit_dir(&paths::config_home().unwrap()), name);
    let wants = a.unit_path().parent().unwrap().join(format!("{SESSION_TARGET}.wants")).join(name);
    let unit = UnitFile { description: "lain test unit (never started)".into(), exec_start: vec!["/bin/true".into()] };

    a.uninstall().await.unwrap(); // What a crashed run left.
    let outcome = std::panic::AssertUnwindSafe(async {
        assert_eq!(a.state().await, AutostartState::NotInstalled);
        a.enable(&unit).await.unwrap();
        assert_eq!(a.state().await, AutostartState::Enabled);
        assert!(wants.symlink_metadata().is_ok(), "no {}", wants.display());
        a.disable().await.unwrap();
        assert_eq!(a.state().await, AutostartState::Disabled);
        assert!(wants.symlink_metadata().is_err());
    })
    .catch_unwind()
    .await;
    a.uninstall().await.unwrap();
    if let Err(panic) = outcome {
        std::panic::resume_unwind(panic);
    }
    assert_eq!(a.state().await, AutostartState::NotInstalled);
    assert!(wants.symlink_metadata().is_err());
}
