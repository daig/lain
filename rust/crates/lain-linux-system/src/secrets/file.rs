//! The file fallback for pairing secrets.

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use lain_platform::{PlatformError, Result, SecretStore};
use tracing::warn;

use crate::paths;

/// The fallback's file name in lain's directory.
pub const SECRETS_FILE: &str = "secrets";

/// The first line of the file: its format and version.
const HEADER: &str = "lain-secrets 1";

/// Pairing secrets in a file, for when no Secret Service is available (Swift: `SecretStore`, implemented
/// by `KeychainSecretStore` on the Mac; no Swift counterpart for a file).
///
/// The file is `<lain dir>/secrets`, mode 0600 in a 0700 directory, replaced atomically on every change
/// (temporary file, fsync, rename, directory fsync). It is not encrypted: its protection is the file
/// mode, like `~/.ssh` keys without a passphrase. Format: the line `lain-secrets 1`, then one line per
/// account, `<account as hex> <secret as hex>`, sorted by account.
///
/// Every change (read, modify, replace) is made under an exclusive `flock` on `<lain dir>/secrets.lock`, so
/// changes from other instances and other processes (the daemon and a CLI) are serialized and none is
/// lost. Reads take no lock: the file is only ever replaced whole.
///
/// A file or directory found wider than 0600/0700 (restored from a backup, copied under umask 022) is
/// narrowed when it is read, not left so until the next change; if it can't be (not ours), the read fails
/// with `Denied`.
#[derive(Debug, Clone)]
pub struct FileSecretStore {
    path: PathBuf,
}

/// The lock file beside the secrets file.
pub const SECRETS_LOCK_FILE: &str = "secrets.lock";

impl FileSecretStore {
    /// The store in `lain_dir` (`$XDG_CONFIG_HOME/lain` in production). Touches nothing until used.
    pub fn new(lain_dir: &Path) -> FileSecretStore {
        FileSecretStore { path: lain_dir.join(SECRETS_FILE) }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn dir(&self) -> &Path {
        self.path.parent().unwrap_or(Path::new("."))
    }

    /// Whether the file exists and holds at least one secret (an unreadable file counts as holding some).
    pub async fn has_secrets(&self) -> bool {
        let store = self.clone();
        tokio::task::spawn_blocking(move || match store.read_all() {
            Ok(secrets) => !secrets.is_empty(),
            Err(_) => store.path.exists(),
        })
        .await
        .unwrap_or(true)
    }

    fn read_all(&self) -> Result<BTreeMap<String, Vec<u8>>> {
        let text = match fs::read(&self.path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(BTreeMap::new()),
            Err(e) => return Err(paths::io_error("reading", &self.path, e)),
        };
        let meta = fs::metadata(&self.path).map_err(|e| paths::io_error("reading", &self.path, e))?;
        if meta.permissions().mode() & 0o077 != 0 {
            warn!(path = %self.path.display(), "the secrets file was readable by others; making it 0600");
            fs::set_permissions(&self.path, fs::Permissions::from_mode(0o600))
                .map_err(|e| paths::io_error("narrowing the mode of", &self.path, e))?;
        }
        paths::ensure_private_dir(self.dir()).map_err(|e| paths::io_error("narrowing the mode of", self.dir(), e))?;
        parse(&text).map_err(|why| PlatformError::Failed(format!("{}: {why}", self.path.display())))
    }

    fn write_all(&self, secrets: &BTreeMap<String, Vec<u8>>) -> Result<()> {
        paths::replace_atomically(&self.path, render(secrets).as_bytes(), 0o600)
            .map_err(|e| paths::io_error("writing", &self.path, e))
    }

    /// Runs `f` on a blocking thread.
    async fn blocking<T: Send + 'static>(
        &self,
        f: impl FnOnce(&FileSecretStore) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let store = self.clone();
        tokio::task::spawn_blocking(move || f(&store))
            .await
            .map_err(|e| PlatformError::Failed(format!("secrets file task: {e}")))?
    }

    /// Reads the secrets, lets `change` edit them, and writes them back if it says they changed: all under
    /// the lock file's exclusive `flock`, released when the lock file closes.
    async fn modify(&self, change: impl FnOnce(&mut BTreeMap<String, Vec<u8>>) -> bool + Send + 'static) -> Result<()> {
        self.blocking(move |s| {
            let dir = s.dir();
            paths::ensure_private_dir(dir).map_err(|e| paths::io_error("creating", dir, e))?;
            let lock_path = dir.join(SECRETS_LOCK_FILE);
            let lock = OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(false)
                .mode(0o600)
                .open(&lock_path)
                .map_err(|e| paths::io_error("opening", &lock_path, e))?;
            lock.lock().map_err(|e| paths::io_error("locking", &lock_path, e))?;
            let mut all = s.read_all()?;
            if change(&mut all) {
                s.write_all(&all)?;
            }
            Ok(())
        })
        .await
    }
}

