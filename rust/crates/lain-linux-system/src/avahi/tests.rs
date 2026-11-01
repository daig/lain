//! The advertiser against a fake Avahi on a private bus, the pure helpers, and one live test.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use zbus::object_server::SignalEmitter;
use zbus::zvariant::OwnedObjectPath;

use super::*;
use crate::testbus::TestBus;

const HOST_ID: &str = "6F9619FF-8B86-D011-B42D-00C04FC964FF";
const WAIT: Duration = Duration::from_secs(5);

fn ad(name: &str, port: u16) -> ServiceAd {
    ServiceAd {
        service_type: "_lain-test._tcp".into(),
        name: name.into(),
        port,
        txt: vec![("v".into(), "4".into()), ("vs".into(), "3,4".into()), ("id".into(), HOST_ID.into())],
    }
}

// MARK: Pure helpers

/// Swift: `WiFiDiscovery.txtCarriesTheVersionsAndHostId`, the wire half (the dictionary is `lain-wifi`'s).
#[test]
fn txt_entries_are_key_value_bytes_in_order() {
    assert_eq!(
        txt_entries(&ad("x", 1).txt).unwrap(),
        [b"v=4".to_vec(), b"vs=3,4".to_vec(), format!("id={HOST_ID}").into_bytes()]
    );
    assert_eq!(txt_entries(&[("bench".into(), "1".into())]).unwrap(), [b"bench=1".to_vec()]);
    assert_eq!(txt_entries(&[("k".into(), "".into())]).unwrap(), [b"k=".to_vec()]);
    assert!(txt_entries(&[]).unwrap().is_empty());
}

#[test]
fn invalid_txt_entries_are_refused() {
    let entry = |k: &str, v: &str| vec![(k.to_owned(), v.to_owned())];
    assert!(txt_entries(&entry("", "x")).is_err());
    assert!(txt_entries(&entry("a=b", "x")).is_err());
    assert!(txt_entries(&entry("ü", "x")).is_err());
    assert!(txt_entries(&entry("k", &"x".repeat(254))).is_err());
    assert!(txt_entries(&entry("k", &"x".repeat(253))).is_ok());
    assert!(txt_entries(&[("v".into(), "1".into()), ("V".into(), "2".into())]).is_err());
}

#[test]
fn instance_names_are_cut_at_a_character_boundary() {
    assert_eq!(instance_name("Desk"), "Desk");
    assert_eq!(instance_name(&"a".repeat(70)), "a".repeat(63));
    let name = format!("{}é", "a".repeat(62)); // 64 bytes: the é would straddle the limit.
    assert_eq!(instance_name(&name), "a".repeat(62));
}

// MARK: Fake Avahi

#[derive(Debug, Clone, PartialEq, Eq)]
struct Published {
    group: String,
    interface: i32,
    protocol: i32,
    flags: u32,
    name: String,
    service_type: String,
    domain: String,
    host: String,
    port: u16,
    txt: Vec<Vec<u8>>,
}

#[derive(Debug)]
struct World {
    server_state: i32,
    /// Committed services.
    published: Vec<Published>,
    /// Names another host on the network has: a commit of one collides.
    taken_remote: BTreeSet<String>,
    groups_created: usize,
    groups_freed: usize,
    /// Commits on any group: each one is a (re)probe and announcement on the network.
    commits: usize,
}

type Shared = Arc<Mutex<World>>;

fn new_world() -> Shared {
    Arc::new(Mutex::new(World {
        server_state: server_state::RUNNING,
        published: vec![],
        taken_remote: BTreeSet::new(),
        groups_created: 0,
        groups_freed: 0,
        commits: 0,
    }))
}

