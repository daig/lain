//! Who this host is (Swift: `HostIdentity`, `LainHostCore/Session/HostIdentity.swift`).
//!
//! **Intended difference from Swift:** the Mac keeps its host id in the Keychain (service
//! `sub.dev.lain.host-identity`, account `host-id`), this device only. Here it is a file,
//! `$XDG_CONFIG_HOME/lain/host-id` (the spec's platform mapping): the id is public (it is advertised in the
//! Bonjour TXT record), so it needs no secret store, and a file keeps working when the keyring is locked.
//! Copying the home directory to another machine copies the id with it, which the Keychain prevents.

use std::fs::{self, OpenOptions};
use std::io;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

use lain_platform::{HostIdentity, PlatformError, Result};
use tracing::{debug, info, warn};

use crate::paths;

/// The file in lain's directory that holds the host id: the UUID and a newline.
pub const HOST_ID_FILE: &str = "host-id";

/// The name when neither `hostname1` nor the kernel gives one (Swift falls back to "Mac").
pub const FALLBACK_NAME: &str = "Linux";

/// How long the `hostname1` property read may take (it may start the service on demand).
const HOSTNAME1_TIMEOUT: Duration = Duration::from_secs(2);

/// Whether `id` is a host id exactly as Swift writes one (`UUID().uuidString`: uppercase, hyphenated).
/// Mirrors `PairingAccounts.isCanonicalHostId`: `UUID(uuidString: id)?.uuidString == id`.
pub fn is_canonical_host_id(id: &str) -> bool {
    uuid::Uuid::try_parse(id).is_ok_and(|u| u.hyphenated().encode_upper(&mut uuid::Uuid::encode_buffer()) == id)
}

/// A new random host id in the canonical form.
pub fn new_host_id() -> String {
    uuid::Uuid::new_v4().hyphenated().to_string().to_uppercase()
}

/// Where a malformed host id file's contents are kept when it is replaced, for recovery by hand.
pub const HOST_ID_CORRUPT_FILE: &str = "host-id.corrupt";

/// The lock file (`flock`) that serializes replacing a malformed host id, across processes.
pub const HOST_ID_LOCK_FILE: &str = "host-id.lock";

/// The stored host id from `lain_dir`/`host-id`, created on first use (Swift: `HostIdentity.load`).
///
/// Created once and atomically: a second process racing to create it reads the winner's id. Surrounding
/// ASCII whitespace (a hand edit's CRLF or extra newline) is ignored and the file left as it is (an
/// intended difference: Swift's Keychain item can't be hand-edited; lowercase stays malformed, as in
/// Swift). Any other malformed contents are replaced, as Swift replaces a malformed
/// Keychain item; the old contents are kept in `host-id.corrupt`, and the replacement is made under an
/// exclusive lock on `host-id.lock`, so loaders racing to replace it all return the one id left on disk
/// (Swift's Keychain version has that race). Fails if the file can't be read or written, so that Wi-Fi
/// stays off rather than advertising an id that changes (as in Swift).
pub fn load_or_create_host_id(lain_dir: &Path) -> Result<String> {
    let path = lain_dir.join(HOST_ID_FILE);
    paths::ensure_private_dir(lain_dir).map_err(|e| paths::io_error("creating", lain_dir, e))?;
    // A few rounds at most: a later one reads what a concurrent creator wrote.
    for _ in 0..3 {
        match read_host_id(&path)? {
            Some(Ok(id)) => return Ok(id),
            Some(Err(_)) => {
                if let Some(id) = replace_malformed(lain_dir, &path)? {
                    return Ok(id);
                }
            }
            None => {
                let id = new_host_id();
                if paths::create_atomically(&path, format!("{id}\n").as_bytes(), 0o600)
                    .map_err(|e| paths::io_error("writing", &path, e))?
                {
                    info!(%id, path = %path.display(), "created the host id");
                    return Ok(id);
                }
                debug!("another process created the host id first");
            }
        }
    }
    Err(PlatformError::Failed(format!("{} keeps changing", path.display())))
}