fn render(secrets: &BTreeMap<String, Vec<u8>>) -> String {
    let mut text = format!("{HEADER}\n");
    for (account, secret) in secrets {
        text.push_str(&hex::encode(account.as_bytes()));
        text.push(' ');
        text.push_str(&hex::encode(secret));
        text.push('\n');
    }
    text
}

fn parse(bytes: &[u8]) -> std::result::Result<BTreeMap<String, Vec<u8>>, String> {
    let text = std::str::from_utf8(bytes).map_err(|_| "not UTF-8".to_owned())?;
    let mut lines = text.lines();
    if lines.next() != Some(HEADER) {
        return Err(format!("the first line isn't `{HEADER}`"));
    }
    let mut secrets = BTreeMap::new();
    for (n, line) in lines.enumerate().map(|(n, l)| (n + 2, l)) {
        if line.is_empty() {
            continue;
        }
        let (account, secret) = line.split_once(' ').ok_or_else(|| format!("line {n}: no separator"))?;
        let account = hex::decode(account)
            .ok()
            .and_then(|a| String::from_utf8(a).ok())
            .ok_or_else(|| format!("line {n}: a malformed account"))?;
        let secret = hex::decode(secret).map_err(|_| format!("line {n}: a malformed secret"))?;
        // The first wins, as in Swift's `KeychainSecretStore.secrets(fromItems:)`.
        secrets.entry(account).or_insert(secret);
    }
    Ok(secrets)
}

impl SecretStore for FileSecretStore {
    async fn secret(&self, account: &str) -> Result<Option<Vec<u8>>> {
        let account = account.to_owned();
        self.blocking(move |s| Ok(s.read_all()?.remove(&account))).await
    }

    async fn set_secret(&self, account: &str, secret: &[u8]) -> Result<()> {
        let (account, secret) = (account.to_owned(), secret.to_vec());
        self.modify(move |all| {
            if all.get(&account) == Some(&secret) {
                return false;
            }
            all.insert(account, secret);
            true
        })
        .await
    }

    async fn remove_secret(&self, account: &str) -> Result<()> {
        // No file, nothing to remove: not even the directory or the lock file is created.
        if !self.blocking(|s| Ok(s.path.exists())).await? {
            return Ok(());
        }
        let account = account.to_owned();
        self.modify(move |all| all.remove(&account).is_some()).await
    }

    async fn all_secrets(&self) -> Result<BTreeMap<String, Vec<u8>>> {
        self.blocking(|s| s.read_all()).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, FileSecretStore) {
        let config = tempfile::tempdir().unwrap();
        let store = FileSecretStore::new(&paths::lain_dir(config.path()));
        (config, store)
    }

    /// Swift: `KeychainSecretStoreTests.keychainSecretStoreRoundTrip` (hosted in Apps/ClientTests).
    #[tokio::test]
    async fn round_trip() {
        let (_config, store) = store();
        store.remove_secret("host").await.unwrap();
        assert_eq!(store.secret("host").await.unwrap(), None);
        store.set_secret("host", &[7; 32]).await.unwrap();
        assert_eq!(store.secret("host").await.unwrap(), Some(vec![7; 32]));
        store.set_secret("host", &[9; 32]).await.unwrap();
        assert_eq!(store.secret("host").await.unwrap(), Some(vec![9; 32]));
        store.remove_secret("host").await.unwrap();
        assert_eq!(store.secret("host").await.unwrap(), None);
    }

