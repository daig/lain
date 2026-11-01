//! Pairing secrets (Swift: `SecretStore` and `KeychainSecretStore`, `LainTransport/Security.swift`).
//!
//! Accounts are whatever `lain-link` names (Swift: `PairingAccounts`; on the host, the iPad's USB
//! serial). Two backends: the Secret Service ([`SecretServiceStore`]) and a 0600 file
//! ([`FileSecretStore`]). [`SystemSecretStore`] chooses between them once, at startup.

mod file;
mod service;

use std::collections::BTreeMap;
use std::path::Path;

use lain_platform::{PlatformError, Result, SecretStore};
use tracing::{info, warn};

pub use file::{FileSecretStore, SECRETS_FILE};
pub use service::{ACCOUNT_ATTRIBUTE, SERVICE_ATTRIBUTE, SecretServiceStore};

/// The `service` attribute of lain's pairing items: Swift's `KeychainSecretStore` default service.
pub const PAIRING_SERVICE: &str = "sub.dev.lain.pairing";

/// The pairing store `lain-hostd` uses: one concrete type (`SecretStore` isn't object safe), choosing its
/// backend at runtime with [`open`](Self::open).
#[derive(Debug)]
pub enum SystemSecretStore {
    SecretService(SecretServiceStore),
    File(FileSecretStore),
}

impl SystemSecretStore {
    /// The Secret Service under [`PAIRING_SERVICE`] if it answers and has a default collection, else the
    /// file in `lain_dir` (`$XDG_CONFIG_HOME/lain`; logged as a warning).
    ///
    /// The choice is made once. A *locked* default collection still chooses the Secret Service (calls fail
    /// with `Denied` until the owner unlocks it): falling back then would split the pairings between two
    /// stores. For the same reason, secrets already in the fallback file are not moved into a Secret
    /// Service that appears later; that is logged.
    pub async fn open(lain_dir: &Path) -> SystemSecretStore {
        Self::choose(SecretServiceStore::new(PAIRING_SERVICE), FileSecretStore::new(lain_dir)).await
    }

    async fn choose(service: SecretServiceStore, file: FileSecretStore) -> SystemSecretStore {
        let probe = service.probe().await;
        match probe {
            Ok(()) | Err(PlatformError::Denied(_)) => {
                match probe {
                    Err(why) => warn!(%why, "pairing secrets: Secret Service, locked for now"),
                    Ok(()) => info!("pairing secrets: Secret Service"),
                }
                if file.has_secrets() {
                    warn!(path = %file.path().display(),
                        "pairing secrets in the fallback file are not used while the Secret Service is available");
                }
                SystemSecretStore::SecretService(service)
            }
            Err(why) => {
                warn!(%why, path = %file.path().display(), "pairing secrets: no usable Secret Service; using the fallback file");
                SystemSecretStore::File(file)
            }
        }
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
}
