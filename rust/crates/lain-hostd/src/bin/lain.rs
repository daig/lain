//! `lain`: the command line for the lain host (wave 4b), on the daemon's control interface
//! (`dev.sub.lain.Host1`, see `lain_hostd::service`).
//!
//! - `lain status`: the host's status, Wi-Fi, video and Start at Login.
//! - `lain wifi on|off`: switches Wi-Fi now and in `config.toml`.
//! - `lain autostart on|off`: installs and enables (or disables) the systemd user unit that starts
//!   `lain-hostd` with the desktop session; works whether or not the daemon runs.
//! - `lain scale [VALUE|own]`: lain's display's scale (the closest the desktop offers is applied), at once.
//! - `lain keep-alive [SECONDS]`: how long lain keeps its display after the iPad leaves, at once.
//! - `lain bitrate [MBPS]`: the video bitrate (the ceiling with adaptive bitrate), from the next start.
//! - `lain adaptive-bitrate [on|off]`: the bitrate follows the link, from the next start.
//! - `lain radio-priority [standard|interactive-video]`: how Wi-Fi connections ask for airtime, from the next
//!   start.
//!
//! Each setting is also written to `config.toml`, so it holds after a restart. Without a value, it is shown.

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
    /// Show or set lain's display's scale: a number from 1 to 3, or `own` for the iPad's own (2).
    Scale { value: Option<String> },
    /// Show or set how long lain keeps its display after the iPad leaves (0 to 600 seconds).
    KeepAlive { seconds: Option<u32> },
    /// Show or set the video bitrate in Mb/s (1 to 200; with adaptive bitrate, the most it uses); applies when
    /// the daemon next starts.
    Bitrate { mbps: Option<u32> },
    /// Show or set whether the bitrate follows what the link delivers; applies when the daemon next starts.
    AdaptiveBitrate { state: Option<OnOff> },
    /// Show or set how Wi-Fi connections ask for airtime: standard, or interactive-video (DSCP AF41); applies
    /// when the daemon next starts.
    RadioPriority { priority: Option<Priority> },
    /// Bring video back after "Stop sharing" in GNOME's top bar (the iPad reconnects).
    Resume,
    /// Show or set whether video comes back by itself after "Stop sharing".
    AutoResume { state: Option<OnOff> },
}

#[derive(Clone, Copy, ValueEnum)]
enum OnOff {
    On,
    Off,
}

#[derive(Clone, Copy, ValueEnum)]
enum Priority {
    Standard,
    InteractiveVideo,
}

fn config_path() -> Result<PathBuf, String> {
    let home = lain_linux_system::paths::config_home().map_err(|e| e.to_string())?;
    Ok(lain_linux_system::paths::lain_dir(&home).join(lain_hostd::CONFIG_FILE))
}

