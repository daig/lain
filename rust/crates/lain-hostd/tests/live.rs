//! Live tests of the real composition, for the lead: they run the `lain-hostd` binary on this desktop for 5 s and
//! stop it with SIGTERM. `#[ignore]`d; run one at a time, by hand, with no iPad attached:
//! `cargo test -p lain-hostd --test live -- --ignored --test-threads=1`.
//!
//! What each run does to the machine:
//! - Runs `target/debug/lain-hostd --config <temp dir>/config.toml`, logging to stderr (captured and printed
//!   at the end; `JOURNAL_STREAM` removed, so nothing goes to the journal; `RUST_LOG=debug` for lain's crates).
//! - If the video environment isn't pinned, it re-executes itself once with `__EGL_VENDOR_LIBRARY_FILENAMES`
//!   (Mesa's vendor file) and `LIBVA_DRIVER_NAME=radeonsi` set. No GPU library is loaded: video starts only
//!   for an iPad's session.
//! - Raises its own soft `RLIMIT_NOFILE` to 4096.
//! - Owns `dev.sub.lain.Host` on the session bus (exits 1 if a lain host already runs; the test then fails).
//! - Reads, or creates once, `~/.config/lain/host-id`, and reads `hostname1`'s PrettyHostname on the system bus.
//! - Probes the Secret Service (the login keyring's default collection; no secret is read or written while no
//!   iPad connects, except by the Wi-Fi listener below). Falls back to `~/.config/lain/secrets` only if there's
//!   no Secret Service at all.
//! - GNOME: `DisplayConfig.GetCurrentState` and a `MonitorsChanged` subscription; reads
//!   `~/.config/lain/arrangement.toml` if it exists; reads gsettings (double-click, key repeat, input sources).
//!   No ScreenCast or RemoteDesktop session, no virtual monitor, no `ApplyMonitorsConfig`, no input, no power
//!   inhibitor: all of those wait for an iPad's session.
//! - systemd user manager: `GetUnitFileState("lain-hostd.service")` at start and every 2 s (read only).
//! - Avahi: connects on the system bus.
//! - usbmuxd: `Listen` on `/var/run/usbmuxd`, retried every second while it isn't running (connecting may start
//!   the socket-activated daemon). With an iPad attached and lain open on it, a full session would start: the
//!   reason to run these with no iPad attached.
//! - After 5 s, SIGTERM; the test expects exit status 0 within 8 s, and the log to show a complete shutdown
//!   (`shutdown complete`, and not main's `exiting anyway`).
//!
//! The Wi-Fi-on run adds: the listener reads every lain pairing secret from the Secret Service. If there is at
//! least one, it listens on `[::]:<a free port>` on every interface (TLS-PSK only) and publishes `_lain._tcp`,
//! named after this computer, through Avahi on the LAN; both end at the stop. With no pairing, nothing listens
//! and nothing is advertised.

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn run_for_5s(config: &str) -> String {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("config.toml");
    std::fs::write(&path, config).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_lain-hostd"))
        .arg("--config")
        .arg(&path)
        .env_remove("JOURNAL_STREAM")
        .env("RUST_LOG", lain_hostd::DEFAULT_LOG_FILTER.replace("=info", "=debug"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start lain-hostd");
    // Read as it is written, so a full pipe never blocks the daemon.
    let mut stderr = child.stderr.take().unwrap();
    let reader = std::thread::spawn(move || {
        let mut log = String::new();
        let _ = stderr.read_to_string(&mut log);
        log
    });
    std::thread::sleep(Duration::from_secs(5));
    let early = child.try_wait().unwrap();
    if early.is_none() {
        rustix::process::kill_process(rustix::process::Pid::from_child(&child), rustix::process::Signal::TERM).unwrap();
    }
    let deadline = Instant::now() + Duration::from_secs(8);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("lain-hostd didn't stop within 8 s of SIGTERM");
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let log = reader.join().unwrap();
    eprintln!("---- lain-hostd's log ----\n{log}---- end ----");
    assert!(early.is_none(), "lain-hostd exited by itself: {early:?}");
    assert!(status.success(), "exit status {status:?}");
    assert!(log.contains("SIGTERM: stopping"), "no stop in the log");
    // Daemon::shutdown's own last line (the Wi-Fi status "Wi-Fi: off: stopped" would match a bare "stopped"),
    // and main's budget wasn't what ended it.
    assert!(log.contains("shutdown complete"), "the shutdown didn't finish");
    assert!(!log.contains("exiting anyway"), "the shutdown overran its 5 s");
    assert!(!log.contains("didn't stop within"), "the Wi-Fi half of the shutdown was cut short");
    assert!(log.contains("Waiting for iPad"), "no status line");
    log
}

#[test]
#[ignore = "live: runs lain-hostd on this desktop for 5 s with Wi-Fi off (see the module documentation)"]
fn live_start_run_5s_and_stop_wifi_off() {
    let log = run_for_5s("wifi = false\n");
    assert!(log.contains("Wi-Fi: off: turned off in config.toml"), "Wi-Fi wasn't off");
    assert!(!log.contains("advertising"), "something was advertised");
}

#[test]
#[ignore = "live: runs lain-hostd on this desktop for 5 s with Wi-Fi on: may listen on the LAN and publish an \
            Avahi ad if a pairing exists (see the module documentation)"]
fn live_start_run_5s_and_stop_wifi_on() {
    let log = run_for_5s("wifi = true\n");
    assert!(log.contains("Wi-Fi: "), "no Wi-Fi status");
    assert!(!log.contains("Wi-Fi failed"), "the listener failed");
    if log.contains("advertising") {
        assert!(log.contains("no longer advertised"), "the ad wasn't withdrawn at the stop");
    }
}
