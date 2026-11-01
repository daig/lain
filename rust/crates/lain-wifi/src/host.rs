//! The host's Wi-Fi link source. Swift: `HostWiFiListener` (`LainHostCore/Session/HostWiFiListener.swift`)
//! and `HostWiFiStatus` (`LainHostCore/HostStatus.swift`).

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use lain_link::ByteStream;
use lain_platform::SecretStore;
use tokio::sync::{mpsc, watch};
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::Instant;

use crate::{ListenerOptions, PskTable, TlsPskListener, WiFiConnection};

/// The host's Wi-Fi listener as the daemon shows it (§7.7 D29 decision 9). Swift: `HostWiFiStatus`.
///
/// Differences from Swift: no `denied` (Linux has no Local Network permission) and no Bonjour name
/// (`advertising(name:port:pairedCount:)` is [`Listening`](Self::Listening): the daemon advertises while
/// it is listening, through `lain-platform`'s `Advertiser`, and knows the name it chose).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WiFiStatus {
    /// Not listening: no iPad has paired over USB yet, the pairing secrets can't be read (retrying), or
    /// the listener was stopped.
    Off(String),
    /// Nothing has been read yet (before the first [`WiFiListener::refresh`]).
    Starting,
    /// Listening on `port` with one PSK per paired iPad.
    Listening { port: u16, paired: usize },
    /// The listener couldn't bind; it retries with backoff.
    Failed(String),
}

impl WiFiStatus {
    /// For a menu or `lain status`. Swift: `HostWiFiStatus.title`.
    pub fn title(&self) -> String {
        match self {
            Self::Off(why) => format!("Wi-Fi: off: {why}"),
            Self::Starting => "Wi-Fi: starting…".to_owned(),
            Self::Listening { port, paired } => {
                let ipads = if *paired == 1 { "1 paired iPad".to_owned() } else { format!("{paired} paired iPads") };
                format!("Wi-Fi: listening on port {port} with {ipads}")
            }
            Self::Failed(why) => format!("Wi-Fi failed: {why}; retrying"),
        }
    }

    /// The port while listening.
    pub fn port(&self) -> Option<u16> {
        match self {
            Self::Listening { port, .. } => Some(*port),
            _ => None,
        }
    }
}

/// How a [`WiFiListener`] listens and retries. Swift: `HostWiFiConfig`'s Wi-Fi half (its admission
/// settings, `usbPreference`, `helloTimeout` and `busyDrain`, are `lain-host`'s).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WiFiListenerOptions {
    pub listener: ListenerOptions,
    /// A failed secret read or a failed bind retries after this, doubling up to `retry_max`.
    pub retry_initial: Duration,
    pub retry_max: Duration,
    /// A secret read that takes longer counts as failed (and retries). No Swift counterpart: its Keychain
    /// read is synchronous; a Secret Service call can hang on a dead bus.
    pub read_timeout: Duration,
}

impl Default for WiFiListenerOptions {
    fn default() -> Self {
        Self {
            listener: ListenerOptions::default(),
            retry_initial: Duration::from_secs(2),
            retry_max: Duration::from_secs(60),
            read_timeout: Duration::from_secs(10),
        }
    }
}

impl WiFiListenerOptions {
    /// Loopback only, for tests.
    pub fn loopback() -> Self {
        Self { listener: ListenerOptions::loopback(), ..Self::default() }
    }
}

enum Command {
    Refresh,
    Cancel,
}

