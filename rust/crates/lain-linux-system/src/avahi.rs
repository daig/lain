//! Bonjour advertising through Avahi's D-Bus API on the system bus (Swift: the Wi-Fi listener's Bonjour
//! service, `NetworkStreamListener.Advertisement` in `LainTransport`, with the TXT record of `LainTXT`).
//!
//! One entry group per publish: `EntryGroupNew`, `AddService`, `Commit`, then `StateChanged`; the previous
//! group is freed first. A fresh group (rather than `Reset` and reuse) means a state change still queued
//! for the previous ad goes with the previous group's signal stream, so it can't be taken for the new ad's.
//! On a name collision the instance is renamed with `GetAlternativeServiceName` (`Desk` → `Desk #2`) and
//! published again, as Bonjour renames a Mac's service. The service is published again after avahi-daemon
//! restarts (`NameOwnerChanged`) and after the server's own host-name collision, and withdrawn with `Free`.
//! Avahi frees the group when our D-Bus connection closes, so a dropped advertiser (or a crashed daemon)
//! leaves nothing behind.

use std::time::Duration;

use futures::StreamExt;
use lain_platform::{Advertiser, PlatformError, Result, ServiceAd};
use tokio::sync::{mpsc, oneshot, watch};
use tracing::{debug, info, warn};
/// Avahi's well-known name on the system bus.
pub const AVAHI_NAME: &str = "org.freedesktop.Avahi";

/// `AVAHI_IF_UNSPEC`, `AVAHI_PROTO_UNSPEC`: every interface, IPv4 and IPv6.
const IF_UNSPEC: i32 = -1;
const PROTO_UNSPEC: i32 = -1;

/// The longest DNS label, in bytes: an instance name longer than this is cut (at a character boundary).
pub const MAX_INSTANCE_NAME: usize = 63;
/// The longest TXT entry (`key=value`), in bytes.
pub const MAX_TXT_ENTRY: usize = 255;
/// How many renames a collision may cause before the advertiser gives up until the next change.
const MAX_RENAMES: usize = 32;

/// How long a D-Bus call to Avahi may take.
const CALL_TIMEOUT: Duration = Duration::from_secs(5);

/// `AvahiServerState`.
mod server_state {
    pub const REGISTERING: i32 = 1;
    pub const RUNNING: i32 = 2;
    pub const COLLISION: i32 = 3;
}

/// `AvahiEntryGroupState`.
mod group_state {
    pub const UNCOMMITED: i32 = 0;
    pub const REGISTERING: i32 = 1;
    pub const ESTABLISHED: i32 = 2;
    pub const COLLISION: i32 = 3;
    pub const FAILURE: i32 = 4;
}

/// `org.freedesktop.Avahi.Server` (each proxy in its own module: their signals share a name).
mod server {
    use zbus::zvariant::OwnedObjectPath;

    #[zbus::proxy(
        interface = "org.freedesktop.Avahi.Server",
        default_service = "org.freedesktop.Avahi",
        default_path = "/"
    )]
    pub(super) trait AvahiServer {
        fn entry_group_new(&self) -> zbus::Result<OwnedObjectPath>;
        fn get_alternative_service_name(&self, name: &str) -> zbus::Result<String>;
        fn get_state(&self) -> zbus::Result<i32>;
        #[zbus(signal)]
        fn state_changed(&self, state: i32, error: String) -> zbus::Result<()>;
    }
}

/// `org.freedesktop.Avahi.EntryGroup`.
mod entry_group {
    #[zbus::proxy(interface = "org.freedesktop.Avahi.EntryGroup", default_service = "org.freedesktop.Avahi")]
    pub(super) trait AvahiEntryGroup {
        #[allow(clippy::too_many_arguments)]
        fn add_service(
            &self,
            interface: i32,
            protocol: i32,
            flags: u32,
            name: &str,
            service_type: &str,
            domain: &str,
            host: &str,
            port: u16,
            txt: Vec<Vec<u8>>,
        ) -> zbus::Result<()>;
        fn commit(&self) -> zbus::Result<()>;
        fn reset(&self) -> zbus::Result<()>;
        fn free(&self) -> zbus::Result<()>;
        #[zbus(signal)]
        fn state_changed(&self, state: i32, error: String) -> zbus::Result<()>;
    }
}

use entry_group::{AvahiEntryGroupProxy, StateChangedStream as GroupSignals};
use server::AvahiServerProxy;