const NEXT_START: &str = " from the next start (systemctl --user restart lain-hostd)";

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
    // Uncached: values are read fresh, right after a change this program made.
    let proxy = zbus::proxy::Builder::new(conn)
        .destination(BUS_NAME)
        .and_then(|b| b.path(OBJECT_PATH))
        .and_then(|b| b.interface(INTERFACE))
        .map_err(|e| e.to_string())?
        .cache_properties(zbus::proxy::CacheProperties::No)
        .build()
        .await
        .map_err(|e| e.to_string())?;
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
            let scale: f64 = host.get_property("AppliedScale").await.unwrap_or(0.0);
            if scale > 0.0 {
                println!("Scale: {}", (scale * 100.0).round() / 100.0);
            }
            let keep: u32 = host.get_property("KeepAliveSeconds").await.unwrap_or(0);
            println!("Keep-alive: {keep} s");
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
        Command::Scale { value } => {
            let host = host(&conn).await?.ok_or("lain-hostd isn't running")?;
            if let Some(value) = value {
                let scale = if value == "own" {
                    0.0
                } else {
                    value.parse::<f64>().map_err(|_| format!("not a scale: {value}"))?
                };
                host.call_method("SetScale", &(scale,)).await.map_err(|e| e.to_string())?;
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            }
            let setting: f64 = host.get_property("Scale").await.map_err(|e| e.to_string())?;
            let applied: f64 = host.get_property("AppliedScale").await.unwrap_or(0.0);
            let options: Vec<f64> = host.get_property("ScaleOptions").await.unwrap_or_default();
            let setting =
                if setting > 0.0 { format!("{}", (setting * 100.0).round() / 100.0) } else { "the iPad's own".into() };
            println!("scale: {setting}");
            if applied > 0.0 {
                let opts: Vec<String> = options.iter().map(|s| format!("{}", (s * 100.0).round() / 100.0)).collect();
                println!("applied now: {} (the desktop offers {})", (applied * 100.0).round() / 100.0, opts.join(", "));
            }
            Ok(())
        }
        Command::Resume => {
            let host = host(&conn).await?.ok_or("lain-hostd isn't running")?;
            let reply = host.call_method("ResumeVideo", &()).await.map_err(|e| e.to_string())?;
            let resumed: bool = reply.body().deserialize().map_err(|e| e.to_string())?;
            println!(
                "{}",
                if resumed { "resuming: the iPad reconnects" } else { "nothing to resume: video isn't stopped" }
            );
            Ok(())
        }
        Command::AutoResume { state } => {
            let host = host(&conn).await?.ok_or("lain-hostd isn't running")?;
            if let Some(state) = state {
                host.call_method("SetResumeAfterStop", &(matches!(state, OnOff::On),))
                    .await
                    .map_err(|e| e.to_string())?;
            }
            let on: bool = host.get_property("ResumeAfterStop").await.map_err(|e| e.to_string())?;
            println!("resume after Stop sharing: {}", if on { "on" } else { "off" });
            Ok(())
        }
        Command::KeepAlive { seconds } => {
            let host = host(&conn).await?.ok_or("lain-hostd isn't running")?;
            if let Some(s) = seconds {
                host.call_method("SetKeepAlive", &(s,)).await.map_err(|e| e.to_string())?;
            }
            let s: u32 = host.get_property("KeepAliveSeconds").await.map_err(|e| e.to_string())?;
            println!("keep-alive: {s} s");
            Ok(())
        }
        Command::Bitrate { mbps } => {
            let path = lain_linux_system::paths::lain_dir(
                &lain_linux_system::paths::config_home().map_err(|e| e.to_string())?,
            )
            .join(lain_hostd::CONFIG_FILE);
            if let Some(m) = mbps {
                match host(&conn).await? {
                    Some(host) => host.call_method("SetBitrate", &(m,)).await.map(|_| ()).map_err(|e| e.to_string())?,
                    None => lain_hostd::config::set_top_level(&path, "bitrate_mbps", Some(&m.to_string()))?,
                }
                println!("bitrate: {m} Mb/s from the next start (systemctl --user restart lain-hostd)");
            } else {
                let config = lain_hostd::Config::load(&path).map_err(|e| e.to_string())?;
                println!("bitrate: {} Mb/s", config.bitrate_mbps);
            }
            Ok(())
        }
        Command::AdaptiveBitrate { state } => {
            let path = config_path()?;
            if let Some(state) = state {
                lain_hostd::config::set_top_level_bool(&path, "adaptive_bitrate", matches!(state, OnOff::On))?;
            }
            let on = lain_hostd::Config::load(&path).map_err(|e| e.to_string())?.adaptive_bitrate;
            let when = if state.is_some() { NEXT_START } else { "" };
            println!("adaptive bitrate: {}{when}", if on { "on" } else { "off" });
            Ok(())
        }
        Command::RadioPriority { priority } => {
            let path = config_path()?;
            if let Some(p) = priority {
                let value = match p {
                    Priority::Standard => lain_hostd::config::RadioPriority::Standard,
                    Priority::InteractiveVideo => lain_hostd::config::RadioPriority::InteractiveVideo,
                };
                lain_hostd::config::set_top_level(&path, "radio_priority", Some(&format!("\"{}\"", value.name())))?;
            }
            let p = lain_hostd::Config::load(&path).map_err(|e| e.to_string())?.radio_priority;
            let when = if priority.is_some() { NEXT_START } else { "" };
            println!("radio priority: {}{when}", p.name());
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
