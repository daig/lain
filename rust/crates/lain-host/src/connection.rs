//! One live link (Swift: `HostConnection` in `HostSession.swift`): the realtime handler, the warp sampler,
//! layout updates and teardown.

use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use lain_input::{InputRouter, Outcome};
use lain_link::{ChannelSender, Link, MessageChannel};
use lain_platform::{
    Clock, DisplayBackend, InputAction, InputBackend, Monitor, Platform, Requirement, RequirementState, SetupReport,
};
use lain_proto::{
    CursorWarp, DisplayLayout, HostSetup, KeyboardType, LayoutDisplay, Message, Pong, ProtocolFeature, SetupItem,
    SetupRequirement, SetupState, VersionList,
};
use tokio::sync::{Notify, watch};
use tokio::task::AbortHandle;
use tracing::info;

use crate::config::HostConfig;
use crate::util::Power;
use crate::video::SessionVideo;
use crate::warp::CursorWarpDetector;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// After video or audio closes alone, the rest of the link is closed this much later (Swift: 0.2 s).
const LONE_CLOSE_DELAY: Duration = Duration::from_millis(200);

/// Everything that touches input, under one lock that only the realtime reader takes (teardown and the
/// sampler aside), so input handling is uncontended and no input can slip in after the release.
struct Realtime {
    router: InputRouter,
    warp: CursorWarpDetector,
    last_activity_ns: Option<u64>,
    /// This connection took the power assertion (`start`), so `finish` must drop it.
    holds_power: bool,
    finished: bool,
    /// Reused for every message.
    actions: Vec<InputAction>,
}

/// One live link (Swift: `HostConnection`).
///
/// Invariants 3 and 4: input is handled synchronously in the realtime reader's task (no awaits, one
/// uncontended lock per message, `InputBackend::apply` never blocks), and [`finish`](Self::finish) releases
/// everything held exactly once, after the last input of the link.
pub(crate) struct HostConnection<P: Platform> {
    platform: Arc<P>,
    power: Arc<Power<P::Power>>,
    pub(crate) version: u8,
    local_versions: VersionList,
    pub(crate) realtime: ChannelSender,
    pub(crate) video_channel: ChannelSender,
    audio_channel: ChannelSender,
    /// The receiving ends, until `run` takes them.
    channels: Mutex<Option<[MessageChannel; 3]>>,
    /// The session's video; stopped by `finish`.
    pub(crate) video: Arc<SessionVideo>,
    /// Capture stopped on its own and closed the link (the next session backs off).
    pub(crate) capture_failed: AtomicBool,
    rt: Mutex<Realtime>,
    user_activity_interval_ns: u64,
    cursor_sample_hz: f64,
    /// The sampler and the layout watcher, cancelled by `finish`.
    tasks: Mutex<Vec<AbortHandle>>,
    last_layout: Mutex<Option<DisplayLayout>>,
    last_setup: Mutex<Option<HostSetup>>,
    /// Told when the layout may have changed: the streamed display came or went.
    layout_changed: Arc<Notify>,
    /// Set once realtime has closed or the connection was finished.
    ended: watch::Sender<bool>,
}

impl<P: Platform> HostConnection<P> {
    pub(crate) fn new(link: Link, platform: Arc<P>, power: Arc<Power<P::Power>>, config: &HostConfig) -> Arc<Self> {
        let Link { realtime, video, audio, version, local_versions, .. } = link;
        let layout_changed = Arc::new(Notify::new());
        let mut warp = config.tuning.warp;
        warp.reset();
        Arc::new(Self {
            platform,
            power,
            version,
            local_versions,
            realtime: realtime.sender(),
            video_channel: video.sender(),
            audio_channel: audio.sender(),
            channels: Mutex::new(Some([realtime, video, audio])),
            video: SessionVideo::new(layout_changed.clone()),
            capture_failed: AtomicBool::new(false),
            rt: Mutex::new(Realtime {
                router: InputRouter::new(config.input),
                warp,
                last_activity_ns: None,
                holds_power: false,
                finished: false,
                actions: Vec::with_capacity(64),
            }),
            user_activity_interval_ns: config.tuning.user_activity_interval_ns,
            cursor_sample_hz: config.tuning.cursor_sample_hz,
            tasks: Mutex::new(Vec::new()),
            last_layout: Mutex::new(None),
            last_setup: Mutex::new(None),
            layout_changed,
            ended: watch::Sender::new(false),
        })
    }

    /// Whether the session's version has `feature` (Swift: `link.supports`).
    pub(crate) fn supports(&self, feature: ProtocolFeature) -> bool {
        feature.is_supported(self.version)
    }

    /// What this session misses against this host's newest version (Swift: `link.olderPeerMisses`).
    pub(crate) fn older_peer_misses(&self) -> Vec<ProtocolFeature> {
        ProtocolFeature::missing(self.version, self.local_versions.newest())
    }

