//! Pairing secrets (Swift: `SecretStore` and `KeychainSecretStore`, `LainTransport/Security.swift`).
//!
//! Accounts are whatever `lain-link` names (Swift: `PairingAccounts`; on the host, the iPad's USB
//! serial). Two backends: the Secret Service ([`SecretServiceStore`]) and a 0600 file
//! ([`FileSecretStore`]). [`SystemSecretStore`] chooses between them once, at startup.

#[cfg(test)]
mod fake_service;
mod file;
mod service;

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

use lain_platform::{PlatformError, Result, SecretStore};
use tracing::{debug, info, warn};

pub use file::{FileSecretStore, SECRETS_FILE, SECRETS_LOCK_FILE};
pub use service::{ACCOUNT_ATTRIBUTE, SERVICE_ATTRIBUTE, SecretServiceStore};

/// The `service` attribute of lain's pairing items: Swift's `KeychainSecretStore` default service.
pub const PAIRING_SERVICE: &str = "sub.dev.lain.pairing";

/// How many times [`SystemSecretStore::open`] asks a Secret Service that is `Unavailable`.
pub const PROBE_ATTEMPTS: usize = 3;
/// The wait between those attempts.
pub const PROBE_RETRY: Duration = Duration::from_secs(1);

/// The pairing store `lain-hostd` uses: one concrete type (`SecretStore` isn't object safe), choosing its
/// backend at runtime with [`open`](Self::open).
#[derive(Debug)]
pub enum SystemSecretStore {
    SecretService(SecretServiceStore),
    File(FileSecretStore),
}

impl SystemSecretStore {
    /// The Secret Service under [`PAIRING_SERVICE`], or the file in `lain_dir` (`$XDG_CONFIG_HOME/lain`;
    /// logged as a warning) only where there is definitely no usable Secret Service.
    ///
    /// The choice is made once, so it leans to the Secret Service: choosing the file for a run would put
    /// that run's pairings where the next run (choosing the Secret Service) doesn't look. The rule, from
    /// the Secret Service's probe:
    /// - it answers with an unlocked default collection: the Secret Service;
    /// - its default collection is *locked*: the Secret Service (calls fail with `Denied` until the owner
    ///   unlocks it);
    /// - it answers with any other error, or not within oo7's 30 s (a hung or confused gnome-keyring): the
    ///   Secret Service, whose calls fail until it works;
    /// - `Unavailable` (no session bus, no Secret Service on it, or no default collection): asked again, up
    ///   to [`PROBE_ATTEMPTS`] times [`PROBE_RETRY`] apart (gnome-keyring may still be starting at login),
    ///   then the file.
    ///
    /// For the same reason, secrets already in the fallback file are not moved into a Secret Service that
    /// appears later; that is logged.
    pub async fn open(lain_dir: &Path) -> SystemSecretStore {
        Self::choose(SecretServiceStore::new(PAIRING_SERVICE), FileSecretStore::new(lain_dir), PROBE_RETRY).await
    }

    async fn choose(service: SecretServiceStore, file: FileSecretStore, retry: Duration) -> SystemSecretStore {
        let mut attempt = 1;
        let probe = loop {
            match service.probe().await {
                Err(PlatformError::Unavailable(why)) if attempt < PROBE_ATTEMPTS => {
                    debug!(%why, attempt, "no Secret Service yet; asking again");
                    tokio::time::sleep(retry).await;
                    attempt += 1;
                }
                probe => break probe,
            }
        };
        match probe {
            Err(PlatformError::Unavailable(why)) => {
                warn!(%why, path = %file.path().display(), "pairing secrets: no Secret Service; using the fallback file");
                return SystemSecretStore::File(file);
            }
            Ok(()) => info!("pairing secrets: Secret Service"),
            Err(why @ PlatformError::Denied(_)) => warn!(%why, "pairing secrets: Secret Service, locked for now"),
            Err(why @ PlatformError::Failed(_)) => {
                warn!(%why, "pairing secrets: Secret Service, failing for now (its calls fail until it works)")
            }
        }
        if file.has_secrets().await {
            warn!(path = %file.path().display(),
                "pairing secrets in the fallback file are not used while the Secret Service is available");
        }
        SystemSecretStore::SecretService(service)
    }

    /// For logs and status: `Secret Service` or `file <path>`.
    pub fn describe(&self) -> String {
        match self {
            SystemSecretStore::SecretService(_) => "Secret Service".into(),
            SystemSecretStore::File(f) => format!("file {}", f.path().display()),
        }
    }