/// The host's Wi-Fi link source (§7.7 D29): a [`TlsPskListener`] holding one PSK per stored pairing secret
/// (`WiFiPsk::new` of every `all_secrets()` entry), handing each authenticated connection to `lain-host`
/// as a `Box<dyn ByteStream>` (a `BoundStream` bound to the secret TLS proved, transport
/// `Network { interface, peer_to_peer: false }`) on the caller's bounded sender. When the sender is full
/// the connection is closed and logged. Swift: `HostWiFiListener`.
///
/// [`refresh`](Self::refresh) re-reads the secrets: it starts listening when there are some and nothing
/// listens, swaps the PSK table in place when they changed, and stops listening when none are left.
/// Refreshes may overlap (start, each `secrets_changed`, retries); the newest read wins, so a slow read can't
/// put back keys a re-pairing replaced. A failed read or a failed bind retries with backoff (2 s doubling
/// to 60 s). Identities are logged, never keys. Nothing listens until the first `refresh`.
///
/// [`cancel`](Self::cancel), or dropping the last handle, stops everything (pending handshakes included);
/// streams already handed over are the consumer's. Must be created inside a tokio runtime.
///
/// Difference from Swift: a change of keys swaps the live table and keeps the socket, where Swift restarts
/// its listener (Network.framework fixes a listener's PSKs): the port, and so the advertisement, stay the
/// same across a re-pairing. [`listener_starts`](Self::listener_starts) counts binds, as Swift's `starts`.
pub struct WiFiListener {
    commands: mpsc::UnboundedSender<Command>,
    status: watch::Receiver<WiFiStatus>,
    starts: Arc<AtomicUsize>,
    task: JoinHandle<()>,
}

impl WiFiListener {
    pub fn new<S: SecretStore + Clone>(
        secrets: S,
        options: WiFiListenerOptions,
        accepted: mpsc::Sender<Box<dyn ByteStream>>,
    ) -> Self {
        let (commands, receiver) = mpsc::unbounded_channel();
        let (status_tx, status) = watch::channel(WiFiStatus::Starting);
        let starts = Arc::new(AtomicUsize::new(0));
        let actor = Actor {
            secrets,
            options,
            accepted,
            status: status_tx,
            starts: starts.clone(),
            table: PskTable::new(),
            listener: None,
            reads: JoinSet::new(),
            issued: 0,
            applied: 0,
            backoff: None,
            retry_at: None,
        };
        let task = tokio::spawn(actor.run(receiver));
        Self { commands, status, starts, task }
    }

    /// Re-reads the stored secrets (in the background; watch [`status`](Self::status)).
    pub fn refresh(&self) {
        let _ = self.commands.send(Command::Refresh);
    }

    /// Off, listening (with the port and the number of pairings), or failed.
    pub fn status(&self) -> watch::Receiver<WiFiStatus> {
        self.status.clone()
    }

    /// The port while listening.
    pub fn port(&self) -> Option<u16> {
        self.status.borrow().port()
    }

    /// Binds so far (tests: a refresh with the same keys, or a re-pairing, must not rebind).
    pub fn listener_starts(&self) -> usize {
        self.starts.load(Ordering::SeqCst)
    }

    /// Stops listening for good; a pending retry is cancelled. Status: `Off("stopped")`.
    pub fn cancel(&self) {
        let _ = self.commands.send(Command::Cancel);
    }
}

impl Drop for WiFiListener {
    fn drop(&mut self) {
        // The actor's own exit path closes the socket; aborting too makes it immediate.
        self.task.abort();
    }
}

impl fmt::Debug for WiFiListener {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WiFiListener").field("status", &*self.status.borrow()).finish_non_exhaustive()
    }
}

type Read = (u64, Result<BTreeMap<String, Vec<u8>>, String>);

struct Actor<S> {
    secrets: S,
    options: WiFiListenerOptions,
    accepted: mpsc::Sender<Box<dyn ByteStream>>,
    status: watch::Sender<WiFiStatus>,
    starts: Arc<AtomicUsize>,
    /// The PSKs of the newest read applied; the listener's handshakes read it live.
    table: PskTable,
    listener: Option<TlsPskListener>,
    /// Reads in flight, each with its ticket; aborted when the actor ends.
    reads: JoinSet<Read>,
    /// Reads numbered as they begin, and the newest one whose outcome was applied: an older read that
    /// finishes later is dropped.
    issued: u64,
    applied: u64,
    /// The next retry's delay while failures continue; `None` once nothing is failing.
    backoff: Option<Duration>,
    retry_at: Option<Instant>,
}

impl<S: SecretStore + Clone> Actor<S> {
    async fn run(mut self, mut commands: mpsc::UnboundedReceiver<Command>) {
        loop {
            tokio::select! {
                command = commands.recv() => match command {
                    Some(Command::Refresh) => self.read(),
                    Some(Command::Cancel) | None => break,
                },
                Some(done) = self.reads.join_next(), if !self.reads.is_empty() => {
                    if let Ok((ticket, result)) = done {
                        self.apply(ticket, result);
                    }
                }
                () = sleep_until(self.retry_at), if self.retry_at.is_some() => {
                    self.retry_at = None;
                    self.read();
                }
            }
        }
        self.listener = None;
        self.status.send_replace(WiFiStatus::Off("stopped".into()));
    }

