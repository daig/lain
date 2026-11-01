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