fn alternative(name: &str) -> String {
    if let Some((base, n)) = name.rsplit_once(" #")
        && let Ok(n) = n.parse::<u32>()
    {
        return format!("{base} #{}", n + 1);
    }
    format!("{name} #2")
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.Avahi")]
enum FakeError {
    #[zbus(error)]
    ZBus(zbus::Error),
    CollisionError(String),
}

struct FakeServer {
    world: Shared,
    next: AtomicUsize,
}

#[zbus::interface(name = "org.freedesktop.Avahi.Server")]
impl FakeServer {
    async fn entry_group_new(
        &self,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> zbus::fdo::Result<OwnedObjectPath> {
        let path = format!("/Client1/EntryGroup{}", self.next.fetch_add(1, Ordering::SeqCst) + 1);
        server
            .at(path.as_str(), FakeGroup { world: Arc::clone(&self.world), path: path.clone(), pending: vec![] })
            .await?;
        self.world.lock().unwrap().groups_created += 1;
        Ok(OwnedObjectPath::try_from(path).unwrap())
    }

    fn get_alternative_service_name(&self, name: &str) -> String {
        alternative(name)
    }

    fn get_state(&self) -> i32 {
        self.world.lock().unwrap().server_state
    }

    #[zbus(signal)]
    async fn state_changed(emitter: &SignalEmitter<'_>, state: i32, error: &str) -> zbus::Result<()>;
}

struct FakeGroup {
    world: Shared,
    path: String,
    pending: Vec<Published>,
}

#[zbus::interface(name = "org.freedesktop.Avahi.EntryGroup")]
impl FakeGroup {
    #[allow(clippy::too_many_arguments)]
    fn add_service(
        &mut self,
        interface: i32,
        protocol: i32,
        flags: u32,
        name: String,
        service_type: String,
        domain: String,
        host: String,
        port: u16,
        txt: Vec<Vec<u8>>,
    ) -> Result<(), FakeError> {
        let world = self.world.lock().unwrap();
        if world.published.iter().any(|p| p.group != self.path && p.name == name && p.service_type == service_type) {
            return Err(FakeError::CollisionError("Local name collision".into()));
        }
        self.pending.push(Published {
            group: self.path.clone(),
            interface,
            protocol,
            flags,
            name,
            service_type,
            domain,
            host,
            port,
            txt,
        });
        Ok(())
    }

    async fn commit(&mut self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> zbus::fdo::Result<()> {
        Self::state_changed(&emitter, group_state::REGISTERING, "").await?;
        let collides = {
            let mut world = self.world.lock().unwrap();
            world.commits += 1;
            let collides = self.pending.iter().any(|p| world.taken_remote.contains(&p.name));
            if !collides {
                world.published.append(&mut self.pending);
            }
            collides
        };
        let state = if collides { group_state::COLLISION } else { group_state::ESTABLISHED };
        Self::state_changed(&emitter, state, "").await?;
        Ok(())
    }

    async fn reset(&mut self, #[zbus(signal_emitter)] emitter: SignalEmitter<'_>) -> zbus::fdo::Result<()> {
        self.pending.clear();
        self.world.lock().unwrap().published.retain(|p| p.group != self.path);
        Self::state_changed(&emitter, group_state::UNCOMMITED, "").await?;
        Ok(())
    }

    async fn free(&mut self, #[zbus(object_server)] server: &zbus::ObjectServer) -> zbus::fdo::Result<()> {
        self.world.lock().unwrap().groups_freed += 1;
        self.world.lock().unwrap().published.retain(|p| p.group != self.path);
        server.remove::<FakeGroup, _>(self.path.as_str()).await?;
        Ok(())
    }

    #[zbus(signal)]
    async fn state_changed(emitter: &SignalEmitter<'_>, state: i32, error: &str) -> zbus::Result<()>;
}

/// A fake avahi-daemon owning Avahi's name on `bus`; dropping the connection is the daemon exiting.
async fn fake_avahi(bus: &TestBus, world: &Shared) -> zbus::Connection {
    let connection = bus.connect().await;
    connection
        .object_server()
        .at("/", FakeServer { world: Arc::clone(world), next: AtomicUsize::new(0) })
        .await
        .unwrap();
    connection.request_name(AVAHI_NAME).await.unwrap();
    connection
}

fn published(world: &Shared) -> Vec<Published> {
    world.lock().unwrap().published.clone()
}

async fn until(what: &str, f: impl Fn() -> bool) {
    let deadline = tokio::time::Instant::now() + WAIT;
    while !f() {
        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

async fn registered_as(advertiser: &AvahiAdvertiser, name: Option<&str>) {
    let mut rx = advertiser.registered_name();
    tokio::time::timeout(WAIT, rx.wait_for(|n| n.as_deref() == name))
        .await
        .unwrap_or_else(|_| panic!("never registered as {name:?}; now {:?}", *advertiser.registered_name().borrow()))
        .unwrap();
}

// MARK: Against the fake

#[tokio::test(flavor = "multi_thread")]
async fn publishes_the_service_with_its_txt_record() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    let _avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    advertiser.advertise(ad("Desk", 4242)).await.unwrap();
    registered_as(&advertiser, Some("Desk")).await;
    let p = published(&world);
    assert_eq!(p.len(), 1);
    let p = &p[0];
    assert_eq!((p.interface, p.protocol, p.flags), (IF_UNSPEC, PROTO_UNSPEC, 0));
    assert_eq!((p.name.as_str(), p.service_type.as_str(), p.port), ("Desk", "_lain-test._tcp", 4242));
    assert_eq!((p.domain.as_str(), p.host.as_str()), ("", ""));
    assert_eq!(p.txt, txt_entries(&ad("Desk", 4242).txt).unwrap());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_name_another_host_has_is_renamed() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    world.lock().unwrap().taken_remote.extend(["Desk".to_owned(), "Desk #2".to_owned()]);
    let _avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    advertiser.advertise(ad("Desk", 4242)).await.unwrap();
    registered_as(&advertiser, Some("Desk #3")).await;
    assert_eq!(published(&world).iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["Desk #3"]);
    // A different ad starts again from the name it is given (the same one again would change nothing).
    world.lock().unwrap().taken_remote.clear();
    advertiser.advertise(ad("Desk", 4243)).await.unwrap();
    registered_as(&advertiser, Some("Desk")).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_name_this_host_already_publishes_is_renamed() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    let _avahi = fake_avahi(&bus, &world).await;
    let first = AvahiAdvertiser::new(bus.connect().await);
    first.advertise(ad("Desk", 1)).await.unwrap();
    registered_as(&first, Some("Desk")).await;
    let second = AvahiAdvertiser::new(bus.connect().await);
    second.advertise(ad("Desk", 2)).await.unwrap();
    registered_as(&second, Some("Desk #2")).await;
    let mut names: Vec<_> = published(&world).into_iter().map(|p| (p.name, p.port)).collect();
    names.sort();
    assert_eq!(names, [("Desk".to_owned(), 1), ("Desk #2".to_owned(), 2)]);
}

#[tokio::test(flavor = "multi_thread")]
async fn advertise_replaces_and_withdraw_is_idempotent() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    let _avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    advertiser.advertise(ad("Desk", 1)).await.unwrap();
    registered_as(&advertiser, Some("Desk")).await;
    advertiser.advertise(ad("Desk", 2)).await.unwrap();
    until("the new port", || published(&world).iter().map(|p| p.port).collect::<Vec<_>>() == [2]).await;
    registered_as(&advertiser, Some("Desk")).await;

    advertiser.withdraw().await;
    assert!(published(&world).is_empty());
    assert_eq!(*advertiser.registered_name().borrow(), None);
    advertiser.withdraw().await;
    assert!(published(&world).is_empty());

    advertiser.advertise(ad("Desk", 3)).await.unwrap();
    registered_as(&advertiser, Some("Desk")).await;
    assert_eq!(published(&world).len(), 1);
    let world = world.lock().unwrap();
    assert_eq!(world.groups_created, 3, "a fresh group per publish");
    assert_eq!(world.groups_freed, 2, "the earlier groups freed");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_invalid_ad_is_refused() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    let _avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    let mut bad = ad("Desk", 1);
    bad.txt.push(("a=b".into(), "c".into()));
    assert!(advertiser.advertise(bad).await.is_err());
    assert!(published(&world).is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_service_returns_after_avahi_daemon_restarts() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    let avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    advertiser.advertise(ad("Desk", 4242)).await.unwrap();
    registered_as(&advertiser, Some("Desk")).await;

    drop(avahi);
    registered_as(&advertiser, None).await;

    let restarted = new_world();
    let _avahi = fake_avahi(&bus, &restarted).await;
    registered_as(&advertiser, Some("Desk")).await;
    assert_eq!(published(&restarted).len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_ad_made_while_avahi_is_down_is_published_when_it_starts() {
    let Some(bus) = TestBus::start().await else { return };
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    assert!(matches!(advertiser.advertise(ad("Desk", 4242)).await, Err(PlatformError::Unavailable(_))));
    let world = new_world();
    let _avahi = fake_avahi(&bus, &world).await;
    registered_as(&advertiser, Some("Desk")).await;
    assert_eq!(published(&world).len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_withdrawn_ad_is_not_published_when_avahi_starts() {
    let Some(bus) = TestBus::start().await else { return };
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    let _ = advertiser.advertise(ad("Desk", 4242)).await;
    advertiser.withdraw().await;
    let world = new_world();
    let _avahi = fake_avahi(&bus, &world).await;
    // A later advertise goes through the same loop, so once it is published the restart was handled.
    let other = AvahiAdvertiser::new(bus.connect().await);
    other.advertise(ad("Other", 1)).await.unwrap();
    registered_as(&other, Some("Other")).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(published(&world).iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["Other"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn the_server_reregistering_resets_and_republishes() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    let avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    advertiser.advertise(ad("Desk", 4242)).await.unwrap();
    registered_as(&advertiser, Some("Desk")).await;

    let emit = async |state: i32| {
        world.lock().unwrap().server_state = state;
        avahi.emit_signal(None::<()>, "/", "org.freedesktop.Avahi.Server", "StateChanged", &(state, "")).await.unwrap();
    };
    emit(server_state::REGISTERING).await;
    registered_as(&advertiser, None).await;
    until("the reset", || published(&world).is_empty()).await;
    emit(server_state::RUNNING).await;
    registered_as(&advertiser, Some("Desk")).await;
    assert_eq!(published(&world).len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_ad_made_while_the_server_registers_waits_for_it() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    world.lock().unwrap().server_state = server_state::REGISTERING;
    let avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    advertiser.advertise(ad("Desk", 4242)).await.unwrap();
    assert!(published(&world).is_empty());
    world.lock().unwrap().server_state = server_state::RUNNING;
    avahi
        .emit_signal(None::<()>, "/", "org.freedesktop.Avahi.Server", "StateChanged", &(server_state::RUNNING, ""))
        .await
        .unwrap();
    registered_as(&advertiser, Some("Desk")).await;
}

/// A restarted avahi-daemon first probes its host name: the service waits for its `Running`, which must
/// come through the signal stream of the new daemon, not the old one.
#[tokio::test(flavor = "multi_thread")]
async fn a_restarted_daemon_that_starts_registering_gets_the_service_once_running() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    let avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    advertiser.advertise(ad("Desk", 4242)).await.unwrap();
    registered_as(&advertiser, Some("Desk")).await;
    drop(avahi);
    registered_as(&advertiser, None).await;

    let restarted = new_world();
    restarted.lock().unwrap().server_state = server_state::REGISTERING;
    let avahi = fake_avahi(&bus, &restarted).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(published(&restarted).is_empty());
    restarted.lock().unwrap().server_state = server_state::RUNNING;
    avahi
        .emit_signal(None::<()>, "/", "org.freedesktop.Avahi.Server", "StateChanged", &(server_state::RUNNING, ""))
        .await
        .unwrap();
    registered_as(&advertiser, Some("Desk")).await;
    assert_eq!(published(&restarted).len(), 1);
}

/// Review S2/R4: an ad refused before it reaches Avahi changes nothing: the earlier ad stays published,
/// registered and desired.
#[tokio::test(flavor = "multi_thread")]
async fn a_refused_ad_leaves_the_earlier_one_as_it_was() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    let avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    advertiser.advertise(ad("Desk", 1)).await.unwrap();
    registered_as(&advertiser, Some("Desk")).await;
    let mut bad = ad("Desk", 2);
    bad.txt.push(("a=b".into(), "c".into()));
    assert!(advertiser.advertise(bad).await.is_err());
    assert_eq!(*advertiser.registered_name().borrow(), Some("Desk".to_owned()));
    assert_eq!(published(&world).iter().map(|p| (p.name.as_str(), p.port)).collect::<Vec<_>>(), [("Desk", 1)]);
    // The earlier ad is still the one desired: re-publishing gives it back, not the refused one.
    let emit = async |state: i32| {
        world.lock().unwrap().server_state = state;
        avahi.emit_signal(None::<()>, "/", "org.freedesktop.Avahi.Server", "StateChanged", &(state, "")).await.unwrap();
    };
    emit(server_state::REGISTERING).await;
    registered_as(&advertiser, None).await;
    emit(server_state::RUNNING).await;
    registered_as(&advertiser, Some("Desk")).await;
    assert_eq!(published(&world).iter().map(|p| p.port).collect::<Vec<_>>(), [1]);
}

/// Review S3/R3: a COLLISION signalled for the previous ad must not rename the next one. Each publish uses
/// a fresh entry group, so the old group's queued signals go with it.
#[tokio::test(flavor = "multi_thread")]
async fn a_stale_collision_does_not_rename_the_next_ad() {
    let Some(bus) = TestBus::start().await else { return };
    let mut bad = vec![];
    for run in 0..20 {
        let world = new_world();
        world.lock().unwrap().taken_remote.insert("Desk".into());
        let avahi = fake_avahi(&bus, &world).await;
        let advertiser = AvahiAdvertiser::new(bus.connect().await);
        let _ = tokio::join!(advertiser.advertise(ad("Desk", 1)), advertiser.advertise(ad("Other", 2)));
        tokio::time::sleep(Duration::from_millis(100)).await;
        let names: Vec<String> = published(&world).into_iter().map(|p| p.name).collect();
        if names != ["Other"] || advertiser.registered_name().borrow().as_deref() != Some("Other") {
            bad.push((run, names));
        }
        drop(advertiser);
        drop(avahi);
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(bad.is_empty(), "renamed or lost the new ad: {bad:?}");
}

/// Review R5: the same ad again is a no-op: no withdrawal, no re-probe, and a renamed name stays.
#[tokio::test(flavor = "multi_thread")]
async fn the_same_ad_twice_changes_nothing() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    world.lock().unwrap().taken_remote.insert("Desk".to_owned());
    let _avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    advertiser.advertise(ad("Desk", 1)).await.unwrap();
    registered_as(&advertiser, Some("Desk #2")).await;
    let before = world.lock().unwrap().commits;
    advertiser.advertise(ad("Desk", 1)).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(world.lock().unwrap().commits, before, "re-published");
    assert_eq!(*advertiser.registered_name().borrow(), Some("Desk #2".to_owned()));
    assert_eq!(published(&world).iter().map(|p| p.name.as_str()).collect::<Vec<_>>(), ["Desk #2"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn dropping_the_advertiser_frees_the_group() {
    let Some(bus) = TestBus::start().await else { return };
    let world = new_world();
    let _avahi = fake_avahi(&bus, &world).await;
    let advertiser = AvahiAdvertiser::new(bus.connect().await);
    advertiser.advertise(ad("Desk", 4242)).await.unwrap();
    registered_as(&advertiser, Some("Desk")).await;
    drop(advertiser);
    until("the group freed", || published(&world).is_empty()).await;
}

// MARK: Live

#[derive(Debug)]
struct Resolved {
    name: String,
    port: u16,
    txt: Vec<Vec<u8>>,
}

/// One `ResolveService` on the real Avahi (used when `avahi-browse` isn't installed).
async fn resolve(bus: &zbus::Connection, name: &str, service_type: &str) -> zbus::Result<Resolved> {
    #[allow(clippy::type_complexity)]
    let reply: (i32, i32, String, String, String, String, i32, String, u16, Vec<Vec<u8>>, u32) = bus
        .call_method(
            Some(AVAHI_NAME),
            "/",
            Some("org.freedesktop.Avahi.Server"),
            "ResolveService",
            &(IF_UNSPEC, PROTO_UNSPEC, name, service_type, "local", PROTO_UNSPEC, 0u32),
        )
        .await?
        .body()
        .deserialize()?;
    Ok(Resolved { name: reply.2, port: reply.8, txt: reply.9 })
}

/// `avahi-browse -rpt <type>`'s resolved lines (`=;iface;proto;name;type;domain;host;address;port;txt`)
/// for `name`, or `None` without `avahi-browse`.
fn browse(name: &str, service_type: &str) -> Option<Vec<String>> {
    let output = std::process::Command::new("avahi-browse").args(["-rpt", service_type]).output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    // avahi-browse escapes the name in parsable output (`\032` for a space); ours has none.
    Some(text.lines().filter(|l| l.starts_with("=;") && l.split(';').nth(3) == Some(name)).map(str::to_owned).collect())
}

/// Publishes `_lain-test._tcp` (never `_lain._tcp`, which a real iPad on the network would see) under a test
/// name, browses it back, and withdraws it.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "publishes a test service on the local network through the system's avahi-daemon"]
async fn live_advertise_and_browse_back() {
    let name = format!("lain-test-{}", std::process::id());
    let service_type = "_lain-test._tcp";
    let advertiser = AvahiAdvertiser::system().await.unwrap();
    let ad = ServiceAd { name: name.clone(), service_type: service_type.into(), ..ad("", 9) };
    advertiser.advertise(ad.clone()).await.unwrap();
    let mut rx = advertiser.registered_name();
    tokio::time::timeout(Duration::from_secs(15), rx.wait_for(|n| n.is_some())).await.unwrap().unwrap();
    let registered = rx.borrow().clone().unwrap();
    eprintln!("registered as {registered:?}");

    let expected_txt = txt_entries(&ad.txt).unwrap();
    match browse(&registered, service_type) {
        Some(lines) => {
            eprintln!("avahi-browse: {lines:#?}");
            assert!(!lines.is_empty(), "avahi-browse didn't find {registered}");
            for line in &lines {
                let fields: Vec<&str> = line.split(';').collect();
                assert_eq!(fields[8], "9");
                for entry in &expected_txt {
                    assert!(fields[9].contains(&format!("\"{}\"", String::from_utf8_lossy(entry))), "{line}");
                }
            }
        }
        None => {
            eprintln!("avahi-browse isn't installed; resolving over D-Bus instead");
            let bus = zbus::Connection::system().await.unwrap();
            let resolved = resolve(&bus, &registered, service_type).await.unwrap();
            eprintln!("resolved: {resolved:?}");
            assert_eq!(resolved.name, registered);
            assert_eq!(resolved.port, 9);
            // Order isn't compared: Avahi 0.8's ResolveService answers the entries reversed (`id`, `vs`, `v`;
            // seen 2026-10-31), and DNS-SD readers (Swift's `NWTXTRecord` dictionary) don't depend on it.
            let mut got = resolved.txt.clone();
            got.sort();
            let mut want = expected_txt.clone();
            want.sort();
            assert_eq!(got, want);
        }
    }

    advertiser.withdraw().await;
    assert_eq!(*advertiser.registered_name().borrow(), None);
    let bus = zbus::Connection::system().await.unwrap();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while resolve(&bus, &registered, service_type).await.is_ok() {
        assert!(tokio::time::Instant::now() < deadline, "still resolvable after the withdrawal");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}
