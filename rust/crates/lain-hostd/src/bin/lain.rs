//! `lain`: the command line for the lain host (wave 4b), on the daemon's control interface
//! (`dev.sub.lain.Host1`, see `lain_hostd::service`).
//!
//! - `lain status`: the host's status, Wi-Fi, video and Start at Login.
//! - `lain wifi on|off`: switches Wi-Fi now and in `config.toml`.
//! - `lain autostart on|off`: installs and enables (or disables) the systemd user unit that starts
//!   `lain-hostd` with the desktop session; works whether or not the daemon runs.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand, ValueEnum};
use lain_hostd::{BUS_NAME, INTERFACE, OBJECT_PATH};
use lain_linux_system::Autostart;
use lain_linux_system::autostart::{AutostartState, UnitFile};

#[derive(Parser)]
#[command(name = "lain", version, about = "Control the lain host: the iPad as this computer's display")]
struct Args {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Show the host's status.
    Status,
    /// Switch Wi-Fi (listening and advertising for the iPad) on or off, now and after restarts.
    Wifi { state: OnOff },
    /// Start lain-hostd with the desktop session, or not.
    Autostart { state: OnOff },
}

#[derive(Clone, Copy, ValueEnum)]
enum OnOff {
    On,
    Off,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> ExitCode {
    let args = Args::parse();
    match run(args.command).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("lain: {e}");
            ExitCode::FAILURE
        }
    }
}

async fn host(conn: &zbus::Connection) -> Result<Option<zbus::Proxy<'static>>, String> {
    let dbus = zbus::fdo::DBusProxy::new(conn).await.map_err(|e| e.to_string())?;
    let name = zbus::names::BusName::try_from(BUS_NAME).map_err(|e| e.to_string())?;
    if !dbus.name_has_owner(name).await.map_err(|e| e.to_string())? {
        return Ok(None);
    }
    let proxy =
        zbus::Proxy::new_owned(conn.clone(), BUS_NAME, OBJECT_PATH, INTERFACE).await.map_err(|e| e.to_string())?;
    Ok(Some(proxy))
}

/// `lain-hostd` next to this program (both are installed together).
fn daemon_path() -> Result<PathBuf, String> {
    let me = std::env::current_exe().map_err(|e| format!("where am I: {e}"))?;
    let path = me.with_file_name("lain-hostd");
    if !path.exists() {
        return Err(format!("{} isn't there (install lain-hostd next to lain)", path.display()));
    }
    Ok(path)
}

fn describe(state: &AutostartState) -> String {
    match state {
        AutostartState::Enabled => "on".into(),
        AutostartState::Disabled => "off (installed, not enabled)".into(),
        AutostartState::NotInstalled => "off".into(),
        AutostartState::Other(s) => format!("systemd says {s}"),
        AutostartState::Unknown(why) => format!("unknown ({why})"),
    }
}

async fn run(command: Command) -> Result<(), String> {
    let conn = zbus::Connection::session().await.map_err(|e| format!("no session bus: {e}"))?;
    match command {
        Command::Status => {
            let autostart = Autostart::session().await.map_err(|e| e.to_string())?;
            let login = describe(&autostart.state().await);
            let Some(host) = host(&conn).await? else {
                println!("lain-hostd isn't running");
                println!("Start at login: {login}");
                return Ok(());
            };
            let text = |name: &'static str| {
                let host = host.clone();
                async move { host.get_property::<String>(name).await.unwrap_or_default() }
            };
            println!("{}", text("Status").await);
            println!("{}", text("WifiStatus").await);
            let lines: Vec<String> = host.get_property("VideoLines").await.unwrap_or_default();
            for l in lines {
                println!("{l}");
            }
            let problem = text("VideoProblem").await;
            if !problem.is_empty() {
                println!("No video: {problem}");
            }
            let note = text("PeerVersionNote").await;
            if !note.is_empty() {
                println!("{note}");
            }
            println!("Start at login: {login}");
            Ok(())
        }
        Command::Wifi { state } => {
            let on = matches!(state, OnOff::On);
            let host = host(&conn).await?.ok_or("lain-hostd isn't running")?;
            host.call_method("SetWifi", &(on,)).await.map_err(|e| e.to_string())?;
            println!("Wi-Fi {}", if on { "on" } else { "off" });
            Ok(())
        }
        Command::Autostart { state } => {
            let autostart = Autostart::session().await.map_err(|e| e.to_string())?;
            match state {
                OnOff::On => {
                    let program = daemon_path()?;
                    autostart.enable(&UnitFile::host(&program)).await.map_err(|e| e.to_string())?;
                    println!("lain-hostd ({}) starts with the desktop session", program.display());
                }
                OnOff::Off => {
                    autostart.disable().await.map_err(|e| e.to_string())?;
                    println!("lain-hostd no longer starts with the desktop session");
                }
            }
            if let Some(host) = host(&conn).await? {
                let _ = host.call_method("RefreshSetup", &()).await;
            }
            Ok(())
        }
    }
}
