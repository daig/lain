//! The tray icon (a StatusNotifierItem, `ksni`; Ubuntu's GNOME shows it through its AppIndicator extension). Swift:
//! the menu-bar extra of `LainHostApp` (`HostController`'s status, Wi-Fi and video lines, Start at Login).
//!
//! Its menu shows the status, the Wi-Fi line and, while connected, the video lines, and switches Wi-Fi (as
//! `lain wifi on|off`, written to `config.toml`) and Start at Login (as `lain autostart on|off`).

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use ksni::TrayMethods;
use ksni::menu::{CheckmarkItem, StandardItem};
use lain_linux_system::Autostart;
use lain_linux_system::autostart::UnitFile;
use lain_platform::RequirementState;
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::service::{Control, set_wifi_persisted};

enum Action {
    Wifi(bool),
    StartAtLogin(bool),
}

struct LainTray {
    status: String,
    wifi: String,
    wifi_on: bool,
    video: Vec<String>,
    start_at_login: bool,
    connected: bool,
    actions: mpsc::UnboundedSender<Action>,
}

impl ksni::Tray for LainTray {
    fn id(&self) -> String {
        "lain-hostd".into()
    }

    fn title(&self) -> String {
        "lain".into()
    }

    fn icon_name(&self) -> String {
        // Connected: a display; waiting: a tablet.
        if self.connected { "video-display" } else { "input-tablet" }.into()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip { title: "lain".into(), description: self.status.clone(), ..Default::default() }
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        let line = |label: &str| StandardItem { label: label.into(), enabled: false, ..Default::default() }.into();
        let mut items: Vec<ksni::MenuItem<Self>> = vec![line(&self.status), line(&self.wifi)];
        items.extend(self.video.iter().map(|l| line(l)));
        items.push(ksni::MenuItem::Separator);
        items.push(
            CheckmarkItem {
                label: "Wi-Fi".into(),
                checked: self.wifi_on,
                activate: Box::new(|t: &mut Self| {
                    let _ = t.actions.send(Action::Wifi(!t.wifi_on));
                }),
                ..Default::default()
            }
            .into(),
        );
        items.push(
            CheckmarkItem {
                label: "Start at login".into(),
                checked: self.start_at_login,
                activate: Box::new(|t: &mut Self| {
                    let _ = t.actions.send(Action::StartAtLogin(!t.start_at_login));
                }),
                ..Default::default()
            }
            .into(),
        );
        items
    }
}

/// Shows the tray icon and keeps it current; logs and returns if there is no tray host.
pub async fn run(control: Arc<dyn Control>, autostart: Autostart, program: PathBuf, config: PathBuf) {
    let (actions, mut requests) = mpsc::unbounded_channel();
    let tray = LainTray {
        status: String::new(),
        wifi: String::new(),
        wifi_on: false,
        video: Vec::new(),
        start_at_login: false,
        connected: false,
        actions,
    };
    let handle = match tray.spawn().await {
        Ok(handle) => handle,
        Err(e) => {
            warn!("no tray icon: {e}");
            return;
        }
    };
    let (mut status, mut wifi, mut enabled) = (control.status_watch(), control.wifi_status(), control.wifi_enabled());
    let mut tick = tokio::time::interval(Duration::from_secs(2));
    loop {
        let (s, w, on, video) = (
            status.borrow_and_update().clone(),
            wifi.borrow_and_update().title(),
            *enabled.borrow_and_update(),
            control.video_lines(),
        );
        let login = autostart.start_at_login() == RequirementState::Granted;
        handle
            .update(|t| {
                t.connected = s.is_connected();
                t.status = s.title();
                t.wifi = w;
                t.wifi_on = on;
                t.video = video;
                t.start_at_login = login;
            })
            .await;
        tokio::select! {
            Ok(()) = status.changed() => {}
            Ok(()) = wifi.changed() => {}
            Ok(()) = enabled.changed() => {}
            _ = tick.tick() => {}
            Some(action) = requests.recv() => match action {
                Action::Wifi(on) => {
                    if let Err(e) = set_wifi_persisted(&*control, Some(&config), on).await {
                        warn!("tray: {e}");
                    }
                }
                Action::StartAtLogin(on) => {
                    info!(on, "tray: Start at Login");
                    let result = if on { autostart.enable(&UnitFile::host(&program)).await } else { autostart.disable().await };
                    if let Err(e) = result {
                        warn!("tray: Start at Login: {e}");
                    }
                    autostart.state().await;
                    control.refresh_setup().await;
                }
            },
            else => break,
        }
    }
}
