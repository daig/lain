//! The host's Wi-Fi listener following the secret store. Port of the listener half of Swift's
//! `HostSessionWiFiTests.swift` ("Keys": the backoff, no pairing, a re-pairing, the slow read), plus the
//! boundary with `lain-host`.

mod common;

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::{T, secret_a, secret_b};
use lain_link::{ByteStream, LinkTransport};
use lain_platform::fake::MemorySecretStore;
use lain_platform::{PlatformError, SecretStore};
use lain_wifi::*;
use tokio::io::AsyncReadExt;
use tokio::sync::{Notify, mpsc, watch};

const SERIAL: &str = "00008112-000A1C2E3F04001E";

fn loopback() -> WiFiListenerOptions {
    WiFiListenerOptions {
        retry_initial: Duration::from_millis(100),
        retry_max: Duration::from_millis(150),
        ..WiFiListenerOptions::loopback()
    }
}

async fn reaches(status: &mut watch::Receiver<WiFiStatus>, want: impl Fn(&WiFiStatus) -> bool) -> WiFiStatus {
    tokio::time::timeout(T, status.wait_for(|s| want(s))).await.expect("status in time").unwrap().clone()
}

async fn listening(listener: &WiFiListener) -> u16 {
    reaches(&mut listener.status(), |s| s.port().is_some()).await.port().unwrap()
}

fn addr(port: u16) -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], port))
}

fn listener(secrets: impl SecretStore + Clone) -> (WiFiListener, mpsc::Receiver<Box<dyn ByteStream>>) {
    let (tx, rx) = mpsc::channel(8);
    (WiFiListener::new(secrets, loopback(), tx), rx)
}

/// A store whose next `fails` listings fail, counting listings and when they happened. Swift:
/// `failingLists` in the test rig.
#[derive(Clone)]
struct Flaky {
    inner: MemorySecretStore,
    fails: Arc<AtomicUsize>,
    lists: Arc<Mutex<Vec<tokio::time::Instant>>>,
}

impl Flaky {
    fn new(inner: MemorySecretStore, fails: usize) -> Self {
        Self { inner, fails: Arc::new(AtomicUsize::new(fails)), lists: Arc::default() }
    }
}

impl SecretStore for Flaky {
    async fn secret(&self, account: &str) -> lain_platform::Result<Option<Vec<u8>>> {
        self.inner.secret(account).await
    }
    async fn set_secret(&self, account: &str, secret: &[u8]) -> lain_platform::Result<()> {
        self.inner.set_secret(account, secret).await
    }
    async fn remove_secret(&self, account: &str) -> lain_platform::Result<()> {
        self.inner.remove_secret(account).await
    }
    async fn all_secrets(&self) -> lain_platform::Result<BTreeMap<String, Vec<u8>>> {
        self.lists.lock().unwrap().push(tokio::time::Instant::now());
        if self.fails.fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_sub(1)).is_ok() {
            return Err(PlatformError::Denied("keyring locked".into()));
        }
        self.inner.all_secrets().await
    }
}

#[tokio::test]
async fn nothing_listens_before_the_first_refresh_nor_without_a_pairing() {
    let store = MemorySecretStore::default();
    let (listener, _rx) = listener(store.clone());
    assert_eq!(*listener.status().borrow(), WiFiStatus::Starting);
    listener.refresh();
    assert_eq!(
        reaches(&mut listener.status(), |s| *s != WiFiStatus::Starting).await,
        WiFiStatus::Off("no paired iPad yet".into())
    );
    assert_eq!(listener.port(), None);
    assert_eq!(listener.listener_starts(), 0);

    // A USB pairing stores a secret; `lain-host`'s `secrets_changed` makes the daemon refresh.
    store.set_secret(SERIAL, &secret_a()).await.unwrap();
    listener.refresh();
    let port = listening(&listener).await;
    assert_eq!(*listener.status().borrow(), WiFiStatus::Listening { port, paired: 1 });
    assert_eq!(listener.status().borrow().title(), format!("Wi-Fi: listening on port {port} with 1 paired iPad"));
    connect(addr(port), &secret_a()).await.unwrap();
}

