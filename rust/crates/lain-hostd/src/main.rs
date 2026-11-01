//! `lain-hostd`, the process (Swift: `LainHostEntry.main` and `HostController.init`): arguments, logging, the video
//! environment re-exec, the open-file limit, the runtime, single instance, the real composition and signals.
//! Everything it composes is in the library; this file only builds the real parts, which talk to the desktop,
//! usbmuxd, the Secret Service, systemd and Avahi.
//!
//! Exit status: 0 after SIGINT or SIGTERM; 1 if another lain host is running, or the session bus or GNOME can't
//! be reached; 2 if the config file is refused.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use clap::Parser;
use lain_gnome::{Gnome, GnomeConfig};
use lain_host::HostConfig;
use lain_hostd::process::{EnvironmentPlan, REEXEC_MARKER, environment_plan, raise_open_file_limit};
use lain_hostd::{
    BUS_NAME, CONFIG_FILE, Config, DEFAULT_LOG_FILTER, Daemon, DaemonOptions, LinuxPlatform, claim_bus_name,
};
use lain_linux_system::autostart::{UNIT_NAME, user_unit_dir};
use lain_linux_system::paths::{config_home, lain_dir};
use lain_linux_system::{Autostart, AvahiAdvertiser, SystemSecretStore, load_host_identity};
use lain_linux_video::{LinuxVideo, LinuxVideoConfig};
use lain_proto::VersionList;
use lain_usbmux::UsbMuxClient;
use tokio::signal::unix::{SignalKind, signal};
use tracing::{error, info, warn};

/// How long the shutdown may take before the process exits anyway.
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);

/// The lain host: the iPad as this computer's display, keyboard and trackpad, over USB or Wi-Fi.
#[derive(Debug, Parser)]
#[command(name = "lain-hostd", version)]
struct Args {
    /// The config file [default: $XDG_CONFIG_HOME/lain/config.toml].
    #[arg(long, value_name = "PATH")]
    config: Option<PathBuf>,
}

fn main() -> ExitCode {
    let args = Args::parse();
    init_logging();
    // Before any thread exists (the runtime is made below): a re-exec replaces this process.
    prepare_environment();
    match raise_open_file_limit() {
        Ok(Some(limit)) => info!("open-file limit raised to {limit}"),
        Ok(None) => {}
        Err(e) => warn!("couldn't raise the open-file limit: {e}"),
    }
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(e) => {
            error!("couldn't start the runtime: {e}");
            return ExitCode::FAILURE;
        }
    };
    let code = runtime.block_on(run(args));
    runtime.shutdown_timeout(Duration::from_secs(1));
    code
}

/// journald under systemd (`JOURNAL_STREAM` set), else stderr; `RUST_LOG` overrides [`DEFAULT_LOG_FILTER`].
/// Starts no thread.
fn init_logging() {
    use tracing_subscriber::prelude::*;
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(DEFAULT_LOG_FILTER));
    let journald = match std::env::var_os("JOURNAL_STREAM") {
        Some(_) => match tracing_journald::layer() {
            Ok(layer) => Some(layer.with_syslog_identifier("lain-hostd".into())),
            Err(e) => {
                eprintln!("lain-hostd: journald unavailable ({e}); logging to stderr");
                None
            }
        },
        None => None,
    };
    let stderr = journald.is_none().then(|| tracing_subscriber::fmt::layer().with_writer(std::io::stderr));
    tracing_subscriber::registry().with(filter).with(journald).with(stderr).init();
}

/// The video environment pin (`lain_linux_video::check_environment`): re-exec once with the pins set on the
/// command (never `set_var`), else go on and let video report why it can't start.
fn prepare_environment() {
    let check = lain_linux_video::check_environment().map_err(|e| e.to_string());
    let reexeced = std::env::var_os(REEXEC_MARKER).is_some();
    match environment_plan(check, reexeced, || LinuxVideo::required_environment().map_err(|e| e.to_string())) {
        EnvironmentPlan::Ready => {}
        EnvironmentPlan::Reexec(pairs) => {
            use std::os::unix::process::CommandExt;
            let names: Vec<_> = pairs.iter().map(|(k, v)| format!("{k}={v}")).collect();
            info!("re-executing with the video environment pinned: {}", names.join(" "));
            let mut argv = std::env::args_os();
            let mut command = std::process::Command::new("/proc/self/exe");
            if let Some(argv0) = argv.next() {
                command.arg0(argv0);
            }
            let error = command.args(argv).envs(pairs).env(REEXEC_MARKER, "1").exec();
            warn!("couldn't re-execute ({error}); video won't start");
        }
        EnvironmentPlan::GoOn(why) => warn!("{why}; video won't start"),
    }
}