/// Replaces a malformed `path` under the lock, unless another loader already has: returns the id now on
/// disk, or `None` if the file has gone (the caller then creates it).
fn replace_malformed(lain_dir: &Path, path: &Path) -> Result<Option<String>> {
    let lock_path = lain_dir.join(HOST_ID_LOCK_FILE);
    let lock = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(&lock_path)
        .map_err(|e| paths::io_error("opening", &lock_path, e))?;
    lock.lock().map_err(|e| paths::io_error("locking", &lock_path, e))?;
    // Read again under the lock: a loader that held it first may have replaced the file already.
    let malformed = match read_host_id(path)? {
        Some(Ok(id)) => return Ok(Some(id)),
        None => return Ok(None),
        Some(Err(malformed)) => malformed,
    };
    let contents = String::from_utf8_lossy(&malformed);
    warn!(path = %path.display(), contents = %contents.escape_debug(), "host id malformed; replacing it");
    let backup = lain_dir.join(HOST_ID_CORRUPT_FILE);
    paths::replace_atomically(&backup, &malformed, 0o600).map_err(|e| paths::io_error("writing", &backup, e))?;
    let id = new_host_id();
    paths::replace_atomically(path, format!("{id}\n").as_bytes(), 0o600)
        .map_err(|e| paths::io_error("writing", path, e))?;
    info!(%id, backup = %backup.display(), "new host id; the malformed one is kept");
    Ok(Some(id))
}

/// `None`: no file. `Some(Err(contents))`: a file that isn't one canonical id (surrounding ASCII
/// whitespace aside).
fn read_host_id(path: &Path) -> Result<Option<std::result::Result<String, Vec<u8>>>> {
    match fs::read(path) {
        Ok(bytes) => {
            let id = std::str::from_utf8(&bytes).map(str::trim_ascii).ok().filter(|id| is_canonical_host_id(id));
            Ok(Some(match id {
                Some(id) => Ok(id.to_owned()),
                None => Err(bytes),
            }))
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(paths::io_error("reading", path, e)),
    }
}

#[zbus::proxy(
    interface = "org.freedesktop.hostname1",
    default_service = "org.freedesktop.hostname1",
    default_path = "/org/freedesktop/hostname1"
)]
trait Hostname1 {
    #[zbus(property)]
    fn pretty_hostname(&self) -> zbus::Result<String>;
}

/// The computer's name (Swift: `HostIdentity.computerName`): `org.freedesktop.hostname1`'s `PrettyHostname`
/// (GNOME Settings › System › About › Device Name), else the kernel's host name, else [`FALLBACK_NAME`].
/// Never empty. `system_bus` is the system bus, or `None` to skip `hostname1`.
pub async fn host_name(system_bus: Option<&zbus::Connection>) -> String {
    if let Some(bus) = system_bus {
        match tokio::time::timeout(HOSTNAME1_TIMEOUT, pretty_hostname(bus)).await {
            Ok(Ok(pretty)) if !pretty.trim().is_empty() => return pretty.trim().to_owned(),
            Ok(Ok(_)) => debug!("no PrettyHostname; using the host name"),
            Ok(Err(e)) => debug!(error = %e, "hostname1 unreadable; using the host name"),
            Err(_) => debug!("hostname1 timed out; using the host name"),
        }
    }
    kernel_host_name().unwrap_or_else(|| FALLBACK_NAME.to_owned())
}

async fn pretty_hostname(bus: &zbus::Connection) -> zbus::Result<String> {
    // Uncached: one read, and no PropertiesChanged subscription to set up.
    Hostname1Proxy::builder(bus)
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await?
        .pretty_hostname()
        .await
}

fn kernel_host_name() -> Option<String> {
    let name = rustix::system::uname().nodename().to_string_lossy().trim().to_owned();
    (!name.is_empty()).then_some(name)
}

/// The host's identity: the id from `lain_dir` (created on first use) and [`host_name`].
pub async fn load_host_identity_in(lain_dir: &Path, system_bus: Option<&zbus::Connection>) -> Result<HostIdentity> {
    let dir: PathBuf = lain_dir.to_owned();
    let id = tokio::task::spawn_blocking(move || load_or_create_host_id(&dir))
        .await
        .map_err(|e| PlatformError::Failed(format!("host id task: {e}")))??;
    Ok(HostIdentity { id, name: host_name(system_bus).await })
}