    pub fn is_fallback(&self) -> bool {
        matches!(self, SystemSecretStore::File(_))
    }
}

impl SecretStore for SystemSecretStore {
    async fn secret(&self, account: &str) -> Result<Option<Vec<u8>>> {
        match self {
            SystemSecretStore::SecretService(s) => s.secret(account).await,
            SystemSecretStore::File(f) => f.secret(account).await,
        }
    }

    async fn set_secret(&self, account: &str, secret: &[u8]) -> Result<()> {
        match self {
            SystemSecretStore::SecretService(s) => s.set_secret(account, secret).await,
            SystemSecretStore::File(f) => f.set_secret(account, secret).await,
        }
    }

    async fn remove_secret(&self, account: &str) -> Result<()> {
        match self {
            SystemSecretStore::SecretService(s) => s.remove_secret(account).await,
            SystemSecretStore::File(f) => f.remove_secret(account).await,
        }
    }

    async fn all_secrets(&self) -> Result<BTreeMap<String, Vec<u8>>> {
        match self {
            SystemSecretStore::SecretService(s) => s.all_secrets().await,
            SystemSecretStore::File(f) => f.all_secrets().await,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;

    fn assert_store<S: SecretStore>() {}

    #[test]
    fn every_backend_is_a_secret_store() {
        assert_store::<SystemSecretStore>();
        assert_store::<SecretServiceStore>();
        assert_store::<FileSecretStore>();
    }

    #[tokio::test]
    async fn the_file_backend_round_trips_through_the_enum() {
        let config = tempfile::tempdir().unwrap();
        let store = SystemSecretStore::File(FileSecretStore::new(&crate::paths::lain_dir(config.path())));
        assert!(store.is_fallback());
        assert!(store.describe().starts_with("file "));
        store.set_secret("serial", &[5; 32]).await.unwrap();
        assert_eq!(store.secret("serial").await.unwrap(), Some(vec![5; 32]));
        assert_eq!(store.all_secrets().await.unwrap().len(), 1);
        store.remove_secret("serial").await.unwrap();
        assert!(store.all_secrets().await.unwrap().is_empty());
    }

    /// Review S3/R7 (and S5's choice cases): the file only where there is definitely no Secret Service; a
    /// locked or misbehaving one is kept, and one that appears while it is asked again is found.
    #[tokio::test(flavor = "multi_thread")]
    async fn the_file_only_when_there_is_definitely_no_secret_service() {
        use fake_service::{new_ring, serve, stop};

        let test = "secrets::tests::the_file_only_when_there_is_definitely_no_secret_service";
        let Some(bus) = fake_service::private_session_bus(test).await else { return };
        let config = tempfile::tempdir().unwrap();
        let dir = crate::paths::lain_dir(config.path());
        let choose = async |retry: Duration| {
            SystemSecretStore::choose(
                SecretServiceStore::new("sub.dev.lain.pairing.test"),
                FileSecretStore::new(&dir),
                retry,
            )
            .await
        };
        let quick = Duration::from_millis(10);

        assert!(choose(quick).await.is_fallback(), "no Secret Service");

        let ring = new_ring();
        let daemon = serve(&bus, &ring).await;
        assert_eq!(choose(quick).await.describe(), "Secret Service");
        stop(daemon, &bus).await;

        ring.lock().unwrap().locked = true;
        let daemon = serve(&bus, &ring).await;
        assert_eq!(choose(quick).await.describe(), "Secret Service", "locked");
        stop(daemon, &bus).await;

        let ring = new_ring();
        ring.lock().unwrap().refuse_sessions = true;
        let daemon = serve(&bus, &ring).await;
        assert_eq!(choose(quick).await.describe(), "Secret Service", "answering with an error");
        stop(daemon, &bus).await;

        let ring = new_ring();
        ring.lock().unwrap().has_default = false;
        let daemon = serve(&bus, &ring).await;
        assert!(choose(quick).await.is_fallback(), "no default collection");
        stop(daemon, &bus).await;

        // Starting while it is asked again (gnome-keyring at login).
        let ring = new_ring();
        let late = {
            let (bus, ring) = (bus.clone(), Arc::clone(&ring));
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(100)).await;
                serve(&bus, &ring).await
            })
        };
        assert_eq!(choose(Duration::from_millis(400)).await.describe(), "Secret Service", "appeared late");
        drop(late.await.unwrap());
    }
}