/// Swift: `anUnreadableKeychainIsRetriedWithBackoff`.
#[tokio::test]
async fn an_unreadable_store_is_retried_with_backoff() {
    let store = Flaky::new(MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]), 2);
    let started = Instant::now();
    let (listener, mut rx) = listener(store.clone());
    listener.refresh();
    let mut status = listener.status();
    assert_eq!(
        reaches(&mut status, |s| *s != WiFiStatus::Starting).await,
        WiFiStatus::Off("can't read the pairing secrets".into())
    );
    let port = listening(&listener).await;
    // Retried after 100 ms, then after 150 ms (doubled, capped): the third listing works.
    assert!(started.elapsed() >= Duration::from_millis(250));
    assert_eq!(store.lists.lock().unwrap().len(), 3);
    assert_eq!(*listener.status().borrow(), WiFiStatus::Listening { port, paired: 1 });
    let _client = connect(addr(port), &secret_a()).await.unwrap();
    assert!(tokio::time::timeout(T, rx.recv()).await.unwrap().is_some());
}

/// The backoff itself, on paused time: 2 s doubling to 60 s, with Swift's defaults.
#[tokio::test(start_paused = true)]
async fn the_backoff_doubles_up_to_a_minute() {
    let store = Flaky::new(MemorySecretStore::default(), usize::MAX);
    let (tx, _rx) = mpsc::channel(1);
    let listener = WiFiListener::new(store.clone(), WiFiListenerOptions::loopback(), tx);
    listener.refresh();
    tokio::time::sleep(Duration::from_secs(300)).await;
    let lists = store.lists.lock().unwrap().clone();
    let gaps: Vec<u64> = lists.windows(2).map(|w| (w[1] - w[0]).as_secs()).collect();
    assert_eq!(gaps[..7], [2, 4, 8, 16, 32, 60, 60]);
    assert_eq!(*listener.status().borrow(), WiFiStatus::Off("can't read the pairing secrets".into()));
}

/// A store that never answers a listing (a dead bus).
#[derive(Clone)]
struct Hanging;

impl SecretStore for Hanging {
    async fn secret(&self, _: &str) -> lain_platform::Result<Option<Vec<u8>>> {
        Ok(None)
    }
    async fn set_secret(&self, _: &str, _: &[u8]) -> lain_platform::Result<()> {
        Ok(())
    }
    async fn remove_secret(&self, _: &str) -> lain_platform::Result<()> {
        Ok(())
    }
    async fn all_secrets(&self) -> lain_platform::Result<BTreeMap<String, Vec<u8>>> {
        std::future::pending().await
    }
}

/// A read that never answers counts as failed after `read_timeout`, and is retried.
#[tokio::test(start_paused = true)]
async fn a_hanging_read_times_out_and_is_retried() {
    let (tx, _rx) = mpsc::channel(1);
    let listener = WiFiListener::new(Hanging, WiFiListenerOptions::loopback(), tx);
    listener.refresh();
    let t0 = tokio::time::Instant::now();
    let mut status = listener.status();
    let off = status.wait_for(|s| *s != WiFiStatus::Starting).await.unwrap().clone();
    assert_eq!(off, WiFiStatus::Off("can't read the pairing secrets".into()));
    assert_eq!(t0.elapsed(), WiFiListenerOptions::default().read_timeout);
}

/// Swift: `anAuthenticatedUSBLinkKeepsTheListener`.
#[tokio::test]
async fn the_same_keys_keep_the_listener() {
    let store = MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]);
    let (listener, _rx) = listener(store);
    listener.refresh();
    let port = listening(&listener).await;
    for _ in 0..3 {
        listener.refresh();
    }
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(listener.listener_starts(), 1);
    assert_eq!(listener.port(), Some(port));
}