async fn run(args: Args) -> ExitCode {
    let config_home = match config_home() {
        Ok(home) => home,
        Err(e) => {
            error!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let dir = lain_dir(&config_home);

    // Single instance (replaces Swift's LoginAgent.settleInstance).
    let conn = match zbus::Connection::session().await {
        Ok(conn) => conn,
        Err(e) => {
            error!("no session bus: {e}");
            return ExitCode::FAILURE;
        }
    };
    match claim_bus_name(&conn).await {
        Ok(true) => {}
        Ok(false) => {
            error!("another lain host is running (it owns {BUS_NAME}); exiting");
            return ExitCode::FAILURE;
        }
        Err(e) => {
            error!("couldn't own {BUS_NAME}: {e}");
            return ExitCode::FAILURE;
        }
    }

    let config_path = args.config.unwrap_or_else(|| dir.join(CONFIG_FILE));
    let config = match Config::load(&config_path) {
        Ok(config) => config,
        Err(e) => {
            error!("{e}");
            return ExitCode::from(2);
        }
    };
    let versions = VersionList::offered().clone();
    info!("lain-hostd {}, protocol {versions}, config {}", env!("CARGO_PKG_VERSION"), config_path.display());

    // Without an id the host runs USB-only (Swift's HostController).
    let identity = match load_host_identity().await {
        Ok(identity) => Some(identity),
        Err(e) => {
            warn!("couldn't load this computer's lain id ({e}); Wi-Fi stays off");
            None
        }
    };
    let secrets = Arc::new(SystemSecretStore::open(&dir).await);
    info!("pairing secrets: {}", secrets.describe());

    let gnome = match Gnome::with_connection(conn.clone(), GnomeConfig { barrier: config.barrier(), arrangement_path: None })
        .await
    {
        Ok(gnome) => gnome,
        Err(e) => {
            error!("GNOME: {e}");
            return ExitCode::FAILURE;
        }
    };
    let autostart = Autostart::new(conn.clone(), &user_unit_dir(&config_home), UNIT_NAME);
    let platform = LinuxPlatform::new(gnome, LinuxVideo::new(LinuxVideoConfig::default()), autostart, secrets);

    let host = HostConfig {
        versions,
        identity,
        video: config.pipeline_options(),
        input: config.input_config(),
        ..HostConfig::default()
    };
    // Connected whenever there is an id, so that Wi-Fi switched on at run time is advertised too; it publishes
    // nothing until the listener listens.
    let advertiser = match &host.identity {
        Some(_) => match AvahiAdvertiser::system().await {
            Ok(advertiser) => Some(advertiser),
            Err(e) => {
                warn!("Avahi unavailable ({e}): Wi-Fi listens but isn't advertised");
                None
            }
        },
        None => None,
    };
    let options = DaemonOptions { wifi: config.wifi, ..DaemonOptions::default() };
    let daemon = Daemon::start(platform, host, UsbMuxClient::default(), advertiser, options).await;

    let (mut term, mut int) = match (signal(SignalKind::terminate()), signal(SignalKind::interrupt())) {
        (Ok(term), Ok(int)) => (term, int),
        (Err(e), _) | (_, Err(e)) => {
            error!("couldn't watch for signals: {e}");
            daemon.shutdown().await;
            return ExitCode::FAILURE;
        }
    };
    tokio::select! {
        _ = term.recv() => info!("SIGTERM: stopping"),
        _ = int.recv() => info!("SIGINT: stopping"),
    }
    tokio::spawn(async move {
        tokio::select! {
            _ = term.recv() => {}
            _ = int.recv() => {}
        }
        error!("a second signal: exiting at once");
        std::process::exit(1);
    });
    if tokio::time::timeout(SHUTDOWN_TIMEOUT, daemon.shutdown()).await.is_err() {
        warn!("the shutdown took longer than {SHUTDOWN_TIMEOUT:?}; exiting anyway");
    }
    ExitCode::SUCCESS
}
