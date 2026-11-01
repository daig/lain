//! The tray icon (a StatusNotifierItem, `ksni`; Ubuntu's GNOME shows it through its AppIndicator extension). Swift:
//! the menu-bar extra of `LainHostApp` (`HostController`'s status, Wi-Fi and video lines, Start at Login).
//!
//! Its menu shows the status, the Wi-Fi line and, while connected, the video lines, and switches Wi-Fi (as
//! `lain wifi on|off`, written to `config.toml`) and Start at Login (as `lain autostart on|off`).

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use ksni::TrayMethods;
use ksni::menu::{CheckmarkItem, RadioGroup, RadioItem, StandardItem, SubMenu};
use lain_linux_system::Autostart;
use lain_linux_system::autostart::UnitFile;
use lain_platform::RequirementState;
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::service::{
    Control, set_keep_alive_persisted, set_resume_after_stop_persisted, set_scale_persisted, set_wifi_persisted,
};

enum Action {
    Wifi(bool),
    StartAtLogin(bool),
    Scale(Option<f64>),
    KeepAlive(u32),
    Resume,
    ResumeAfterStop(bool),
}

/// The keep-alive choices offered, in seconds.
const KEEP_ALIVES: [u32; 6] = [0, 10, 30, 60, 300, 600];
/// The scales offered before a display has said which it supports (an iPad Pro 13" at 2752×2064).
const FALLBACK_SCALES: [f64; 4] = [1.0, 4.0 / 3.0, 2.0, 8.0 / 3.0];

fn scale_label(s: f64) -> String {
    format!("{}×", (s * 100.0).round() / 100.0)
}

fn keep_label(s: u32) -> String {
    match s {
        0 => "Off".into(),
        s if s % 60 == 0 => format!("{} min", s / 60),
        s => format!("{s} s"),
    }
}

struct LainTray {
    status: String,
    wifi: String,
    wifi_on: bool,
    video: Vec<String>,
    start_at_login: bool,
    connected: bool,
    scale: Option<f64>,
    scale_options: Vec<f64>,
    keep_alive: u32,
    /// Video was stopped on the desktop (GNOME's sharing indicator).
    stopped: bool,
    resume_after_stop: bool,
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
        if self.stopped {
            items.push(
                StandardItem {
                    label: "Resume video".into(),
                    activate: Box::new(|t: &mut Self| {
                        let _ = t.actions.send(Action::Resume);
                    }),
                    ..Default::default()
                }
                .into(),
            );
        }
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
        // Scale: the iPad's own, then what the desktop offers.
        let options = self.scale_options.clone();
        let selected = match self.scale {
            None => 0,
            Some(s) => {
                let nearest = options.iter().enumerate().min_by(|a, b| (a.1 - s).abs().total_cmp(&(b.1 - s).abs()));
                nearest.map_or(0, |(i, _)| i + 1)
            }
        };
        let mut scale_items = vec![RadioItem { label: "The iPad's own".into(), ..Default::default() }];
        scale_items.extend(options.iter().map(|s| RadioItem { label: scale_label(*s), ..Default::default() }));
        items.push(
            SubMenu {
                label: "Scale".into(),
                submenu: vec![
                    RadioGroup {
                        selected,
                        select: Box::new(move |t: &mut Self, i| {
                            let scale = if i == 0 { None } else { t.scale_options.get(i - 1).copied() };
                            let _ = t.actions.send(Action::Scale(scale));
                        }),
                        options: scale_items,
                    }
                    .into(),
                ],
                ..Default::default()
            }
            .into(),
        );
        let mut keeps: Vec<u32> = KEEP_ALIVES.to_vec();
        if !keeps.contains(&self.keep_alive) {
            keeps.push(self.keep_alive);
            keeps.sort_unstable();
        }
        let selected = keeps.iter().position(|k| *k == self.keep_alive).unwrap_or(0);
        let keep_items = keeps.iter().map(|k| RadioItem { label: keep_label(*k), ..Default::default() }).collect();
        items.push(
            SubMenu {
                label: "Keep display when the iPad leaves".into(),
                submenu: vec![
                    RadioGroup {
                        selected,
                        select: Box::new(move |t: &mut Self, i| {
                            if let Some(k) = keeps.get(i) {
                                let _ = t.actions.send(Action::KeepAlive(*k));
                            }
                        }),
                        options: keep_items,
                    }
                    .into(),
                ],
                ..Default::default()
            }
            .into(),
        );
        items.push(
            CheckmarkItem {
                label: "Resume after Stop sharing".into(),
                checked: self.resume_after_stop,
                activate: Box::new(|t: &mut Self| {
                    let _ = t.actions.send(Action::ResumeAfterStop(!t.resume_after_stop));
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
        scale: None,
        scale_options: FALLBACK_SCALES.to_vec(),
        keep_alive: 0,
        stopped: false,
        resume_after_stop: false,
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
        let (scale, options, keep_alive) =
            (control.scale_setting(), control.scale_options(), control.keep_alive_seconds());
        let (stopped, resume_after_stop) =
            (control.video_problem() == "capture stopped on the desktop", control.resume_after_stop());
        handle
            .update(|t| {
                t.connected = s.is_connected();
                t.status = s.title();
                t.wifi = w;
                t.wifi_on = on;
                t.video = video;
                t.start_at_login = login;
                t.scale = scale;
                if !options.is_empty() {
                    t.scale_options = options;
                }
                t.keep_alive = keep_alive;
                t.stopped = stopped;
                t.resume_after_stop = resume_after_stop;
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
                Action::Scale(scale) => {
                    info!(?scale, "tray: scale");
                    if let Err(e) = set_scale_persisted(&*control, Some(&config), scale) {
                        warn!("tray: {e}");
                    }
                }
                Action::Resume => {
                    info!("tray: resume video");
                    control.resume_video();
                }
                Action::ResumeAfterStop(on) => {
                    if let Err(e) = set_resume_after_stop_persisted(&*control, Some(&config), on) {
                        warn!("tray: {e}");
                    }
                }
                Action::KeepAlive(seconds) => {
                    info!(seconds, "tray: keep-alive");
                    if let Err(e) = set_keep_alive_persisted(&*control, Some(&config), seconds) {
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