    pub(crate) fn close_link(&self) {
        self.realtime.close();
        self.video_channel.close();
        self.audio_channel.close();
    }

    /// Takes the power assertion unless the connection has already been finished (a detach or stop raced
    /// the handshake). Returns whether the session should go on.
    pub(crate) fn start(&self) -> bool {
        let mut s = lock(&self.rt);
        if s.finished {
            return false;
        }
        s.holds_power = true;
        self.power.begin();
        true
    }

    /// `finish` has run: a takeover, detach or stop ended the session.
    pub(crate) fn is_finished(&self) -> bool {
        lock(&self.rt).finished
    }

    /// The client's physical keyboard, from its `Hello` (Swift: `sink.setKeyboardType`, on the shared sink;
    /// here each link has its own router).
    pub(crate) fn set_keyboard_type(&self, keyboard_type: KeyboardType) {
        lock(&self.rt).router.set_keyboard_type(keyboard_type);
    }

    /// Reads every connection of the link until realtime closes (or the connection is finished), with the
    /// cursor sampler and the layout watcher running meanwhile.
    pub(crate) async fn run(self: &Arc<Self>) {
        let Some([mut realtime, mut video, mut audio]) = lock(&self.channels).take() else { return };
        let mut ended = self.ended.subscribe();
        if *ended.borrow() {
            return;
        }
        let mut handles = Vec::new();
        // Realtime carries the input: the session ends when it closes, after its last message is handled.
        let this = self.clone();
        handles.push(
            tokio::spawn(async move {
                while let Ok(env) = realtime.recv().await {
                    this.handle(&env.message);
                }
                this.ended.send_replace(true);
            })
            .abort_handle(),
        );
        // Frame acks (and any KeyframeRequest) go to the video; without it they're dropped. Read every channel:
        // each buffers only one frame unread, and notices the peer's close only once read.
        let this = self.clone();
        handles.push(
            tokio::spawn(async move {
                while let Ok(env) = video.recv().await {
                    if matches!(env.message, Message::FrameAck(_) | Message::KeyframeRequest(_)) {
                        this.video.handle(env.message);
                    }
                }
                tokio::time::sleep(LONE_CLOSE_DELAY).await;
                this.close_link();
            })
            .abort_handle(),
        );
        let this = self.clone();
        handles.push(
            tokio::spawn(async move {
                while audio.recv().await.is_ok() {}
                tokio::time::sleep(LONE_CLOSE_DELAY).await;
                this.close_link();
            })
            .abort_handle(),
        );
        let this = self.clone();
        handles.push(tokio::spawn(async move { this.sample_loop().await }).abort_handle());
        let this = self.clone();
        handles.push(tokio::spawn(async move { this.layout_loop().await }).abort_handle());
        let start_late = {
            let mut tasks = lock(&self.tasks);
            tasks.extend(handles);
            *self.ended.borrow()
        };
        if start_late {
            // `finish` ran while the tasks started: it may have missed them.
            lock(&self.tasks).drain(..).for_each(|t| t.abort());
            return;
        }
        let _ = ended.wait_for(|e| *e).await;
    }

    /// Idempotent teardown: stop video (the display goes in the background), stop sampling, close the
    /// link, release everything, drop the assertion.
    pub(crate) fn finish(&self) {
        self.video.stop();
        lock(&self.tasks).drain(..).for_each(|t| t.abort());
        self.close_link();
        let end_power = {
            let mut s = lock(&self.rt);
            if s.finished {
                false
            } else {
                s.finished = true;
                let Realtime { router, actions, .. } = &mut *s;
                actions.clear();
                router.release_all(actions);
                if !actions.is_empty() {
                    self.platform.input().apply(actions);
                }
                std::mem::take(&mut s.holds_power)
            }
        };
        if end_power {
            self.power.end();
        }
        self.ended.send_replace(true);
    }

    /// One realtime message (Swift: `HostConnection.handle`).
    pub(crate) fn handle(&self, message: &Message) {
        let clock = self.platform.clock();
        match message {
            Message::Ping(p) => {
                let received = clock.now_ns();
                let _ = self.realtime.send(&Message::Pong(Pong {
                    id: p.id,
                    ping_sent_at_ns: p.sent_at_ns,
                    received_at_ns: received,
                    sent_at_ns: clock.now_ns(),
                }));
                return;
            }
            // D22: loss recovery (and the client coming back to the foreground) is a keyframe.
            Message::KeyframeRequest(_) => {
                self.video.handle(message.clone());
                return;
            }
            _ => {}
        }
        let now = clock.now_ns();
        let declare = {
            let mut s = lock(&self.rt);
            if s.finished {
                return;
            }
            let Realtime { router, actions, warp, .. } = &mut *s;
            actions.clear();
            let outcome = router.handle_at(message, now, actions);
            if !actions.is_empty() {
                self.platform.input().apply(actions);
            }
            match outcome {
                Outcome::NotInput | Outcome::Ignored => false,
                Outcome::Injected { pointer } => {
                    warp.note_input(pointer, now);
                    self.activity_due(&mut s, now)
                }
                Outcome::Released => {
                    warp.note_input(None, now);
                    self.activity_due(&mut s, now)
                }
            }
        };
        if declare {
            self.power.user_activity();
        }
    }

