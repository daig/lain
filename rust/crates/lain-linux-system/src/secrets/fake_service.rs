//! A fake Secret Service (`org.freedesktop.secrets`) for tests, and a way to run a test with a private
//! bus as its session bus.
//!
//! oo7 0.6 builds its `Service` only on the session bus (`DBUS_SESSION_BUS_ADDRESS`), and setting that in
//! the test process would need `unsafe` and race the other tests. So a test that talks to the fake runs
//! itself again in a child process whose environment names a private [`TestBus`]; see
//! [`private_session_bus`].
//!
//! The fake keeps what the store's calls need: plain sessions only (the encrypted algorithm is refused,
//! so oo7 falls back to plain, as against an old gnome-keyring), one collection (the `default` alias, or
//! none), items with attributes, and the errors gnome-keyring gives: `NoSession` for a session it doesn't
//! know (a restarted daemon), `IsLocked` for a locked collection. It never offers a prompt.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

use crate::testbus::TestBus;

/// Set in a child process run by [`private_session_bus`]: the private bus's address.
const CHILD_BUS: &str = "LAIN_TEST_PRIVATE_SESSION_BUS";

/// In the test process: starts a private bus, runs the test `test` (its full path, such as
/// `secrets::service::tests::x`) again in a child process whose session bus that is, asserts that it
/// passed, and returns `None` (also when there's no `dbus-daemon`). In that child: the bus's address.
pub(crate) async fn private_session_bus(test: &str) -> Option<String> {
    if let Ok(address) = std::env::var(CHILD_BUS) {
        return Some(address);
    }
    let bus = TestBus::start().await?;
    let output = tokio::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", test, "--nocapture", "--test-threads=1"])
        .env(CHILD_BUS, bus.address())
        .env("DBUS_SESSION_BUS_ADDRESS", bus.address())
        .output()
        .await
        .unwrap();
    let (stdout, stderr) = (String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
    assert!(
        output.status.success() && stdout.contains("test result: ok. 1 passed"),
        "{test} failed in its child process:\n{stdout}\n{stderr}"
    );
    None
}

const SERVICE_PATH: &str = "/org/freedesktop/secrets";
const COLLECTION_PATH: &str = "/org/freedesktop/secrets/collection/login";
const NAME: &str = "org.freedesktop.secrets";

fn session_path(generation: u32) -> String {
    format!("/org/freedesktop/secrets/session/g{generation}")
}

fn item_path(id: u32) -> String {
    format!("{COLLECTION_PATH}/i{id}")
}

fn path(p: &str) -> OwnedObjectPath {
    OwnedObjectPath::try_from(p.to_owned()).unwrap()
}

#[derive(Debug, Clone)]
pub(crate) struct FakeItem {
    pub id: u32,
    pub attributes: HashMap<String, String>,
    pub secret: Vec<u8>,
}

/// The keyring's state, kept across daemon restarts (as gnome-keyring keeps it on disk).
#[derive(Debug)]
pub(crate) struct Ring {
    /// Each start of the daemon is a new generation, with a new session path.
    pub generation: u32,
    pub locked: bool,
    pub has_default: bool,
    /// `OpenSession` fails with `org.freedesktop.DBus.Error.Failed` (a confused daemon).
    pub refuse_sessions: bool,
    pub items: Vec<FakeItem>,
    pub next_id: u32,
    /// `CreateItem` calls that reached the fake, refused or not.
    pub create_calls: usize,
}

pub(crate) type SharedRing = Arc<Mutex<Ring>>;

pub(crate) fn new_ring() -> SharedRing {
    Arc::new(Mutex::new(Ring {
        generation: 0,
        locked: false,
        has_default: true,
        refuse_sessions: false,
        items: vec![],
        next_id: 1,
        create_calls: 0,
    }))
}

/// `(attributes, secret)` items, for a test's set-up.
pub(crate) fn add_item(ring: &SharedRing, attributes: &[(&str, &str)], secret: &[u8]) {
    let mut ring = ring.lock().unwrap();
    let id = ring.next_id;
    ring.next_id += 1;
    let attributes = attributes.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    ring.items.push(FakeItem { id, attributes, secret: secret.to_vec() });
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.Secret.Error")]
enum FakeError {
    #[zbus(error)]
    ZBus(zbus::Error),
    IsLocked(String),
    NoSession(String),
    NoSuchObject(String),
}

/// The session the daemon of this generation knows, or `NoSession` (gnome-keyring forgets every session
/// when it restarts).
fn check_session(ring: &Ring, session: &OwnedObjectPath) -> Result<(), FakeError> {
    if session.as_str() == session_path(ring.generation) {
        Ok(())
    } else {
        Err(FakeError::NoSession(format!("{} is not a session", session.as_str())))
    }
}

struct Service {
    ring: SharedRing,
}

#[zbus::interface(name = "org.freedesktop.Secret.Service")]
impl Service {
    fn open_session(&self, algorithm: &str, _input: Value<'_>) -> zbus::fdo::Result<(OwnedValue, OwnedObjectPath)> {
        let ring = self.ring.lock().unwrap();
        if ring.refuse_sessions {
            return Err(zbus::fdo::Error::Failed("the fake refuses sessions".into()));
        }
        if algorithm != "plain" {
            return Err(zbus::fdo::Error::NotSupported(format!("{algorithm} is not supported")));
        }
        Ok((OwnedValue::try_from(Value::from("")).unwrap(), path(&session_path(ring.generation))))
    }

    fn read_alias(&self, name: &str) -> OwnedObjectPath {
        let ring = self.ring.lock().unwrap();
        path(if name == "default" && ring.has_default { COLLECTION_PATH } else { "/" })
    }
}

struct Session;

#[zbus::interface(name = "org.freedesktop.Secret.Session")]
impl Session {
    fn close(&self) {}
}

struct Collection {
    ring: SharedRing,
}

#[zbus::interface(name = "org.freedesktop.Secret.Collection")]
impl Collection {
    #[zbus(property)]
    fn locked(&self) -> bool {
        self.ring.lock().unwrap().locked
    }

    fn search_items(&self, attributes: HashMap<String, String>) -> Vec<OwnedObjectPath> {
        let ring = self.ring.lock().unwrap();
        ring.items
            .iter()
            .filter(|item| attributes.iter().all(|(k, v)| item.attributes.get(k) == Some(v)))
            .map(|item| path(&item_path(item.id)))
            .collect()
    }

    /// Returns no prompt (`/`): it never asks anyone.
    async fn create_item(
        &self,
        properties: HashMap<String, OwnedValue>,
        secret: (OwnedObjectPath, Vec<u8>, Vec<u8>, String),
        replace: bool,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> Result<(OwnedObjectPath, OwnedObjectPath), FakeError> {
        let attributes: HashMap<String, String> = properties
            .get("org.freedesktop.Secret.Item.Attributes")
            .map(|v| HashMap::try_from(v.try_clone().unwrap()).unwrap())
            .unwrap_or_default();
        let (id, new) = {
            let mut ring = self.ring.lock().unwrap();
            ring.create_calls += 1;
            if ring.locked {
                return Err(FakeError::IsLocked("the collection is locked".into()));
            }
            check_session(&ring, &secret.0)?;
            match ring.items.iter_mut().find(|item| replace && item.attributes == attributes) {
                Some(item) => {
                    item.secret = secret.2;
                    (item.id, false)
                }
                None => {
                    let id = ring.next_id;
                    ring.next_id += 1;
                    ring.items.push(FakeItem { id, attributes, secret: secret.2 });
                    (id, true)
                }
            }
        };
        if new {
            server.at(item_path(id), Item { ring: Arc::clone(&self.ring), id }).await?;
        }
        Ok((path(&item_path(id)), path("/")))
    }
}

struct Item {
    ring: SharedRing,
    id: u32,
}

impl Item {
    fn with<T>(&self, f: impl FnOnce(&mut Ring, usize) -> T) -> Result<T, FakeError> {
        let mut ring = self.ring.lock().unwrap();
        let index = ring
            .items
            .iter()
            .position(|item| item.id == self.id)
            .ok_or_else(|| FakeError::NoSuchObject(format!("no item {}", self.id)))?;
        Ok(f(&mut ring, index))
    }
}

#[zbus::interface(name = "org.freedesktop.Secret.Item")]
impl Item {
    #[zbus(property)]
    fn locked(&self) -> bool {
        self.ring.lock().unwrap().locked
    }

    #[zbus(property)]
    fn attributes(&self) -> zbus::fdo::Result<HashMap<String, String>> {
        self.with(|ring, i| ring.items[i].attributes.clone()).map_err(|e| zbus::fdo::Error::Failed(e.to_string()))
    }

    fn get_secret(&self, session: OwnedObjectPath) -> Result<(OwnedObjectPath, Vec<u8>, Vec<u8>, String), FakeError> {
        self.with(|ring, i| {
            if ring.locked {
                return Err(FakeError::IsLocked("the item is locked".into()));
            }
            check_session(ring, &session)?;
            Ok((session.clone(), vec![], ring.items[i].secret.clone(), "application/octet-stream".into()))
        })?
    }

    async fn delete(&self, #[zbus(object_server)] server: &zbus::ObjectServer) -> Result<OwnedObjectPath, FakeError> {
        self.with(|ring, i| {
            if ring.locked {
                return Err(FakeError::IsLocked("the collection is locked".into()));
            }
            ring.items.remove(i);
            Ok(())
        })??;
        server.remove::<Item, _>(item_path(self.id)).await?;
        Ok(path("/"))
    }
}

/// Starts the fake daemon (a new generation) on the bus at `address`, owning `org.freedesktop.secrets`;
/// dropping the connection is the daemon exiting.
pub(crate) async fn serve(address: &str, ring: &SharedRing) -> zbus::Connection {
    let (generation, ids) = {
        let mut ring = ring.lock().unwrap();
        ring.generation += 1;
        (ring.generation, ring.items.iter().map(|item| item.id).collect::<Vec<_>>())
    };
    let connection = zbus::connection::Builder::address(address).unwrap().build().await.unwrap();
    let server = connection.object_server();
    server.at(SERVICE_PATH, Service { ring: Arc::clone(ring) }).await.unwrap();
    server.at(session_path(generation), Session).await.unwrap();
    server.at(COLLECTION_PATH, Collection { ring: Arc::clone(ring) }).await.unwrap();
    for id in ids {
        server.at(item_path(id), Item { ring: Arc::clone(ring), id }).await.unwrap();
    }
    connection.request_name(NAME).await.unwrap();
    connection
}

/// Stops a fake daemon and waits until its name is gone from the bus.
pub(crate) async fn stop(daemon: zbus::Connection, address: &str) {
    drop(daemon);
    let observer = zbus::connection::Builder::address(address).unwrap().build().await.unwrap();
    let dbus = zbus::fdo::DBusProxy::new(&observer).await.unwrap();
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(5);
    while dbus.name_has_owner(NAME.try_into().unwrap()).await.unwrap() {
        assert!(tokio::time::Instant::now() < deadline, "the fake Secret Service never went away");
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
}