/// Swift: `aUSBRePairingRestartsTheListenerWithTheNewKey`. Difference: the key is swapped in place; the
/// socket and its port stay.
#[tokio::test]
async fn a_re_pairing_swaps_in_the_new_key_and_keeps_the_port() {
    let store = MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]);
    let (listener, mut rx) = listener(store.clone());
    listener.refresh();
    let port = listening(&listener).await;
    store.set_secret(SERIAL, &secret_b()).await.unwrap();
    listener.refresh();
    // The new key gets in once the read is applied (the status doesn't change: same port, one pairing).
    let deadline = Instant::now() + T;
    let client = loop {
        match connect(addr(port), &secret_b()).await {
            Ok(client) => break client,
            Err(_) if Instant::now() < deadline => tokio::time::sleep(Duration::from_millis(10)).await,
            Err(e) => panic!("the new key is refused: {e}"),
        }
    };
    assert_eq!(client.psk_identity, WiFiPsk::new(&secret_b()).identity());
    let accepted = tokio::time::timeout(T, rx.recv()).await.unwrap().unwrap();
    assert_eq!(accepted.pairing_secret(), Some(&secret_b()[..]));
    // The old key is refused at TLS.
    assert_eq!(connect(addr(port), &secret_a()).await.unwrap_err(), WiFiError::UnknownIdentity);
    assert_eq!(listener.listener_starts(), 1);
    assert_eq!(listener.port(), Some(port));
}

/// A store whose next listing, once held, reads the secrets and then waits to be released, as a slow
/// Secret Service call would. Swift: `HeldListing`.
#[derive(Clone)]
struct Held {
    inner: MemorySecretStore,
    hold: Arc<AtomicUsize>,
    entered: Arc<Notify>,
    release: Arc<Notify>,
}

impl SecretStore for Held {
    async fn secret(&self, account: &str) -> lain_platform::Result<Option<Vec<u8>>> {
        self.inner.secret(account).await
    }
    async fn set_secret(&self, account: &str, secret: &[u8]) -> lain_platform::Result<()> {
        self.inner.set_secret(account, secret).await
    }
    async fn remove_secret(&self, account: &str) -> lain_platform::Result<()> {
        self.inner.remove_secret(account).await
    }
    async fn all_secrets(&self) -> lain_platform::Result<BTreeMap<String, Vec<u8>>> {
        let read = self.inner.all_secrets().await;
        if self.hold.swap(0, Ordering::SeqCst) == 1 {
            self.entered.notify_one();
            self.release.notified().await;
        }
        read
    }
}

/// Swift: `aSlowKeyReadFinishingLastDoesNotPutBackTheOldKey`.
#[tokio::test]
async fn a_slow_key_read_finishing_last_does_not_put_back_the_old_key() {
    let store = Held {
        inner: MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]),
        hold: Arc::new(AtomicUsize::new(1)),
        entered: Arc::default(),
        release: Arc::default(),
    };
    let (listener, _rx) = listener(store.clone());
    // The launch refresh reads the keys and is slow to come back...
    listener.refresh();
    tokio::time::timeout(T, store.entered.notified()).await.unwrap();
    // ...while the iPad re-pairs over USB, and the link-up's refresh reads the new key and starts listening.
    store.inner.set_secret(SERIAL, &secret_b()).await.unwrap();
    listener.refresh();
    let port = listening(&listener).await;
    assert_eq!(listener.listener_starts(), 1);
    // The slow read comes back last, with the old key: dropped.
    store.release.notify_one();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(listener.listener_starts(), 1);
    connect(addr(port), &secret_b()).await.unwrap();
    assert_eq!(connect(addr(port), &secret_a()).await.unwrap_err(), WiFiError::UnknownIdentity);
}

#[tokio::test]
async fn removing_every_pairing_stops_listening() {
    let store = MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]);
    let (listener, _rx) = listener(store.clone());
    listener.refresh();
    let port = listening(&listener).await;
    store.remove_secret(SERIAL).await.unwrap();
    listener.refresh();
    assert_eq!(
        reaches(&mut listener.status(), |s| s.port().is_none()).await,
        WiFiStatus::Off("no paired iPad yet".into())
    );
    assert_eq!(connect(addr(port), &secret_a()).await.unwrap_err(), WiFiError::Refused);
}