    fn activity_due(&self, s: &mut Realtime, now: u64) -> bool {
        if let Some(last) = s.last_activity_ns
            && now < last.wrapping_add(self.user_activity_interval_ns)
        {
            return false;
        }
        s.last_activity_ns = Some(now);
        true
    }

    /// The warp sampler, which also sends `lain-input`'s held-back scroll stop when it is due.
    async fn sample_loop(&self) {
        let period = Duration::from_secs_f64(1.0 / self.cursor_sample_hz.max(1.0));
        let mut interval = tokio::time::interval_at(tokio::time::Instant::now() + period, period);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            self.sample();
        }
    }

    /// The real cursor in global logical pixels: a warp for the client when it moved on its own (§5.4).
    fn sample(&self) {
        let location = self.platform.display().cursor_location();
        let now = self.platform.clock().now_ns();
        let warp = {
            let mut s = lock(&self.rt);
            if s.finished {
                return;
            }
            let Realtime { router, actions, warp, .. } = &mut *s;
            actions.clear();
            if router.poll(now, actions) {
                self.platform.input().apply(actions);
            }
            location.and_then(|p| warp.sample(p, now))
        };
        if let Some(p) = warp {
            let _ = self.realtime.send(&Message::CursorWarp(CursorWarp { x: p.x, y: p.y }));
        }
    }

    /// Re-sends the layout whenever the monitors change, or the streamed display comes or goes.
    ///
    /// Difference from Swift, which re-reads the arrangement every 500 ms: the platform's monitor list is a
    /// watch, so a change goes out when it happens.
    async fn layout_loop(&self) {
        let mut monitors = self.platform.display().monitors();
        loop {
            tokio::select! {
                changed = monitors.changed() => if changed.is_err() { return },
                () = self.layout_changed.notified() => {}
            }
            self.send_layout_if_changed();
        }
    }

    /// The desktop: every monitor in global logical pixels, lain's display marked while it streams (Swift:
    /// `DisplayLayoutProvider.desktopLayout`).
    pub(crate) fn desktop_layout(&self) -> DisplayLayout {
        let streamed = self.video.streaming().map(|s| s.display.id);
        let monitors = self.platform.display().monitors();
        let displays = monitors
            .borrow()
            .iter()
            .map(|m| LayoutDisplay {
                display_id: m.id,
                x: m.bounds.x,
                y: m.bounds.y,
                width: m.bounds.width,
                height: m.bounds.height,
                is_streamed: Some(m.id) == streamed,
            })
            .collect();
        DisplayLayout { displays }
    }

    /// The streamed display's monitor, else the primary, else the first (Swift:
    /// `DisplayLayoutProvider.targetDisplay`).
    pub(crate) fn target_monitor(&self) -> Option<Monitor> {
        let streamed = self.video.streaming().map(|s| s.display.id);
        let monitors = self.platform.display().monitors();
        let all = monitors.borrow();
        all.iter()
            .find(|m| Some(m.id) == streamed)
            .or_else(|| all.iter().find(|m| m.primary))
            .or_else(|| all.first())
            .cloned()
    }

    /// Sends the desktop's `DisplayLayout` if it differs from the last one sent (the first always goes). A
    /// resolution change, a monitor added or removed, a new arrangement or a new streamed display just
    /// updates the client, which re-clamps its cursor; the session goes on.
    pub(crate) fn send_layout_if_changed(&self) {
        let layout = self.desktop_layout();
        if layout.displays.is_empty() {
            return;
        }
        let sent = {
            let mut last = lock(&self.last_layout);
            if last.as_ref() == Some(&layout) || *self.ended.borrow() {
                false
            } else {
                if last.is_some() {
                    info!(displays = layout.displays.len(), "display arrangement changed; sending the new layout");
                }
                let _ = self.realtime.send(&Message::DisplayLayout(layout.clone()));
                *last = Some(layout);
                true
            }
        };
        // A warp sent just before this layout was snapped against the old one on the client (the cursor may
        // only exist in the new arrangement): report the cursor again, after the layout.
        if sent {
            lock(&self.rt).warp.resync();
        }
    }

    /// Sends `setup` if it differs from the last one sent (the first always goes). The caller checked that
    /// the link's version has `HostSetup`.
    pub(crate) fn send_setup_if_changed(&self, setup: HostSetup) {
        let mut last = lock(&self.last_setup);
        if last.as_ref() == Some(&setup) || *self.ended.borrow() {
            return;
        }
        let _ = self.realtime.send(&Message::HostSetup(setup.clone()));
        *last = Some(setup);
    }
}