    fn read(&mut self) {
        self.issued += 1;
        let ticket = self.issued;
        let secrets = self.secrets.clone();
        let timeout = self.options.read_timeout;
        self.reads.spawn(async move {
            let result = match tokio::time::timeout(timeout, secrets.all_secrets()).await {
                Ok(Ok(map)) => Ok(map),
                Ok(Err(e)) => Err(e.to_string()),
                Err(_) => Err(format!("no answer within {timeout:?}")),
            };
            (ticket, result)
        });
    }

    fn apply(&mut self, ticket: u64, result: Result<BTreeMap<String, Vec<u8>>, String>) {
        if ticket <= self.applied {
            return; // a newer read was applied already
        }
        self.applied = ticket;
        let stored = match result {
            Ok(stored) => stored,
            Err(why) => {
                tracing::error!("Wi-Fi: could not read the pairing secrets ({why}); retrying");
                if self.listener.is_none() {
                    self.status.send_replace(WiFiStatus::Off("can't read the pairing secrets".into()));
                }
                self.retry_later();
                return;
            }
        };
        let before: BTreeSet<String> = self.table.identities().into_iter().collect();
        let paired = self.table.replace(stored.values());
        let after: BTreeSet<String> = self.table.identities().into_iter().collect();
        if paired == 0 {
            if self.listener.take().is_some() || before != after {
                tracing::info!("Wi-Fi: no paired iPad; not listening");
            }
            self.status.send_replace(WiFiStatus::Off("no paired iPad yet".into()));
            self.backoff = None;
            self.retry_at = None;
            return;
        }
        if let Some(listener) = &self.listener {
            if before != after {
                tracing::info!(
                    "Wi-Fi: {paired} paired iPad(s); PSK identities now {}",
                    after.iter().cloned().collect::<Vec<_>>().join(", ")
                );
            }
            self.status.send_replace(WiFiStatus::Listening { port: listener.port(), paired });
            self.backoff = None;
            self.retry_at = None;
            return;
        }
        let accepted = self.accepted.clone();
        match TlsPskListener::bind(self.table.clone(), &self.options.listener, move |c| hand_over(&accepted, c)) {
            Ok((listener, _rejections)) => {
                tracing::info!("Wi-Fi: {paired} paired iPad(s); listening on {}", listener.local_addr());
                self.starts.fetch_add(1, Ordering::SeqCst);
                self.status.send_replace(WiFiStatus::Listening { port: listener.port(), paired });
                self.listener = Some(listener);
                self.backoff = None;
                self.retry_at = None;
            }
            Err(e) => {
                tracing::error!("Wi-Fi listener could not start on {}: {e}", self.options.listener.bind);
                self.status.send_replace(WiFiStatus::Failed(e.to_string()));
                self.retry_later();
            }
        }
    }

    /// Schedules a read after the backoff, unless one is pending.
    fn retry_later(&mut self) {
        if self.retry_at.is_some() {
            return;
        }
        let delay = self.backoff.unwrap_or(self.options.retry_initial);
        self.backoff = Some((delay * 2).min(self.options.retry_max));
        self.retry_at = Some(Instant::now() + delay);
    }
}

async fn sleep_until(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

/// Passes an authenticated connection on to `lain-host`, never waiting: a full queue closes it.
fn hand_over(accepted: &mpsc::Sender<Box<dyn ByteStream>>, connection: WiFiConnection) {
    let (peer, identity) = (connection.peer_addr, connection.psk_identity.clone());
    match accepted.try_send(connection.into_byte_stream()) {
        Ok(()) => tracing::debug!("Wi-Fi: handed over {peer} ({identity})"),
        Err(mpsc::error::TrySendError::Full(_)) => {
            tracing::warn!("Wi-Fi: the session's queue is full; closing {peer} ({identity})");
        }
        Err(mpsc::error::TrySendError::Closed(_)) => {
            tracing::warn!("Wi-Fi: nobody takes connections; closing {peer} ({identity})");
        }
    }
}
