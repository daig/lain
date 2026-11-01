//! Single instance, on a private dbus-daemon this test starts (never the developer's session bus): the first
//! process to request `dev.sub.lain.Host` owns it, a second is refused (`DoNotQueue`), and the name is free again
//! once its owner's connection ends. Skipped, with a note, where `dbus-daemon` isn't installed.

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use lain_hostd::{BUS_NAME, claim_bus_name};

struct TestBus {
    child: Child,
    address: String,
    _dir: tempfile::TempDir,
}

impl TestBus {
    /// A private session-type bus with no service directories (nothing is ever activated on it), in a temp dir.
    async fn start() -> Option<TestBus> {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("bus");
        let config = dir.path().join("bus.conf");
        std::fs::write(
            &config,
            format!(
                r#"<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path={}</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
"#,
                socket.display()
            ),
        )
        .unwrap();
        let mut child = match Command::new("dbus-daemon")
            .arg(format!("--config-file={}", config.display()))
            .args(["--nofork", "--print-address=1"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
        {
            Ok(child) => child,
            Err(e) => {
                eprintln!("skipped: no dbus-daemon ({e})");
                return None;
            }
        };
        let stdout = child.stdout.take().unwrap();
        let address = tokio::task::spawn_blocking(move || {
            let mut line = String::new();
            BufReader::new(stdout).read_line(&mut line).map(|_| line.trim().to_owned())
        })
        .await
        .unwrap()
        .unwrap();
        assert!(!address.is_empty(), "dbus-daemon printed no address");
        Some(TestBus { child, address, _dir: dir })
    }

    async fn connect(&self) -> zbus::Connection {
        zbus::connection::Builder::address(self.address.as_str()).unwrap().build().await.unwrap()
    }
}

impl Drop for TestBus {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn one_host_owns_the_name() {
    let Some(bus) = TestBus::start().await else { return };
    let first = bus.connect().await;
    let second = bus.connect().await;
    assert!(claim_bus_name(&first).await.unwrap(), "the first host owns it");
    assert!(!claim_bus_name(&second).await.unwrap(), "a second host is refused, not queued");
    assert!(claim_bus_name(&first).await.unwrap(), "asking again changes nothing");

    let dbus = zbus::fdo::DBusProxy::new(&second).await.unwrap();
    let owner = dbus.get_name_owner(BUS_NAME.try_into().unwrap()).await.unwrap();
    assert_eq!(owner.as_str(), first.unique_name().unwrap().as_str());
    // DoNotQueue: the refused host isn't waiting in line.
    let queued = dbus.list_queued_owners(BUS_NAME.try_into().unwrap()).await.unwrap();
    assert_eq!(queued.len(), 1, "{queued:?}");

    // Once the first host's connection is gone, a new host can start.
    drop(first);
    let third = bus.connect().await;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while !claim_bus_name(&third).await.unwrap() {
        assert!(tokio::time::Instant::now() < deadline, "the name was never freed");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A [`lain_hostd::Control`] driven by the test.
struct FakeControl {
    status: tokio::sync::watch::Sender<lain_host::HostStatus>,
    wifi: tokio::sync::watch::Sender<lain_wifi::WiFiStatus>,
    enabled: tokio::sync::watch::Sender<bool>,
    keep_alive: std::sync::atomic::AtomicU32,
    scale: std::sync::Mutex<Option<f64>>,
}

impl lain_hostd::Control for FakeControl {
    fn status_watch(&self) -> tokio::sync::watch::Receiver<lain_host::HostStatus> {
        self.status.subscribe()
    }
    fn wifi_status(&self) -> tokio::sync::watch::Receiver<lain_wifi::WiFiStatus> {
        self.wifi.subscribe()
    }
    fn wifi_enabled(&self) -> tokio::sync::watch::Receiver<bool> {
        self.enabled.subscribe()
    }
    fn video_lines(&self) -> Vec<String> {
        vec!["Video 2752×2064 4:2:0".into()]
    }
    fn video_problem(&self) -> String {
        String::new()
    }
    fn peer_version_note(&self) -> String {
        String::new()
    }
    fn set_wifi(
        &self,
        on: bool,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<(), lain_hostd::WifiControlError>> + Send + '_>>
    {
        self.enabled.send_replace(on);
        self.wifi.send_replace(if on {
            lain_wifi::WiFiStatus::Starting
        } else {
            lain_wifi::WiFiStatus::Off("stopped".into())
        });
        Box::pin(async { Ok(()) })
    }
    fn refresh_setup(&self) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send + '_>> {
        Box::pin(async {})
    }
    fn keep_alive_seconds(&self) -> u32 {
        self.keep_alive.load(std::sync::atomic::Ordering::Relaxed)
    }
    fn set_keep_alive_seconds(&self, seconds: u32) {
        self.keep_alive.store(seconds, std::sync::atomic::Ordering::Relaxed)
    }
    fn resume_video(&self) -> bool {
        false
    }
    fn resume_after_stop(&self) -> bool {
        true
    }
    fn set_resume_after_stop(&self, _on: bool) {}
    fn scale_setting(&self) -> Option<f64> {
        *self.scale.lock().unwrap()
    }
    fn applied_scale(&self) -> Option<f64> {
        Some(self.scale_setting().map_or(2.0, |_| 4.0 / 3.0))
    }
    fn scale_options(&self) -> Vec<f64> {
        vec![1.0, 4.0 / 3.0, 2.0, 8.0 / 3.0]
    }
    fn set_scale(&self, scale: Option<f64>) {
        *self.scale.lock().unwrap() = scale;
    }
}

/// The control interface the `lain` CLI uses: properties read the daemon, `SetWifi` switches it and writes
/// `wifi` into config.toml, and a status change is announced (`PropertiesChanged`).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_control_interface_reads_switches_and_announces() {
    let Some(bus) = TestBus::start().await else { return };
    let daemon = bus.connect().await;
    assert!(claim_bus_name(&daemon).await.unwrap());
    let control = std::sync::Arc::new(FakeControl {
        status: tokio::sync::watch::Sender::new(lain_host::HostStatus::WaitingForIPad),
        wifi: tokio::sync::watch::Sender::new(lain_wifi::WiFiStatus::Off("no paired iPad yet".into())),
        enabled: tokio::sync::watch::Sender::new(true),
        keep_alive: std::sync::atomic::AtomicU32::new(30),
        scale: std::sync::Mutex::new(None),
    });
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("config.toml");
    std::fs::write(&config, "# mine\nscale = 1.5\n").unwrap();
    lain_hostd::serve(&daemon, control.clone(), Some(config.clone())).await.unwrap();

    let cli = bus.connect().await;
    let host: zbus::Proxy<'_> = zbus::proxy::Builder::new(&cli)
        .destination(BUS_NAME)
        .unwrap()
        .path(lain_hostd::OBJECT_PATH)
        .unwrap()
        .interface(lain_hostd::INTERFACE)
        .unwrap()
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await
        .unwrap();
    assert_eq!(host.get_property::<String>("Status").await.unwrap(), "Waiting for iPad");
    assert_eq!(host.get_property::<String>("WifiStatus").await.unwrap(), "Wi-Fi: off: no paired iPad yet");
    assert_eq!(host.get_property::<Vec<String>>("VideoLines").await.unwrap(), ["Video 2752×2064 4:2:0"]);

    host.call_method("SetWifi", &(false,)).await.unwrap();
    assert!(!*control.enabled.borrow());
    assert_eq!(std::fs::read_to_string(&config).unwrap(), "# mine\nscale = 1.5\nwifi = false\n");

    // Scale and keep-alive: applied, written, refused out of bounds, and back to the iPad's own.
    assert_eq!(host.get_property::<f64>("Scale").await.unwrap(), 0.0);
    host.call_method("SetScale", &(1.5f64,)).await.unwrap();
    assert_eq!(*control.scale.lock().unwrap(), Some(1.5));
    assert_eq!(host.get_property::<f64>("AppliedScale").await.unwrap(), 4.0 / 3.0);
    assert!(host.call_method("SetScale", &(4.0f64,)).await.is_err(), "out of bounds");
    host.call_method("SetKeepAlive", &(60u32,)).await.unwrap();
    assert_eq!(host.get_property::<u32>("KeepAliveSeconds").await.unwrap(), 60);
    assert!(host.call_method("SetKeepAlive", &(601u32,)).await.is_err());
    assert_eq!(
        std::fs::read_to_string(&config).unwrap(),
        "# mine\nscale = 1.5\nwifi = false\nkeep_alive_seconds = 60\n"
    );
    host.call_method("SetScale", &(0.0f64,)).await.unwrap();
    assert_eq!(*control.scale.lock().unwrap(), None);
    assert_eq!(std::fs::read_to_string(&config).unwrap(), "# mine\nwifi = false\nkeep_alive_seconds = 60\n");
    host.call_method("SetBitrate", &(40u32,)).await.unwrap();
    assert!(std::fs::read_to_string(&config).unwrap().contains("bitrate_mbps = 40\n"));

    let watcher = zbus::Proxy::new(&cli, BUS_NAME, lain_hostd::OBJECT_PATH, lain_hostd::INTERFACE).await.unwrap();
    let mut changes = watcher.receive_property_changed::<String>("Status").await;
    control.status.send_replace(lain_host::HostStatus::WaitingForIPad); // same value: no news
    control.status.send_replace(lain_host::HostStatus::connected_usb("iPad16,6"));
    let seen = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            use futures::StreamExt;
            let change = changes.next().await.expect("a change");
            let value = change.get().await.unwrap();
            if value != "Waiting for iPad" {
                return value;
            }
        }
    })
    .await
    .expect("announced");
    assert_eq!(seen, lain_host::HostStatus::connected_usb("iPad16,6").title());
}
