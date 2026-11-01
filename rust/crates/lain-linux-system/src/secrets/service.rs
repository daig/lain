//! Pairing secrets in the Secret Service (gnome-keyring), through `oo7`.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

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
/// default collection makes every call fail with [`PlatformError::Denied`]; a missing one, no session bus,
/// or no Secret Service on it (the name unowned and not activatable, or gone) with
/// [`PlatformError::Unavailable`]; anything else (a Secret Service that answers with an error, or doesn't
/// answer within oo7's 30 s) with [`PlatformError::Failed`]. Intended differences from Swift's Keychain
/// items:
/// - The Keychain's `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` has no equivalent; the items live as
///   long as the user's login keyring, which gnome-keyring unlocks at login.
/// - Items get a label, `lain pairing <account>`, which Seahorse shows.
///
/// The Secret Service session (and so the connection) is opened on first use and dropped after an error
/// that may mean it is stale: any D-Bus-level error, or the service's `NoSession`/`NoSuchObject`. The
/// call is then made once more on a new session, so a restarted gnome-keyring (which has forgotten our
/// session) is picked up by the very next call. Every call is idempotent, so the repeat is safe.
#[derive(Debug)]
pub struct SecretServiceStore {
    service_attribute: String,
    connection: Mutex<Option<Arc<Service>>>,
    /// How many times the connection was dropped as possibly stale: a call that saw it change retries.
    reconnects: AtomicU64,
}

/// `$op`, an expression making one attempt, made once more if it failed and the connection was dropped as
/// possibly stale meanwhile (see [`SecretServiceStore`]).
macro_rules! once_more_on_a_new_session {
    ($store:expr, $op:expr) => {{
        let before = $store.reconnects.load(Ordering::SeqCst);
        match $op {
            Err(e) if $store.reconnects.load(Ordering::SeqCst) != before => {
                debug!(error = %e, "Secret Service call failed on a stale session; once more on a new one");
                $op
            }
            result => result,
        }
    }};
}

impl SecretServiceStore {
    /// Items with the `service` attribute `service_attribute`; tests use their own, so that they never touch
    /// real pairings (Swift's hosted tests use `sub.dev.lain.pairing.test`).
    pub fn new(service_attribute: impl Into<String>) -> SecretServiceStore {
        SecretServiceStore {
            service_attribute: service_attribute.into(),
            connection: Mutex::new(None),
            reconnects: AtomicU64::new(0),
        }
    }

    pub fn service_attribute(&self) -> &str {
        &self.service_attribute
    }

    /// Checks that the Secret Service answers and has an unlocked default collection, without prompting.
    pub async fn probe(&self) -> Result<()> {
        once_more_on_a_new_session!(self, self.collection().await.map(|_| ()))
    }

