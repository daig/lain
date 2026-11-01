//! Where lain keeps its files, and how it writes them.
//!
//! No Swift counterpart: the Mac host keeps its state in the Keychain and in `UserDefaults`.

use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use lain_platform::PlatformError;

/// The directory name under `$XDG_CONFIG_HOME`.
pub const APP_DIR: &str = "lain";

/// `$XDG_CONFIG_HOME`, else `$HOME/.config` (the XDG base directory rules: a relative
/// `XDG_CONFIG_HOME` is ignored). `None` when neither gives an absolute path.
pub fn config_home_from(xdg_config_home: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    if let Some(xdg) = xdg_config_home.map(PathBuf::from).filter(|p| p.is_absolute()) {
        return Some(xdg);
    }
    home.map(PathBuf::from).filter(|p| p.is_absolute()).map(|h| h.join(".config"))
}

/// [`config_home_from`] with this process's environment.
pub fn config_home() -> Result<PathBuf, PlatformError> {
    config_home_from(std::env::var_os("XDG_CONFIG_HOME"), std::env::var_os("HOME"))
        .ok_or_else(|| PlatformError::Unavailable("neither XDG_CONFIG_HOME nor HOME is an absolute path".into()))
}

/// lain's own directory, `<config home>/lain`.
pub fn lain_dir(config_home: &Path) -> PathBuf {
    config_home.join(APP_DIR)
}

/// Creates `dir` (and its parents) if needed and makes it 0700: it holds the host id and, in the fallback,
/// the pairing secrets.
pub(crate) fn ensure_private_dir(dir: &Path) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    let meta = fs::metadata(dir)?;
    if !meta.is_dir() {
        return Err(io::Error::new(io::ErrorKind::NotADirectory, format!("{} is not a directory", dir.display())));
    }
    if meta.permissions().mode() & 0o777 != 0o700 {
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// A temporary file beside `target`, created exclusively with `mode`, holding `bytes`, flushed to disk.
fn write_temp(target: &Path, bytes: &[u8], mode: u32) -> io::Result<PathBuf> {
    let dir = target.parent().ok_or_else(|| io::Error::other("a target path needs a parent directory"))?;
    let name = target.file_name().ok_or_else(|| io::Error::other("a target path needs a file name"))?;
    let mut temp_name = OsString::from(".");
    temp_name.push(name);
    temp_name.push(format!(".tmp-{}-{}", std::process::id(), TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)));
    let temp = dir.join(temp_name);
    let result = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).mode(mode).open(&temp)?;
        // The umask may have narrowed `mode`; it can't have widened it, but say exactly what we mean.
        file.set_permissions(fs::Permissions::from_mode(mode))?;
        file.write_all(bytes)?;
        file.sync_all()
    })();
    match result {
        Ok(()) => Ok(temp),
        Err(e) => {
            let _ = fs::remove_file(&temp);
            Err(e)
        }
    }
}

fn sync_dir(dir: &Path) -> io::Result<()> {
    File::open(dir)?.sync_all()
}

/// Replaces `target` with `bytes` atomically: a temporary file in the same directory, fsynced, renamed over
/// `target`, then the directory fsynced. A reader sees the old contents or the new, never a mix, and a crash
/// leaves one of the two.
pub(crate) fn replace_atomically(target: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    let temp = write_temp(target, bytes, mode)?;
    if let Err(e) = fs::rename(&temp, target) {
        let _ = fs::remove_file(&temp);
        return Err(e);
    }
    sync_dir(target.parent().unwrap_or(Path::new(".")))
}

/// Creates `target` with `bytes` atomically, only if it doesn't exist: a temporary file hard-linked to
/// `target` (which fails if another writer got there first). Returns false, writing nothing, when `target`
/// already exists.
pub(crate) fn create_atomically(target: &Path, bytes: &[u8], mode: u32) -> io::Result<bool> {
    let temp = write_temp(target, bytes, mode)?;
    let linked = fs::hard_link(&temp, target);
    let _ = fs::remove_file(&temp);
    match linked {
        Ok(()) => {
            sync_dir(target.parent().unwrap_or(Path::new(".")))?;
            Ok(true)
        }
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Ok(false),
        Err(e) => Err(e),
    }
}

/// An I/O error as the contract's error, naming what was being done.
pub(crate) fn io_error(what: &str, path: &Path, e: io::Error) -> PlatformError {
    match e.kind() {
        io::ErrorKind::PermissionDenied => PlatformError::Denied(format!("{what} {}: {e}", path.display())),
        _ => PlatformError::Failed(format!("{what} {}: {e}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_home_follows_the_xdg_rules() {
        let abs = |s: &str| Some(OsString::from(s));
        assert_eq!(config_home_from(abs("/x/cfg"), abs("/home/u")), Some(PathBuf::from("/x/cfg")));
        assert_eq!(config_home_from(None, abs("/home/u")), Some(PathBuf::from("/home/u/.config")));
        // A relative XDG_CONFIG_HOME is invalid and ignored.
        assert_eq!(config_home_from(abs("rel/cfg"), abs("/home/u")), Some(PathBuf::from("/home/u/.config")));
        assert_eq!(config_home_from(abs(""), abs("/home/u")), Some(PathBuf::from("/home/u/.config")));
        assert_eq!(config_home_from(None, abs("rel")), None);
        assert_eq!(config_home_from(None, None), None);
        assert_eq!(lain_dir(Path::new("/x/cfg")), PathBuf::from("/x/cfg/lain"));
    }

    #[test]
    fn the_private_dir_is_0700_even_if_it_existed_wider() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("a/lain");
        ensure_private_dir(&dir).unwrap();
        assert_eq!(fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        ensure_private_dir(&dir).unwrap();
        assert_eq!(fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
    }

    #[test]
    fn a_replacement_is_whole_with_its_mode_and_leaves_no_temporary_file() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("f");
        replace_atomically(&target, b"one", 0o600).unwrap();
        replace_atomically(&target, b"two", 0o600).unwrap();
        assert_eq!(fs::read(&target).unwrap(), b"two");
        assert_eq!(fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o600);
        let names: Vec<_> = fs::read_dir(tmp.path()).unwrap().map(|e| e.unwrap().file_name()).collect();
        assert_eq!(names, [OsString::from("f")]);
    }

    #[test]
    fn creation_never_overwrites() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("f");
        assert!(create_atomically(&target, b"first", 0o600).unwrap());
        assert!(!create_atomically(&target, b"second", 0o600).unwrap());
        assert_eq!(fs::read(&target).unwrap(), b"first");
        assert_eq!(fs::read_dir(tmp.path()).unwrap().count(), 1);
    }
}
