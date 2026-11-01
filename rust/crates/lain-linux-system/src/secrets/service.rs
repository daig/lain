//! Pairing secrets in the Secret Service (gnome-keyring), through `oo7`.

use std::collections::BTreeMap;
use std::sync::Arc;

use lain_platform::{PlatformError, Result, SecretStore};
use oo7::dbus::{Collection, Error as DbusError, Item, Service, ServiceError};
use tokio::sync::Mutex;
use tracing::debug;

/// The item attribute naming the service (Swift: `kSecAttrService`).
pub const SERVICE_ATTRIBUTE: &str = "service";
/// The item attribute naming the account (Swift: `kSecAttrAccount`).
pub const ACCOUNT_ATTRIBUTE: &str = "account";

/// Pairing secrets as Secret Service items in the default collection (Swift: `KeychainSecretStore`), one
/// item per account, with the attributes `service` (Swift's `kSecAttrService`, by default
/// [`PAIRING_SERVICE`](super::PAIRING_SERVICE)) and `account` (`kSecAttrAccount`).
///
/// It never prompts: it never unlocks a collection or an item and never creates a collection. A locked
/// default collection makes every call fail with [`PlatformError::Denied`]; a missing one (or no Secret
/// Service) with [`PlatformError::Unavailable`]. Intended differences from Swift's Keychain items:
/// - The Keychain's `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` has no equivalent; the items live as
///   long as the user's login keyring, which gnome-keyring unlocks at login.
/// - Items get a label, `lain pairing <account>`, which Seahorse shows.
///
/// The D-Bus session (and so the connection) is opened on first use and opened again after a D-Bus error,
/// so a restarted gnome-keyring is picked up.
#[derive(Debug)]
pub struct SecretServiceStore {
    service_attribute: String,
    connection: Mutex<Option<Arc<Service>>>,
}

impl SecretServiceStore {
    /// Items with the `service` attribute `service_attribute`; tests use their own, so that they never touch
    /// real pairings (Swift's hosted tests use `sub.dev.lain.pairing.test`).
    pub fn new(service_attribute: impl Into<String>) -> SecretServiceStore {
        SecretServiceStore { service_attribute: service_attribute.into(), connection: Mutex::new(None) }
    }

    pub fn service_attribute(&self) -> &str {
        &self.service_attribute
    }

    /// Checks that the Secret Service answers and has an unlocked default collection, without prompting.
    pub async fn probe(&self) -> Result<()> {
        self.collection().await.map(|_| ())
    }

    async fn service(&self) -> Result<Arc<Service>> {
        let mut connection = self.connection.lock().await;
        if let Some(service) = connection.as_ref() {
            return Ok(Arc::clone(service));
        }
        let service =
            Arc::new(Service::new().await.map_err(|e| PlatformError::Unavailable(format!("no Secret Service: {e}")))?);
        *connection = Some(Arc::clone(&service));
        Ok(service)
    }

    /// The default collection, unlocked. Never creates one (`Service::default_collection` would).
    async fn collection(&self) -> Result<Collection> {
        let service = self.service().await?;
        let collection = self
            .checked(service.with_alias(Service::DEFAULT_COLLECTION).await)
            .await?
            .ok_or_else(|| PlatformError::Unavailable("the Secret Service has no default collection".into()))?;
        if self.checked(collection.is_locked().await).await? {
            return Err(PlatformError::Denied("the default keyring collection is locked".into()));
        }
        Ok(collection)
    }

    /// Maps an `oo7` error, forgetting the connection after a D-Bus-level failure.
    async fn checked<T>(&self, result: std::result::Result<T, DbusError>) -> Result<T> {
        match result {
            Ok(value) => Ok(value),
            Err(e) => {
                if matches!(e, DbusError::ZBus(_) | DbusError::IO(_)) {
                    debug!(error = %e, "Secret Service D-Bus error; reconnecting on the next call");
                    // Never held across another await, so this can't deadlock.
                    *self.connection.lock().await = None;
                }
                Err(map_error(&e))
            }
        }
    }

    async fn items(&self, collection: &Collection, account: Option<&str>) -> Result<Vec<Item>> {
        let mut attributes = vec![(SERVICE_ATTRIBUTE, self.service_attribute.as_str())];
        if let Some(account) = account {
            attributes.push((ACCOUNT_ATTRIBUTE, account));
        }
        self.checked(collection.search_items(&attributes).await).await
    }

    /// An item's secret, or `None` (with a note) if the item is locked: one odd item mustn't hide others.
    async fn read(&self, item: &Item) -> Result<Option<Vec<u8>>> {
        if self.checked(item.is_locked().await).await? {
            debug!(path = %item.path(), "skipping a locked Secret Service item");
            return Ok(None);
        }
        Ok(Some(self.checked(item.secret().await).await?.as_bytes().to_vec()))
    }
}

fn map_error(e: &DbusError) -> PlatformError {
    match e {
        DbusError::Service(ServiceError::IsLocked(m)) => PlatformError::Denied(format!("Secret Service locked: {m}")),
        DbusError::Dismissed => PlatformError::Denied("a Secret Service prompt was dismissed".into()),
        DbusError::NotFound(_) | DbusError::Deleted => PlatformError::Unavailable(format!("Secret Service: {e}")),
        DbusError::ZBus(zbus::Error::MethodError(name, _, _))
            if name.as_str() == "org.freedesktop.DBus.Error.ServiceUnknown"
                || name.as_str() == "org.freedesktop.DBus.Error.NameHasNoOwner" =>
        {
            PlatformError::Unavailable(format!("no Secret Service: {e}"))
        }
        _ => PlatformError::Failed(format!("Secret Service: {e}")),
    }
}