#[tokio::test]
async fn a_failed_bind_retries_with_backoff() {
    let taken = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = taken.local_addr().unwrap().port();
    let store = MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]);
    let (tx, _rx) = mpsc::channel(8);
    let mut options = loopback();
    options.listener.bind = addr(port);
    let listener = WiFiListener::new(store, options, tx);
    listener.refresh();
    let failed = reaches(&mut listener.status(), |s| *s != WiFiStatus::Starting).await;
    assert!(matches!(failed, WiFiStatus::Failed(_)), "{failed:?}");
    assert!(failed.title().starts_with("Wi-Fi failed: ") && failed.title().ends_with("; retrying"));
    drop(taken);
    assert_eq!(listening(&listener).await, port);
    assert_eq!(listener.listener_starts(), 1);
}

#[tokio::test]
async fn cancel_stops_listening_and_leaves_handed_over_streams_up() {
    use tokio::io::AsyncWriteExt;
    let store = MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]);
    let (listener, mut rx) = listener(store);
    listener.refresh();
    let port = listening(&listener).await;
    let mut client = connect(addr(port), &secret_a()).await.unwrap();
    let mut accepted = tokio::time::timeout(T, rx.recv()).await.unwrap().unwrap();
    listener.cancel();
    assert_eq!(reaches(&mut listener.status(), |s| s.port().is_none()).await, WiFiStatus::Off("stopped".into()));
    assert_eq!(connect(addr(port), &secret_a()).await.unwrap_err(), WiFiError::Refused);
    // A refresh after the cancel does nothing.
    listener.refresh();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(*listener.status().borrow(), WiFiStatus::Off("stopped".into()));
    client.stream.write_all(b"still up").await.unwrap();
    let mut got = [0u8; 8];
    accepted.read_exact(&mut got).await.unwrap();
    assert_eq!(&got, b"still up");
}

#[tokio::test]
async fn dropping_the_listener_closes_the_port() {
    let store = MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]);
    let (listener, _rx) = listener(store);
    listener.refresh();
    let port = listening(&listener).await;
    drop(listener);
    assert!(common::poll_until(T, || std::net::TcpStream::connect(addr(port)).is_err()).await, "the port closed");
}

/// The boundary with `lain-host`: boxed `ByteStream`s, bound to the secret TLS proved, on the given path.
#[tokio::test]
async fn handed_over_streams_are_bound_to_their_pairing_and_say_their_path() {
    let store = MemorySecretStore::with([("IPAD-1".to_owned(), secret_a()), ("IPAD-2".to_owned(), secret_b())]);
    let (listener, mut rx) = listener(store);
    listener.refresh();
    let port = listening(&listener).await;
    assert_eq!(*listener.status().borrow(), WiFiStatus::Listening { port, paired: 2 });
    for secret in [secret_a(), secret_b()] {
        let _client = connect(addr(port), &secret).await.unwrap();
        let stream = tokio::time::timeout(T, rx.recv()).await.unwrap().unwrap();
        assert_eq!(stream.pairing_secret(), Some(&secret[..]));
        assert_eq!(
            stream.link_transport(),
            LinkTransport::Network { interface: Some("lo".into()), peer_to_peer: false }
        );
    }
}

/// A full queue closes the connection rather than waiting (the brief: close it and log it).
#[tokio::test]
async fn a_full_queue_closes_the_connection() {
    let store = MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]);
    let (tx, mut rx) = mpsc::channel(1);
    let listener = WiFiListener::new(store, loopback(), tx);
    listener.refresh();
    let port = listening(&listener).await;
    let _first = connect(addr(port), &secret_a()).await.unwrap();
    let mut second = connect(addr(port), &secret_a()).await.unwrap();
    // The second didn't fit: the host closed it.
    let mut buf = [0u8; 8];
    let read = tokio::time::timeout(T, second.stream.read(&mut buf)).await.unwrap();
    assert!(matches!(read, Ok(0) | Err(_)));
    assert!(rx.try_recv().is_ok());
    assert!(rx.try_recv().is_err());
}