/// The TXT record as Avahi takes it: one `key=value` byte string per entry, in the ad's order (`v`, `vs`,
/// `id`). Swift's `NWTXTRecord` is a dictionary, so its order is unspecified; DNS-SD readers don't care.
pub fn txt_entries(txt: &[(String, String)]) -> Result<Vec<Vec<u8>>> {
    let mut seen = std::collections::BTreeSet::new();
    txt.iter()
        .map(|(key, value)| {
            if key.is_empty() || key.contains('=') || !key.bytes().all(|b| (0x20..=0x7e).contains(&b)) {
                return Err(PlatformError::Failed(format!("TXT key {key:?} is not printable ASCII without '='")));
            }
            if !seen.insert(key.to_ascii_lowercase()) {
                return Err(PlatformError::Failed(format!("TXT key {key:?} appears twice")));
            }
            let entry = format!("{key}={value}").into_bytes();
            if entry.len() > MAX_TXT_ENTRY {
                return Err(PlatformError::Failed(format!("TXT entry {key:?} is longer than {MAX_TXT_ENTRY} bytes")));
            }
            Ok(entry)
        })
        .collect()
}

/// `name` cut to [`MAX_INSTANCE_NAME`] bytes at a character boundary. An intended difference from the Mac,
/// where the computer name is already limited by the system.
pub fn instance_name(name: &str) -> String {
    let mut end = name.len().min(MAX_INSTANCE_NAME);
    while !name.is_char_boundary(end) {
        end -= 1;
    }
    name[..end].to_owned()
}

enum Command {
    Advertise(ServiceAd, oneshot::Sender<Result<()>>),
    Withdraw(oneshot::Sender<()>),
}

/// Publishes the host's service with Avahi ([`Advertiser`]). Cheap to call from anywhere; one task (on the
/// tokio runtime that created it) owns the entry group. Dropping the advertiser ends the task, which frees
/// the group (and Avahi frees it anyway when the task's runtime, and so its connection, ends).
#[derive(Debug)]
pub struct AvahiAdvertiser {
    commands: mpsc::UnboundedSender<Command>,
    registered: watch::Receiver<Option<String>>,
}

impl AvahiAdvertiser {
    /// An advertiser on the system bus.
    pub async fn system() -> Result<AvahiAdvertiser> {
        let bus =
            zbus::Connection::system().await.map_err(|e| PlatformError::Unavailable(format!("system bus: {e}")))?;
        Ok(Self::new(bus))
    }

    /// An advertiser on `bus` (the system bus, or a test bus). Must be called inside a tokio runtime.
    pub fn new(bus: zbus::Connection) -> AvahiAdvertiser {
        let (commands, rx) = mpsc::unbounded_channel();
        let (registered_tx, registered) = watch::channel(None);
        tokio::spawn(Driver::new(bus, registered_tx).run(rx));
        AvahiAdvertiser { commands, registered }
    }

    /// The instance name Avahi established (after any rename), or `None` while nothing is established.
    /// Swift shows the registered name in the host's status (`HostWiFiListener`'s `.registered(name)`).
    pub fn registered_name(&self) -> watch::Receiver<Option<String>> {
        self.registered.clone()
    }
}

impl Advertiser for AvahiAdvertiser {
    /// Publishes `ad`, replacing any earlier one. Returns once Avahi has the service (committed, still
    /// probing the name), or straight away if Avahi's server isn't running yet.
    ///
    /// - An invalid ad (a TXT key that isn't printable ASCII without `=`, a repeated key, an entry over 255
    ///   bytes) is refused before anything changes: the earlier ad, if any, stays published and is still
    ///   the one kept.
    /// - The same ad as the last one, while it is published, changes nothing (no withdrawal and re-probe,
    ///   and a name renamed after a collision stays), as Swift's listener keeps its Bonjour service.
    /// - Any other error means the ad isn't published now (no avahi-daemon, say); the advertiser keeps it
    ///   all the same and publishes it when avahi-daemon appears or restarts, until
    ///   [`withdraw`](Advertiser::withdraw).
    async fn advertise(&self, ad: ServiceAd) -> Result<()> {
        let (reply, result) = oneshot::channel();
        self.commands
            .send(Command::Advertise(ad, reply))
            .map_err(|_| PlatformError::Failed("the advertiser task ended".into()))?;
        result.await.unwrap_or_else(|_| Err(PlatformError::Failed("the advertiser task ended".into())))
    }

    async fn withdraw(&self) {
        let (reply, done) = oneshot::channel();
        if self.commands.send(Command::Withdraw(reply)).is_ok() {
            let _ = done.await;
        }
    }
}

struct Group {
    proxy: AvahiEntryGroupProxy<'static>,
    signals: GroupSignals,
}

/// The task's state: what should be published, and what is.
struct Driver {
    bus: zbus::Connection,
    registered: watch::Sender<Option<String>>,
    /// What the owner asked for, as given (the name only cut to a DNS label).
    requested: Option<ServiceAd>,
    /// `requested`, with the name as renamed after collisions.
    desired: Option<ServiceAd>,
    group: Option<Group>,
    /// Renames since the last `advertise`.
    renames: usize,
    /// The group holds the desired service (committed, whatever Avahi then reports).
    committed: bool,
}