    /// Swift: `KeychainSecretStoreTests.allSecretsListsTheServicesItems`. The host's accounts are the iPads'
    /// USB serials; the client's are `host` and `mac:<host id>`. Any string works, spaces and all.
    #[tokio::test]
    async fn all_secrets_lists_every_account() {
        let (_config, store) = store();
        assert!(store.all_secrets().await.unwrap().is_empty());
        let accounts = ["host", "mac:6F9619FF-8B86-D011-B42D-00C04FC964FF", "00008103-001A2B3C4D5E", "a b\nc", ""];
        for (n, account) in accounts.iter().enumerate() {
            store.set_secret(account, &[n as u8; 32]).await.unwrap();
        }
        let listed = store.all_secrets().await.unwrap();
        let expected: BTreeMap<String, Vec<u8>> =
            accounts.iter().enumerate().map(|(n, a)| (a.to_string(), vec![n as u8; 32])).collect();
        assert_eq!(listed, expected);
        for account in accounts {
            store.remove_secret(account).await.unwrap();
        }
        assert!(store.all_secrets().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn the_file_is_0600_in_a_0700_directory_and_survives_a_new_store() {
        let (config, store) = store();
        store.set_secret("serial", &[1, 2, 3]).await.unwrap();
        let dir = paths::lain_dir(config.path());
        assert_eq!(fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(fs::metadata(store.path()).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::read_to_string(store.path()).unwrap(), "lain-secrets 1\n73657269616c 010203\n");
        let reopened = FileSecretStore::new(&dir);
        assert_eq!(reopened.secret("serial").await.unwrap(), Some(vec![1, 2, 3]));
        assert!(reopened.has_secrets().await);
    }

    /// Review S4: the file's only protection is its mode, so a wider one is narrowed as soon as it is seen
    /// (a read), not at the next change.
    #[tokio::test]
    async fn a_wider_mode_is_narrowed_on_read() {
        let (config, store) = store();
        store.set_secret("a", &[1]).await.unwrap();
        let dir = paths::lain_dir(config.path());
        fs::set_permissions(store.path(), fs::Permissions::from_mode(0o644)).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(store.secret("a").await.unwrap(), Some(vec![1]));
        assert_eq!(fs::metadata(store.path()).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(fs::read_to_string(store.path()).unwrap(), "lain-secrets 1\n61 01\n", "the contents untouched");
    }

    /// Review S2: two instances on one file (or two processes: the lock is an `flock`) keep every change.
    #[tokio::test(flavor = "multi_thread", worker_threads = 8)]
    async fn two_instances_on_one_file_keep_every_change() {
        let (config, a) = store();
        let b = FileSecretStore::new(&paths::lain_dir(config.path()));
        let tasks: Vec<_> = (0..32u8)
            .map(|n| {
                let s = if n % 2 == 0 { a.clone() } else { b.clone() };
                tokio::spawn(async move { s.set_secret(&format!("acct{n}"), &[n]).await.unwrap() })
            })
            .collect();
        for task in tasks {
            task.await.unwrap();
        }
        assert_eq!(a.all_secrets().await.unwrap().len(), 32);
        let lock = paths::lain_dir(config.path()).join(SECRETS_LOCK_FILE);
        assert_eq!(fs::metadata(lock).unwrap().permissions().mode() & 0o777, 0o600);
    }

    #[tokio::test]
    async fn a_corrupt_file_is_an_error_and_is_left_alone() {
        let (config, store) = store();
        fs::create_dir_all(paths::lain_dir(config.path())).unwrap();
        for corrupt in
            ["", "something else\n", "lain-secrets 1\nzz 00\n", "lain-secrets 1\n61\n", "lain-secrets 1\n61 0\n"]
        {
            fs::write(store.path(), corrupt).unwrap();
            assert!(store.secret("a").await.is_err(), "{corrupt:?}");
            assert!(store.all_secrets().await.is_err(), "{corrupt:?}");
            assert!(store.set_secret("a", &[1]).await.is_err(), "{corrupt:?}");
            assert_eq!(fs::read_to_string(store.path()).unwrap(), corrupt);
        }
    }

    #[test]
    fn the_first_duplicate_wins_and_blank_lines_are_skipped() {
        let parsed = parse(b"lain-secrets 1\n\n61 01\n61 02\n62 \n").unwrap();
        assert_eq!(parsed, BTreeMap::from([("a".to_owned(), vec![1]), ("b".to_owned(), vec![])]));
    }

    #[tokio::test]
    async fn concurrent_changes_are_all_kept() {
        let (_config, store) = store();
        let tasks: Vec<_> = (0..16u8)
            .map(|n| {
                let store = store.clone();
                tokio::spawn(async move { store.set_secret(&format!("acct{n}"), &[n]).await.unwrap() })
            })
            .collect();
        for task in tasks {
            task.await.unwrap();
        }
        assert_eq!(store.all_secrets().await.unwrap().len(), 16);
    }

    #[tokio::test]
    async fn removing_a_missing_account_writes_nothing() {
        let (_config, store) = store();
        store.remove_secret("nobody").await.unwrap();
        assert!(!store.path().exists());
        assert!(!store.has_secrets().await);
        assert!(!store.path().parent().unwrap().exists(), "nothing created");
    }
}
