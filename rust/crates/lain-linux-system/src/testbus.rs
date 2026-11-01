//! A private D-Bus daemon for tests, so the D-Bus clients can be tested against fake services without
//! touching the real session or system bus. Its configuration has no service directories, so nothing is
//! ever activated on it. Tests that need it skip (with a note) when `dbus-daemon` isn't installed.

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};

pub(crate) struct TestBus {
    child: Child,
    address: String,
    _dir: tempfile::TempDir,
}

impl TestBus {
    /// `None` (after printing why) when no `dbus-daemon` can be started.
    pub(crate) async fn start() -> Option<TestBus> {
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

    /// A new connection to this bus.
    pub(crate) async fn connect(&self) -> zbus::Connection {
        zbus::connection::Builder::address(self.address.as_str()).unwrap().build().await.unwrap()
    }
}

impl Drop for TestBus {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