async fn timed<T>(call: impl Future<Output = zbus::Result<T>>) -> zbus::Result<T> {
    tokio::time::timeout(CALL_TIMEOUT, call).await.unwrap_or_else(|_| Err(zbus::Error::Failure("timed out".into())))
}

fn is_collision(e: &zbus::Error) -> bool {
    matches!(e, zbus::Error::MethodError(name, _, _) if name.as_str() == "org.freedesktop.Avahi.CollisionError")
}

fn platform_error(e: zbus::Error) -> PlatformError {
    match &e {
        zbus::Error::MethodError(name, _, _)
            if matches!(
                name.as_str(),
                "org.freedesktop.DBus.Error.ServiceUnknown" | "org.freedesktop.DBus.Error.NameHasNoOwner"
            ) =>
        {
            PlatformError::Unavailable(format!("avahi-daemon isn't running: {e}"))
        }
        _ => PlatformError::Failed(format!("Avahi: {e}")),
    }
}

impl Driver {
    fn new(bus: zbus::Connection, registered: watch::Sender<Option<String>>) -> Driver {
        Driver { bus, registered, requested: None, desired: None, group: None, renames: 0, committed: false }
    }

    /// The `Advertise` command: see [`AvahiAdvertiser::advertise`].
    async fn advertise(&mut self, mut ad: ServiceAd) -> Result<()> {
        ad.name = instance_name(&ad.name);
        // Refused before anything changes, so the earlier ad stays published and kept.
        txt_entries(&ad.txt)?;
        if self.committed && self.requested.as_ref() == Some(&ad) {
            debug!(name = %ad.name, "the same ad again; nothing to change");
            return Ok(());
        }
        self.requested = Some(ad.clone());
        self.desired = Some(ad);
        self.renames = 0;
        self.publish().await
    }

    async fn run(mut self, mut commands: mpsc::UnboundedReceiver<Command>) {
        let owners = async {
            zbus::fdo::DBusProxy::new(&self.bus).await?.receive_name_owner_changed_with_args(&[(0, AVAHI_NAME)]).await
        };
        let mut owners = match owners.await {
            Ok(stream) => Some(stream),
            Err(e) => {
                warn!(error = %e, "can't follow avahi-daemon restarts");
                None
            }
        };
        let server_states = async { AvahiServerProxy::new(&self.bus).await?.receive_state_changed().await };
        let mut server_states = match server_states.await {
            Ok(stream) => Some(stream),
            Err(e) => {
                warn!(error = %e, "can't follow Avahi's server state");
                None
            }
        };

        loop {
            tokio::select! {
                command = commands.recv() => match command {
                    Some(Command::Advertise(ad, reply)) => {
                        let _ = reply.send(self.advertise(ad).await);
                    }
                    Some(Command::Withdraw(reply)) => {
                        self.requested = None;
                        self.desired = None;
                        self.unpublish().await;
                        let _ = reply.send(());
                    }
                    None => break,
                },
                Some(signal) = next(&mut self.group) => {
                    match signal.args() {
                        Ok(args) => self.group_state_changed(args.state, &args.error).await,
                        Err(e) => warn!(error = %e, "an unreadable entry group signal"),
                    }
                }
                Some(changed) = next_some(&mut owners) => {
                    let appeared = changed.args().map(|a| a.new_owner().is_some()).unwrap_or(false);
                    // The old group, if any, died with the old daemon.
                    self.group = None;
                    self.committed = false;
                    self.registered.send_replace(None);
                    if appeared {
                        info!("avahi-daemon (re)started");
                        if self.desired.is_some() {
                            self.renames = 0;
                            if let Err(e) = self.publish().await {
                                warn!(error = %e, "re-publishing after avahi-daemon restarted");
                            }
                        }
                    } else {
                        info!("avahi-daemon stopped; the service will be published again when it returns");
                    }
                }
                Some(signal) = next_some(&mut server_states) => {
                    if let Ok(args) = signal.args() {
                        self.server_state_changed(args.state).await;
                    }
                }
            }
        }
        self.unpublish().await;
    }

    async fn server_state_changed(&mut self, state: i32) {
        match state {
            server_state::RUNNING if self.desired.is_some() && !self.committed => {
                if let Err(e) = self.publish().await {
                    warn!(error = %e, "publishing once Avahi's server runs");
                }
            }
            // The host name is being (re)probed: Avahi's documentation says to reset the group and add the
            // services again once the server runs.
            server_state::REGISTERING | server_state::COLLISION if self.committed => {
                debug!(state, "Avahi's server is re-registering; withdrawing the group");
                self.unpublish().await;
            }
            _ => {}
        }
    }