/// Swift's `refresh()` leaves `status` alone when nothing changed: a refresh with the same keys, or still none,
/// wakes no status receiver (each USB link-up refreshes; the daemon re-advertises on a change).
#[tokio::test]
async fn a_refresh_that_changes_nothing_leaves_the_status_watch_quiet() {
    let store = MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]);
    let (listener, _rx) = listener(store.clone());
    let mut status = listener.status();
    listener.refresh();
    reaches(&mut status, |s| s.port().is_some()).await;
    status.mark_unchanged();
    for _ in 0..3 {
        listener.refresh();
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(!status.has_changed().unwrap(), "{:?}", *status.borrow());

    // No pairing, refreshed again and again: one change to Off, then quiet.
    store.remove_secret(SERIAL).await.unwrap();
    listener.refresh();
    reaches(&mut status, |s| s.port().is_none()).await;
    status.mark_unchanged();
    for _ in 0..3 {
        listener.refresh();
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(!status.has_changed().unwrap(), "{:?}", *status.borrow());
}

/// A store whose first listing panics, as a bug in a store or its D-Bus stack would.
#[derive(Clone)]
struct Panicky {
    inner: MemorySecretStore,
    lists: Arc<AtomicUsize>,
}

impl SecretStore for Panicky {
    async fn secret(&self, account: &str) -> lain_platform::Result<Option<Vec<u8>>> {
        self.inner.secret(account).await
    }
    async fn set_secret(&self, account: &str, secret: &[u8]) -> lain_platform::Result<()> {
        self.inner.set_secret(account, secret).await
    }
    async fn remove_secret(&self, account: &str) -> lain_platform::Result<()> {
        self.inner.remove_secret(account).await
    }
    async fn all_secrets(&self) -> lain_platform::Result<BTreeMap<String, Vec<u8>>> {
        if self.lists.fetch_add(1, Ordering::SeqCst) == 0 {
            panic!("the store's first listing panics (expected by the test)");
        }
        self.inner.all_secrets().await
    }
}

/// A read that panics counts as a failed read: retried with backoff, not lost.
#[tokio::test(start_paused = true)]
async fn a_panicking_read_is_retried() {
    let store = Panicky { inner: MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]), lists: Arc::default() };
    let (tx, _rx) = mpsc::channel(8);
    let listener = WiFiListener::new(store.clone(), WiFiListenerOptions::loopback(), tx);
    listener.refresh();
    let mut status = listener.status();
    // On paused time, a minute is instant; without a retry the status would stay `Starting` for good.
    let minute = Duration::from_secs(60);
    let off = tokio::time::timeout(minute, status.wait_for(|s| *s != WiFiStatus::Starting)).await;
    assert_eq!(
        *off.expect("the panicked read was applied").unwrap(),
        WiFiStatus::Off("can't read the pairing secrets".into())
    );
    let t0 = tokio::time::Instant::now();
    tokio::time::timeout(minute, status.wait_for(|s| s.port().is_some())).await.expect("retried").unwrap();
    assert_eq!(t0.elapsed(), WiFiListenerOptions::default().retry_initial);
    assert_eq!(store.lists.load(Ordering::SeqCst), 2);
}

/// Dropping the listener closes the hand-off at once, even after a flood scheduled a summary notice.
#[tokio::test]
async fn dropping_the_listener_closes_the_hand_off_at_once() {
    let store = MemorySecretStore::with([(SERIAL.to_owned(), secret_a())]);
    let (listener, mut rx) = listener(store);
    listener.refresh();
    let port = listening(&listener).await;
    // Past the per-host cap of 8: two evictions schedule a summary.
    let mut raws = Vec::new();
    for _ in 0..10 {
        raws.push(tokio::net::TcpStream::connect(addr(port)).await.unwrap());
    }
    tokio::time::sleep(Duration::from_millis(100)).await;
    let t0 = Instant::now();
    drop(listener);
    assert!(tokio::time::timeout(T, rx.recv()).await.unwrap().is_none());
    assert!(t0.elapsed() < Duration::from_millis(200), "{:?}", t0.elapsed());
}