/// The wire's `HostSetup` from the platform's report and why there's no video (Swift: `HostSetupProbe`
/// plus the session's `videoProblem`). The platform reports only the items that mean something on it (on
/// GNOME no Screen Recording or Accessibility, L2), in its order.
pub(crate) fn host_setup(report: SetupReport, video_problem: String) -> HostSetup {
    let items = report
        .items
        .into_iter()
        .map(|(requirement, state)| SetupItem {
            requirement: match requirement {
                Requirement::ScreenCapture => SetupRequirement::ScreenRecording,
                Requirement::InputInjection => SetupRequirement::Accessibility,
                Requirement::LocalNetwork => SetupRequirement::LocalNetwork,
                Requirement::StartAtLogin => SetupRequirement::StartAtLogin,
            },
            state: match state {
                RequirementState::Granted => SetupState::Granted,
                RequirementState::Missing => SetupState::Missing,
                RequirementState::Unknown => SetupState::Unknown,
            },
        })
        .collect();
    HostSetup { items, video_problem, has_other_display: report.has_other_display }
}

impl<P: Platform> Drop for HostConnection<P> {
    fn drop(&mut self) {
        // A connection dropped without `finish` (turned away before serving) still closes its link.
        self.close_link();
    }
}

#[cfg(test)]
mod tests {
    //! Swift: `HostConnectionTests`, teardown ordering without a socket.
    use lain_link::{LinkTransport, memory_pair};
    use lain_platform::fake::FakePlatform;
    use lain_proto::{KeyEvent, ModifierFlags, MouseButton, PointerButton};

    use super::*;

    fn connection() -> (Arc<HostConnection<FakePlatform>>, FakePlatform) {
        let platform = FakePlatform::new();
        let channel = || MessageChannel::new(memory_pair().0, "test");
        let link = Link::new(
            [0; 16],
            channel(),
            channel(),
            channel(),
            LinkTransport::Usb,
            4,
            None,
            VersionList::offered().clone(),
        );
        let power = Arc::new(Power::new(platform.power.clone()));
        (HostConnection::new(link, Arc::new(platform.clone()), power, &HostConfig::default()), platform)
    }

    fn key(usage: u16) -> Message {
        Message::KeyEvent(KeyEvent {
            usage_page: KeyEvent::KEYBOARD_PAGE,
            usage,
            is_down: true,
            is_repeat: false,
            modifiers: ModifierFlags(0),
        })
    }

    #[tokio::test]
    async fn input_handled_after_finish_is_dropped() {
        let (connection, platform) = connection();
        assert!(connection.start());
        connection.handle(&key(0x04));
        let pressed = platform.input.actions();
        assert!(!pressed.is_empty());
        connection.finish();
        let released = platform.input.actions();
        assert!(released.len() > pressed.len(), "the key is released");
        // Buffered input drained after the release must not press anything again (invariant 4).
        connection.handle(&key(0x05));
        connection.handle(&Message::PointerButton(PointerButton {
            button: MouseButton::Left,
            is_down: true,
            click_count: 1,
            x: 1.0,
            y: 1.0,
            modifiers: ModifierFlags(0),
        }));
        assert_eq!(platform.input.actions(), released);
        assert_eq!(platform.power.transitions(), [true, false]);
        connection.finish();
        assert_eq!(platform.power.transitions(), [true, false], "idempotent");
    }

    #[tokio::test]
    async fn start_after_finish_takes_no_assertion() {
        let (connection, platform) = connection();
        connection.finish(); // a detach or stop raced the handshake
        assert!(!connection.start());
        assert!(platform.power.transitions().is_empty());
    }

    #[test]
    fn setup_items_map_to_the_wire() {
        let report = SetupReport {
            items: vec![
                (Requirement::StartAtLogin, RequirementState::Missing),
                (Requirement::ScreenCapture, RequirementState::Unknown),
            ],
            has_other_display: true,
        };
        let setup = host_setup(report, "why".into());
        assert_eq!(
            setup.items,
            [
                SetupItem { requirement: SetupRequirement::StartAtLogin, state: SetupState::Missing },
                SetupItem { requirement: SetupRequirement::ScreenRecording, state: SetupState::Unknown },
            ]
        );
        assert_eq!((setup.video_problem.as_str(), setup.has_other_display), ("why", true));
    }
}