    async fn group_state_changed(&mut self, state: i32, error: &str) {
        let Some(ad) = &self.desired else { return };
        match state {
            group_state::ESTABLISHED => {
                info!(name = %ad.name, service_type = %ad.service_type, port = ad.port, "advertised");
                self.registered.send_replace(Some(ad.name.clone()));
            }
            group_state::COLLISION => {
                self.registered.send_replace(None);
                if let Err(e) = self.rename_and_publish().await {
                    warn!(error = %e, "re-publishing after a name collision");
                }
            }
            group_state::FAILURE => {
                warn!(name = %ad.name, %error, "Avahi failed to publish the service");
                self.registered.send_replace(None);
                // Not published: the same ad again, or the server running again, retries.
                self.committed = false;
            }
            group_state::UNCOMMITED | group_state::REGISTERING => {}
            _ => debug!(state, "an unknown entry group state"),
        }
    }

    async fn rename_and_publish(&mut self) -> Result<()> {
        self.renames += 1;
        if self.renames > MAX_RENAMES {
            return Err(PlatformError::Failed(format!("{MAX_RENAMES} name collisions in a row")));
        }
        let Some(ad) = &mut self.desired else { return Ok(()) };
        let server = AvahiServerProxy::new(&self.bus).await.map_err(platform_error)?;
        let alternative = timed(server.get_alternative_service_name(&ad.name)).await.map_err(platform_error)?;
        info!(from = %ad.name, to = %alternative, "service name collision; renamed");
        ad.name = alternative;
        self.publish().await
    }

    /// (Re)publishes `desired` in our group, creating the group if needed.
    async fn publish(&mut self) -> Result<()> {
        match self.try_publish().await {
            Ok(()) => Ok(()),
            Err(e) if is_collision(&e) => {
                // A local collision (another service of this host has the name) fails AddService itself.
                self.registered.send_replace(None);
                Box::pin(self.rename_and_publish()).await
            }
            Err(e) => {
                let mapped = platform_error(e);
                if matches!(mapped, PlatformError::Unavailable(_)) {
                    self.group = None;
                    self.committed = false;
                }
                self.registered.send_replace(None);
                Err(mapped)
            }
        }
    }

    async fn try_publish(&mut self) -> zbus::Result<()> {
        let Some(ad) = self.desired.clone() else { return Ok(()) };
        let txt = txt_entries(&ad.txt).map_err(|e| zbus::Error::Failure(e.to_string()))?;
        let server = AvahiServerProxy::new(&self.bus).await?;
        if timed(server.get_state()).await? != server_state::RUNNING {
            debug!("Avahi's server isn't running yet; publishing when it is");
            self.unpublish().await;
            return Ok(());
        }
        // A fresh group: the old one's queued signals (say, a COLLISION for the previous name) are dropped
        // with its stream instead of being applied to this ad.
        self.unpublish().await;
        let path = timed(server.entry_group_new()).await?;
        let proxy = AvahiEntryGroupProxy::builder(&self.bus).path(path)?.build().await?;
        // Subscribed before Commit, so no state change is missed.
        let signals = proxy.receive_state_changed().await?;
        let group = Group { proxy, signals };
        let added = async {
            timed(group.proxy.add_service(
                IF_UNSPEC,
                PROTO_UNSPEC,
                0,
                &ad.name,
                &ad.service_type,
                "",
                "",
                ad.port,
                txt,
            ))
            .await?;
            timed(group.proxy.commit()).await
        }
        .await;
        self.group = Some(group);
        added?;
        self.committed = true;
        debug!(name = %ad.name, "committed the entry group");
        Ok(())
    }

    /// Withdraws the service by freeing the group (the next publish makes a new one), dropping its signals.
    async fn unpublish(&mut self) {
        self.registered.send_replace(None);
        self.committed = false;
        let Some(group) = self.group.take() else { return };
        if let Err(e) = timed(group.proxy.free()).await {
            debug!(error = %e, "freeing the entry group");
        }
    }
}

/// The next signal of the group, or never when there's none.
async fn next(group: &mut Option<Group>) -> Option<<GroupSignals as futures::Stream>::Item> {
    match group {
        Some(group) => group.signals.next().await,
        None => std::future::pending().await,
    }
}

async fn next_some<S: futures::Stream + Unpin>(stream: &mut Option<S>) -> Option<S::Item> {
    match stream {
        Some(s) => match s.next().await {
            Some(item) => Some(item),
            None => {
                *stream = None;
                std::future::pending().await
            }
        },
        None => std::future::pending().await,
    }
}

#[cfg(test)]
mod tests;