    async fn service(&self) -> Result<Arc<Service>> {
        let mut connection = self.connection.lock().await;
        if let Some(service) = connection.as_ref() {
            return Ok(Arc::clone(service));
        }
        let service = Arc::new(Service::new().await.map_err(|e| {
            if is_absent(&e) {
                PlatformError::Unavailable(format!("no Secret Service: {e}"))
            } else {
                PlatformError::Failed(format!("opening a Secret Service session: {e}"))
            }
        })?);
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

    /// Maps an `oo7` error, forgetting the connection after one that may mean it is stale.
    ///
    /// oo7 0.6 wraps a method call's error as `Service(ServiceError::…)`, a D-Bus-level one included
    /// (`Service(ServiceError::ZBus(…))`); property reads give a bare `ZBus`.
    async fn checked<T>(&self, result: std::result::Result<T, DbusError>) -> Result<T> {
        match result {
            Ok(value) => Ok(value),
            Err(e) => {
                if matches!(
                    e,
                    DbusError::ZBus(_)
                        | DbusError::IO(_)
                        | DbusError::Service(
                            ServiceError::ZBus(_) | ServiceError::NoSession(_) | ServiceError::NoSuchObject(_)
                        )
                ) {
                    debug!(error = %e, "Secret Service error; a new session for the next call");
                    // Never held across another await, so this can't deadlock.
                    *self.connection.lock().await = None;
                    self.reconnects.fetch_add(1, Ordering::SeqCst);
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
        _ if is_absent(e) => PlatformError::Unavailable(format!("no Secret Service: {e}")),
        _ => PlatformError::Failed(format!("Secret Service: {e}")),
    }
}

/// Whether `e` says there is no Secret Service to talk to: no session bus to connect to, the name
/// unowned (and not activatable), or the bus gone. Not a timeout: a hung gnome-keyring is there.
fn is_absent(e: &DbusError) -> bool {
    let (DbusError::ZBus(e) | DbusError::Service(ServiceError::ZBus(e))) = e else { return false };
    match e {
        zbus::Error::MethodError(name, _, _) => matches!(
            name.as_str(),
            "org.freedesktop.DBus.Error.ServiceUnknown"
                | "org.freedesktop.DBus.Error.NameHasNoOwner"
                | "org.freedesktop.DBus.Error.Disconnected"
        ),
        zbus::Error::Address(_) => true,
        zbus::Error::InputOutput(io) => io.kind() != std::io::ErrorKind::TimedOut,
        _ => false,
    }
}

impl SecretStore for SecretServiceStore {
    async fn secret(&self, account: &str) -> Result<Option<Vec<u8>>> {
        once_more_on_a_new_session!(self, self.secret_once(account).await)
    }

    async fn set_secret(&self, account: &str, secret: &[u8]) -> Result<()> {
        once_more_on_a_new_session!(self, self.set_secret_once(account, secret).await)
    }

    async fn remove_secret(&self, account: &str) -> Result<()> {
        once_more_on_a_new_session!(self, self.remove_secret_once(account).await)
    }

    async fn all_secrets(&self) -> Result<BTreeMap<String, Vec<u8>>> {
        once_more_on_a_new_session!(self, self.all_secrets_once().await)
    }
}

/// One attempt of each [`SecretStore`] call.
impl SecretServiceStore {
    async fn secret_once(&self, account: &str) -> Result<Option<Vec<u8>>> {
        let collection = self.collection().await?;
        for item in self.items(&collection, Some(account)).await? {
            if let Some(secret) = self.read(&item).await? {
                return Ok(Some(secret));
            }
        }
        Ok(None)
    }

    async fn set_secret_once(&self, account: &str, secret: &[u8]) -> Result<()> {
        let collection = self.collection().await?;
        let attributes = [(SERVICE_ATTRIBUTE, self.service_attribute.as_str()), (ACCOUNT_ATTRIBUTE, account)];
        // `replace`: an item with exactly these attributes gets the new secret (Swift: `SecItemUpdate`, else
        // `SecItemAdd`).
        let label = format!("lain pairing {account}");
        self.checked(collection.create_item(&label, &attributes, oo7::Secret::blob(secret), true, None).await)
            .await
            .map(|_| ())
    }

    async fn remove_secret_once(&self, account: &str) -> Result<()> {
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

    async fn all_secrets_once(&self) -> Result<BTreeMap<String, Vec<u8>>> {
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
    use crate::secrets::fake_service::{self, private_session_bus};

    fn method_error(name: &str) -> zbus::Error {
        let message = zbus::message::Message::method_call("/", "Ping").unwrap().build(&()).unwrap();
        zbus::Error::MethodError(name.try_into().unwrap(), Some("x".into()), message)
    }

    /// In the shapes oo7 0.6 gives: a method call's error wrapped as `Service(…)`, a property read's bare.
    #[test]
    fn errors_map_to_the_contract() {
        assert!(matches!(map_error(&DbusError::Service(ServiceError::IsLocked("x".into()))), PlatformError::Denied(_)));
        assert!(matches!(map_error(&DbusError::Dismissed), PlatformError::Denied(_)));
        assert!(matches!(map_error(&DbusError::NotFound("default".into())), PlatformError::Unavailable(_)));
        assert!(matches!(map_error(&DbusError::Deleted), PlatformError::Unavailable(_)));
        assert!(matches!(map_error(&DbusError::IO(std::io::Error::other("x"))), PlatformError::Failed(_)));
        for gone in ["org.freedesktop.DBus.Error.ServiceUnknown", "org.freedesktop.DBus.Error.NameHasNoOwner"] {
            let wrapped = DbusError::Service(ServiceError::ZBus(method_error(gone)));
            assert!(matches!(map_error(&wrapped), PlatformError::Unavailable(_)), "{wrapped}");
            assert!(matches!(map_error(&DbusError::ZBus(method_error(gone))), PlatformError::Unavailable(_)));
        }
        let no_session = DbusError::Service(ServiceError::NoSession("x".into()));
        assert!(matches!(map_error(&no_session), PlatformError::Failed(_)));
        // A timeout is a daemon that is there but hung, not a missing one.
        let timed_out = zbus::Error::from(std::io::Error::new(std::io::ErrorKind::TimedOut, "timed out"));
        assert!(matches!(map_error(&DbusError::ZBus(timed_out)), PlatformError::Failed(_)));
        let refused = zbus::Error::from(std::io::Error::from(std::io::ErrorKind::ConnectionRefused));
        assert!(matches!(map_error(&DbusError::ZBus(refused)), PlatformError::Unavailable(_)));
    }

    /// The round trip of Swift's hosted `KeychainSecretStoreTests` (both tests), on an empty store.
    async fn round_trip(store: &SecretServiceStore) {
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
        store.remove_secret(wifi).await.unwrap();
        assert!(store.all_secrets().await.unwrap().is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_round_trip_against_a_fake_secret_service() {
        let test = "secrets::service::tests::the_round_trip_against_a_fake_secret_service";
        let Some(bus) = private_session_bus(test).await else { return };
        let ring = fake_service::new_ring();
        // Someone else's item, which must stay untouched and unlisted.
        fake_service::add_item(&ring, &[("service", "elsewhere"), ("account", "host")], &[1]);
        let _daemon = fake_service::serve(&bus, &ring).await;
        round_trip(&SecretServiceStore::new(PAIRING_TEST_SERVICE)).await;
        let ring = ring.lock().unwrap();
        assert_eq!(ring.items.len(), 1);
        assert_eq!(ring.items[0].secret, [1]);
    }

    /// Review S1/R1: gnome-keyring restarting (crash, OOM kill, `--replace`) forgets our session; the store
    /// must not keep using it. While it is gone, calls are `Unavailable`.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_restarted_secret_service_is_picked_up() {
        let test = "secrets::service::tests::a_restarted_secret_service_is_picked_up";
        let Some(bus) = private_session_bus(test).await else { return };
        let ring = fake_service::new_ring();
        fake_service::add_item(&ring, &[("service", PAIRING_TEST_SERVICE), ("account", "host")], &[7; 32]);
        let daemon = fake_service::serve(&bus, &ring).await;
        let store = SecretServiceStore::new(PAIRING_TEST_SERVICE);
        assert_eq!(store.secret("host").await.unwrap(), Some(vec![7; 32]));

        // Gone, then back: the first call after the restart already works.
        fake_service::stop(daemon, &bus).await;
        let gone = store.secret("host").await;
        assert!(matches!(gone, Err(PlatformError::Unavailable(_))), "{gone:?}");
        let daemon = fake_service::serve(&bus, &ring).await;
        assert_eq!(store.secret("host").await.unwrap(), Some(vec![7; 32]));

        // Restarted between two calls (the cached session is stale): each call works first time.
        fake_service::stop(daemon, &bus).await;
        let daemon = fake_service::serve(&bus, &ring).await;
        assert_eq!(store.secret("host").await.unwrap(), Some(vec![7; 32]));
        fake_service::stop(daemon, &bus).await;
        let _daemon = fake_service::serve(&bus, &ring).await;
        store.set_secret("ipad", &[3; 32]).await.unwrap();
        assert_eq!(store.all_secrets().await.unwrap().len(), 2);
    }

    /// Review S5: a locked default collection is `Denied`, without a prompt and without trying to write.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_locked_collection_is_denied_without_prompting() {
        let test = "secrets::service::tests::a_locked_collection_is_denied_without_prompting";
        let Some(bus) = private_session_bus(test).await else { return };
        let ring = fake_service::new_ring();
        fake_service::add_item(&ring, &[("service", PAIRING_TEST_SERVICE), ("account", "host")], &[7; 32]);
        ring.lock().unwrap().locked = true;
        let _daemon = fake_service::serve(&bus, &ring).await;
        let store = SecretServiceStore::new(PAIRING_TEST_SERVICE);
        assert!(matches!(store.probe().await, Err(PlatformError::Denied(_))));
        assert!(matches!(store.secret("host").await, Err(PlatformError::Denied(_))));
        assert!(matches!(store.set_secret("host", &[1]).await, Err(PlatformError::Denied(_))));
        assert!(matches!(store.remove_secret("host").await, Err(PlatformError::Denied(_))));
        assert!(matches!(store.all_secrets().await, Err(PlatformError::Denied(_))));
        let ring = ring.lock().unwrap();
        assert_eq!(ring.create_calls, 0);
        assert_eq!(ring.items.len(), 1);
    }

    /// Review S5: no Secret Service on the bus, or one without a default collection, is `Unavailable`.
    #[tokio::test(flavor = "multi_thread")]
    async fn no_secret_service_or_no_default_collection_is_unavailable() {
        let test = "secrets::service::tests::no_secret_service_or_no_default_collection_is_unavailable";
        let Some(bus) = private_session_bus(test).await else { return };
        let store = SecretServiceStore::new(PAIRING_TEST_SERVICE);
        assert!(matches!(store.probe().await, Err(PlatformError::Unavailable(_))));
        assert!(matches!(store.secret("host").await, Err(PlatformError::Unavailable(_))));

        let ring = fake_service::new_ring();
        ring.lock().unwrap().has_default = false;
        let _daemon = fake_service::serve(&bus, &ring).await;
        let store = SecretServiceStore::new(PAIRING_TEST_SERVICE);
        assert!(matches!(store.probe().await, Err(PlatformError::Unavailable(_))));
        assert!(matches!(store.set_secret("host", &[1]).await, Err(PlatformError::Unavailable(_))));
        assert_eq!(ring.lock().unwrap().create_calls, 0);
    }

    /// Swift's hosted tests' own service attribute: never the real pairings.
    const PAIRING_TEST_SERVICE: &str = "sub.dev.lain.pairing.test";

    /// The live round trip under [`PAIRING_TEST_SERVICE`] (Swift's hosted `KeychainSecretStoreTests`): never
    /// the real pairings, never a prompt. Skips when the Secret Service or its default collection is
    /// missing or locked. The test's items are removed first (what a crashed run left) and last, even
    /// after a failed assertion.
    #[tokio::test]
    #[ignore = "uses the desktop's Secret Service (gnome-keyring) under a test attribute"]
    async fn live_keyring_round_trip() {
        use futures::FutureExt;

        let store = SecretServiceStore::new(PAIRING_TEST_SERVICE);
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
        let outcome = std::panic::AssertUnwindSafe(round_trip(&store)).catch_unwind().await;
        cleanup(&store).await;
        if let Err(panic) = outcome {
            std::panic::resume_unwind(panic);
        }
    }
}