/// The host's identity from `$XDG_CONFIG_HOME/lain/host-id` and the system bus's `hostname1`.
pub async fn load_host_identity() -> Result<HostIdentity> {
    let dir = paths::lain_dir(&paths::config_home()?);
    let bus = match zbus::Connection::system().await {
        Ok(bus) => Some(bus),
        Err(e) => {
            debug!(error = %e, "no system bus; using the host name");
            None
        }
    };
    load_host_identity_in(&dir, bus.as_ref()).await
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt;

    use super::*;
    use crate::testbus::TestBus;

    #[test]
    fn canonical_ids_are_uppercase_hyphenated_uuids() {
        assert!(is_canonical_host_id("6F9619FF-8B86-D011-B42D-00C04FC964FF"));
        assert!(!is_canonical_host_id("6f9619ff-8b86-d011-b42d-00c04fc964ff"));
        assert!(!is_canonical_host_id("6F9619FF8B86D011B42D00C04FC964FF"));
        assert!(!is_canonical_host_id("{6F9619FF-8B86-D011-B42D-00C04FC964FF}"));
        assert!(!is_canonical_host_id("urn:uuid:6F9619FF-8B86-D011-B42D-00C04FC964FF"));
        assert!(!is_canonical_host_id(" 6F9619FF-8B86-D011-B42D-00C04FC964FF"));
        assert!(!is_canonical_host_id("not-a-uuid"));
        assert!(!is_canonical_host_id(""));
        for _ in 0..16 {
            assert!(is_canonical_host_id(&new_host_id()));
        }
    }

    /// Swift: `HostIdentityTests.theIdIsCreatedOnceThenKept`.
    #[test]
    fn the_id_is_created_once_then_kept() {
        let config = tempfile::tempdir().unwrap();
        let dir = paths::lain_dir(config.path());
        let first = load_or_create_host_id(&dir).unwrap();
        assert!(is_canonical_host_id(&first));
        assert_eq!(fs::read_to_string(dir.join(HOST_ID_FILE)).unwrap(), format!("{first}\n"));
        assert_eq!(load_or_create_host_id(&dir).unwrap(), first);
        assert_eq!(fs::metadata(&dir).unwrap().permissions().mode() & 0o777, 0o700);
        assert_eq!(fs::metadata(dir.join(HOST_ID_FILE)).unwrap().permissions().mode() & 0o777, 0o600);
    }

    /// Swift: `HostIdentityTests.aMalformedStoredIdIsReplaced`.
    #[test]
    fn a_malformed_stored_id_is_replaced() {
        let config = tempfile::tempdir().unwrap();
        let dir = paths::lain_dir(config.path());
        for malformed in ["not-a-uuid", "6f9619ff-8b86-d011-b42d-00c04fc964ff\n", "", "\u{FFFD}"] {
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join(HOST_ID_FILE), malformed).unwrap();
            let id = load_or_create_host_id(&dir).unwrap();
            assert!(is_canonical_host_id(&id));
            assert_eq!(fs::read_to_string(dir.join(HOST_ID_FILE)).unwrap(), format!("{id}\n"));
            // The old contents are kept, 0600, for recovery by hand.
            assert_eq!(fs::read_to_string(dir.join(HOST_ID_CORRUPT_FILE)).unwrap(), malformed);
            assert_eq!(fs::metadata(dir.join(HOST_ID_CORRUPT_FILE)).unwrap().permissions().mode() & 0o777, 0o600);
        }
    }

    /// Review S5: a hand edit's CRLF, trailing space or extra newline keeps the id (and every Wi-Fi pairing
    /// made under it).
    #[test]
    fn surrounding_whitespace_keeps_the_id() {
        let config = tempfile::tempdir().unwrap();
        let dir = paths::lain_dir(config.path());
        fs::create_dir_all(&dir).unwrap();
        let id = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
        for written in [format!("{id}\r\n"), format!("{id} \n"), format!("{id}\n\n"), format!(" \t{id}")] {
            fs::write(dir.join(HOST_ID_FILE), &written).unwrap();
            assert_eq!(load_or_create_host_id(&dir).unwrap(), id, "{written:?}");
            assert_eq!(fs::read_to_string(dir.join(HOST_ID_FILE)).unwrap(), written, "left as it is");
        }
        assert!(!dir.join(HOST_ID_CORRUPT_FILE).exists());
    }

    /// Review S4: loaders racing to replace a malformed id all return the one left on disk.
    #[test]
    fn racing_replacers_of_a_malformed_id_agree() {
        for _ in 0..50 {
            let config = tempfile::tempdir().unwrap();
            let dir = paths::lain_dir(config.path());
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join(HOST_ID_FILE), "garbage").unwrap();
            let barrier = std::sync::Barrier::new(4);
            let ids: Vec<String> = std::thread::scope(|s| {
                let handles: Vec<_> = (0..4)
                    .map(|_| {
                        s.spawn(|| {
                            barrier.wait();
                            load_or_create_host_id(&dir).unwrap()
                        })
                    })
                    .collect();
                handles.into_iter().map(|h| h.join().unwrap()).collect()
            });
            let on_disk = fs::read_to_string(dir.join(HOST_ID_FILE)).unwrap();
            assert!(ids.iter().all(|id| format!("{id}\n") == on_disk), "returned {ids:?}, on disk {on_disk:?}");
            assert_eq!(fs::read_to_string(dir.join(HOST_ID_CORRUPT_FILE)).unwrap(), "garbage");
        }
    }

    #[test]
    fn a_hand_written_id_without_a_newline_is_kept() {
        let config = tempfile::tempdir().unwrap();
        let dir = paths::lain_dir(config.path());
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(HOST_ID_FILE), "6F9619FF-8B86-D011-B42D-00C04FC964FF").unwrap();
        assert_eq!(load_or_create_host_id(&dir).unwrap(), "6F9619FF-8B86-D011-B42D-00C04FC964FF");
    }

    #[test]
    fn racing_creators_agree_on_one_id() {
        let config = tempfile::tempdir().unwrap();
        let dir = paths::lain_dir(config.path());
        let ids: Vec<String> = std::thread::scope(|s| {
            let handles: Vec<_> = (0..8).map(|_| s.spawn(|| load_or_create_host_id(&dir).unwrap())).collect();
            handles.into_iter().map(|h| h.join().unwrap()).collect()
        });
        assert!(ids.iter().all(|id| *id == ids[0]), "{ids:?}");
        assert_eq!(fs::read_to_string(dir.join(HOST_ID_FILE)).unwrap(), format!("{}\n", ids[0]));
    }

    #[test]
    fn an_unwritable_directory_is_an_error_not_a_fresh_id() {
        let config = tempfile::tempdir().unwrap();
        // lain's directory is a file: nothing can be created in it.
        fs::write(config.path().join(paths::APP_DIR), b"").unwrap();
        assert!(load_or_create_host_id(&paths::lain_dir(config.path())).is_err());
    }

    /// Swift: `HostIdentityTests.theComputerNameIsNeverEmpty`.
    #[tokio::test]
    async fn the_computer_name_is_never_empty() {
        assert!(!host_name(None).await.is_empty());
        assert_eq!(host_name(None).await, kernel_host_name().unwrap_or_else(|| FALLBACK_NAME.into()));
    }

    struct FakeHostname1(String);

    #[zbus::interface(name = "org.freedesktop.hostname1")]
    impl FakeHostname1 {
        #[zbus(property)]
        fn pretty_hostname(&self) -> String {
            self.0.clone()
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_name_is_the_pretty_hostname_else_the_host_name() {
        let Some(bus) = TestBus::start().await else { return };
        let client = bus.connect().await;
        // No hostname1 on the bus.
        assert_eq!(host_name(Some(&client)).await, host_name(None).await);

        let service = bus.connect().await;
        service.object_server().at("/org/freedesktop/hostname1", FakeHostname1("  Dai's Desk  ".into())).await.unwrap();
        service.request_name("org.freedesktop.hostname1").await.unwrap();
        assert_eq!(host_name(Some(&client)).await, "Dai's Desk");
        drop(service);

        let service = bus.connect().await;
        service.object_server().at("/org/freedesktop/hostname1", FakeHostname1(" ".into())).await.unwrap();
        service.request_name("org.freedesktop.hostname1").await.unwrap();
        assert_eq!(host_name(Some(&client)).await, host_name(None).await);
    }

    #[tokio::test]
    async fn the_identity_combines_the_id_and_the_name() {
        let config = tempfile::tempdir().unwrap();
        let dir = paths::lain_dir(config.path());
        let identity = load_host_identity_in(&dir, None).await.unwrap();
        assert_eq!(identity.id, load_or_create_host_id(&dir).unwrap());
        assert_eq!(identity.name, host_name(None).await);
    }
}