impl SecretStore for SecretServiceStore {
    async fn secret(&self, account: &str) -> Result<Option<Vec<u8>>> {
        let collection = self.collection().await?;
        for item in self.items(&collection, Some(account)).await? {
            if let Some(secret) = self.read(&item).await? {
                return Ok(Some(secret));
            }
        }
        Ok(None)
    }

    async fn set_secret(&self, account: &str, secret: &[u8]) -> Result<()> {
        let collection = self.collection().await?;
        let attributes = [(SERVICE_ATTRIBUTE, self.service_attribute.as_str()), (ACCOUNT_ATTRIBUTE, account)];
        // `replace`: an item with exactly these attributes gets the new secret (Swift: `SecItemUpdate`, else
        // `SecItemAdd`).
        let label = format!("lain pairing {account}");
        self.checked(collection.create_item(&label, &attributes, oo7::Secret::blob(secret), true, None).await)
            .await
            .map(|_| ())
    }

    async fn remove_secret(&self, account: &str) -> Result<()> {
        let collection = self.collection().await?;
        // Every matching item: a duplicate (say, from another tool adding attributes) would otherwise
        // resurface the secret.
        for item in self.items(&collection, Some(account)).await? {
            match item.delete(None).await {
                Ok(()) | Err(DbusError::Deleted) => {}
                Err(e) => return self.checked(Err(e)).await,
            }
        }
        Ok(())
    }

    async fn all_secrets(&self) -> Result<BTreeMap<String, Vec<u8>>> {
        let collection = self.collection().await?;
        let mut secrets = BTreeMap::new();
        for item in self.items(&collection, None).await? {
            // Skipped, not fatal (Swift: `KeychainSecretStore.secrets(fromItems:)`): an item without an
            // account, or a locked one.
            let Some(account) = self.checked(item.attributes().await).await?.remove(ACCOUNT_ATTRIBUTE) else {
                continue;
            };
            if secrets.contains_key(&account) {
                continue; // The first wins, as in Swift.
            }
            if let Some(secret) = self.read(&item).await? {
                secrets.insert(account, secret);
            }
        }
        Ok(secrets)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_map_to_the_contract() {
        assert!(matches!(map_error(&DbusError::Service(ServiceError::IsLocked("x".into()))), PlatformError::Denied(_)));
        assert!(matches!(map_error(&DbusError::Dismissed), PlatformError::Denied(_)));
        assert!(matches!(map_error(&DbusError::NotFound("default".into())), PlatformError::Unavailable(_)));
        assert!(matches!(map_error(&DbusError::Deleted), PlatformError::Unavailable(_)));
        assert!(matches!(map_error(&DbusError::IO(std::io::Error::other("x"))), PlatformError::Failed(_)));
    }

    /// The live round trip under a test-only `service` attribute (Swift's hosted
    /// `KeychainSecretStoreTests`, both tests): never the real pairings, never a prompt. Skips when the
    /// Secret Service or its default collection is missing or locked.
    #[tokio::test]
    #[ignore = "uses the desktop's Secret Service (gnome-keyring) under a test attribute"]
    async fn live_keyring_round_trip() {
        let store = SecretServiceStore::new(format!("sub.dev.lain.pairing.test.{}", std::process::id()));
        match store.probe().await {
            Ok(()) => {}
            Err(e @ (PlatformError::Unavailable(_) | PlatformError::Denied(_))) => {
                eprintln!("skipped: {e}");
                return;
            }
            Err(e) => panic!("{e}"),
        }
        let cleanup = async |store: &SecretServiceStore| {
            for account in store.all_secrets().await.unwrap().keys() {
                store.remove_secret(account).await.unwrap();
            }
        };
        cleanup(&store).await;
        assert!(store.all_secrets().await.unwrap().is_empty());

        store.remove_secret("host").await.unwrap();
        assert_eq!(store.secret("host").await.unwrap(), None);
        store.set_secret("host", &[7; 32]).await.unwrap();
        assert_eq!(store.secret("host").await.unwrap(), Some(vec![7; 32]));
        store.set_secret("host", &[9; 32]).await.unwrap();
        assert_eq!(store.secret("host").await.unwrap(), Some(vec![9; 32]));

        let wifi = "mac:6F9619FF-8B86-D011-B42D-00C04FC964FF";
        store.set_secret(wifi, &[2; 32]).await.unwrap();
        let listed = store.all_secrets().await.unwrap();
        assert_eq!(listed, BTreeMap::from([("host".to_owned(), vec![9; 32]), (wifi.to_owned(), vec![2; 32])]));
        // Another service attribute sees none of them.
        let other = SecretServiceStore::new(format!("{}.other", store.service_attribute()));
        assert!(other.all_secrets().await.unwrap().is_empty());

        store.remove_secret("host").await.unwrap();
        assert_eq!(store.secret("host").await.unwrap(), None);
        cleanup(&store).await;
        assert!(store.all_secrets().await.unwrap().is_empty());
    }
}
