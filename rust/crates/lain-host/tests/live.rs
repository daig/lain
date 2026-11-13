//! The live session's video, cursor, setup and version skew, end to end over the fake usbmuxd (Swift's
//! behaviour in `LainLoopbackTests/{M3EndToEndTests,VersionSkewLoopbackTests}`; the fakes stand in for the
//! virtual display, capture and encode, so the frames are `lain-platform`'s non-decodable access units).

mod common;

use std::time::Duration;

use common::*;
use lain_host::{HostConfig, HostStatus, Tuning};
use lain_link::VersionGap;
use lain_platform::{Chroma, CursorImage, EncodeConfig, PlatformError, Requirement, RequirementState, SetupReport};
use lain_proto::*;

async fn video_message(link: &mut ClientLink) -> Option<Message> {
    within(T, link.video_received.recv()).await.flatten().map(|env| env.message)
}

#[tokio::test]
async fn video_and_cursor_flow_end_to_end() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    let session = rig.platform.video().last_session().expect("video started");
    // The encoder is asked for the client's display: HEVC 4:2:0 8-bit at 60 Mbps (L3), capped at its 120 Hz.
    assert_eq!(
        session.config(),
        EncodeConfig {
            width: 2752,
            height: 2064,
            frame_rate: 120,
            bitrate: 60_000_000,
            chroma: Chroma::Yuv420,
            bit_depth: 8
        }
    );
    assert_eq!(session.source().display_id, rig.platform.display.fake.created().unwrap().id);

    // A capture goes out as VideoConfig (the parameter sets) and a keyframe on the video connection.
    session.capture();
    let Some(Message::VideoConfig(config)) = video_message(&mut link).await else { panic!("no VideoConfig") };
    assert_eq!((config.width, config.height, config.chroma, config.bit_depth), (2752, 2064, ChromaFormat::Yuv420, 8));
    assert_eq!(config.parameter_sets.len(), 3);
    let Some(Message::VideoFrame(frame)) = video_message(&mut link).await else { panic!("no VideoFrame") };
    assert!(frame.is_keyframe);
    assert_eq!(frame.config_id, config.config_id);

    // Acked, the next capture is a P-frame.
    let ack = |frame_id| Message::FrameAck(FrameAck { frame_id, received_at_ns: 1, bytes: 1 });
    let _ = link.video.send(&ack(frame.frame_id));
    tokio::time::sleep(Duration::from_millis(20)).await;
    session.capture();
    let Some(Message::VideoFrame(next)) = video_message(&mut link).await else { panic!("no second frame") };
    assert!(!next.is_keyframe && next.frame_id > frame.frame_id);

    // A KeyframeRequest on realtime forces a keyframe, even on an idle desktop.
    let _ = link.video.send(&ack(next.frame_id));
    link.send(Message::KeyframeRequest(KeyframeRequest { reason: KeyframeReason::DecodeError, last_good_frame_id: 0 }));
    let keyframe = within(T, async {
        loop {
            match video_message(&mut link).await {
                Some(Message::VideoFrame(f)) if f.is_keyframe => return Some(f),
                Some(_) => {}
                None => return None,
            }
        }
    })
    .await
    .flatten();
    assert!(keyframe.is_some());
    assert!(rig.session.video_stats().is_some_and(|s| s.sent >= 3));

    // The cursor's shape goes on realtime, then its selection.
    rig.platform.fake.cursor.set(Some(CursorImage::new(1, 1, 2, 0.5, 0.5, vec![1, 2, 3, 4])));
    let Some(Message::CursorShape(shape)) = link.first(T, |m| matches!(m, Message::CursorShape(_))).await else {
        panic!("no CursorShape")
    };
    assert_eq!(
        (shape.pixel_width, shape.pixel_height, shape.scale, shape.pixels.as_slice()),
        (1, 1, 2, &[1, 2, 3, 4][..])
    );
    assert_eq!(
        link.next(T).await,
        Some(Message::CursorSelect(CursorSelect { shape_id: shape.shape_id, visible: true }))
    );
    rig.session.stop().await;
    assert!(session.is_stopped());
    assert_eq!(rig.platform.display.live(), 0);
}

#[tokio::test]
async fn capture_stopped_by_the_user_keeps_an_input_only_session() {
    let mut rig = Rig::new(RigOptions::default()).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    assert!(link.first(T, |m| matches!(m, Message::HostSetup(_))).await.is_some());
    rig.platform.video().last_session().unwrap().stop_by_user();
    assert!(eventually(T, || rig.platform.display.live() == 0).await);
    assert!(eventually(T, || rig.session.video_error().is_some()).await);
    // The client hears why there's no video (v4) and that the display went (in either order).
    let (mut layout, mut setup) = (None, None);
    while layout.is_none() || setup.is_none() {
        match link.next(T).await {
            Some(Message::DisplayLayout(l)) => layout = Some(l),
            Some(Message::HostSetup(s)) => setup = Some(s),
            Some(_) => {}
            None => panic!("layout {layout:?}, setup {setup:?}"),
        }
    }
    let layout = layout.unwrap();
    assert!(layout.displays.iter().all(|d| !d.is_streamed && d.display_id != 100), "{layout:?}");
    assert_eq!(
        setup,
        Some(HostSetup {
            items: vec![],
            video_problem: "capture stopped on the desktop".into(),
            has_other_display: false
        })
    );
    // Not restarted: the session goes on with the same link, no new display.
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(rig.platform.display.created(), 1);
    assert_eq!(rig.status(), HostStatus::connected_usb("iPad16,6"));
    assert!(rig.actions().is_empty());
    link.send(key(0x04, true));
    assert!(eventually(T, || !rig.actions().is_empty()).await);
    assert!(!link.closed(Duration::from_millis(50)).await);
    rig.session.stop().await;
}

#[tokio::test]
async fn recurring_capture_errors_back_off() {
    let config = HostConfig {
        tuning: Tuning { capture_retry_interval: Duration::from_millis(200), ..Tuning::default() },
        ..wifi_config()
    };
    let rig = Rig::new(RigOptions { config, ..Default::default() }).await;
    let video = rig.platform.video().clone();
    let failing = tokio::spawn(async move {
        let mut seen = 0;
        loop {
            let sessions = video.sessions();
            for s in sessions.iter().skip(seen) {
                let s = s.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    s.fail(PlatformError::Failed("broken".into()));
                });
            }
            seen = sessions.len();
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    });
    assert!(eventually(T, || rig.platform.display.created() >= 2).await, "the first one redials at once");
    tokio::time::sleep(Duration::from_millis(1000)).await;
    // Immediate, then 200, 400, 800 ms apart: a handful of sessions, not one every few ms.
    let created = rig.platform.display.created();
    assert!(created <= 6, "{created} sessions");
    failing.abort();
    rig.session.stop().await;
}

/// Capture (or the virtual display) failing at start leaves an input-only session on the primary monitor,
/// with the reason in the status and in `HostSetup`.
#[tokio::test]
async fn video_failure_leaves_an_input_only_session() {
    for display_fails in [true, false] {
        let mut rig = Rig::new(RigOptions::default()).await;
        // The failed start's display lingers in the monitor list a while, as a released one does.
        rig.platform.display.set_removal(Duration::from_millis(300));
        if display_fails {
            rig.platform.display.fake.fail_next_create(PlatformError::Unavailable("no compositor".into()));
        } else {
            rig.platform.video().fail_next_start(PlatformError::Denied("no screencast".into()));
        }
        let mut link = rig.usb.next_link(T).await.expect("a USB link");
        let ack = link.hello_ack().await.expect("HelloAck");
        // The primary monitor's size: nothing streams.
        assert_eq!((ack.display_point_width, ack.display_point_height), (1920, 1080));
        let Some(Message::DisplayLayout(layout)) = link.next(T).await else { panic!("no layout") };
        // Neither HelloAck nor the layout describes the display being torn down.
        assert_eq!(layout.displays.len(), 1, "{layout:?}");
        assert!(!layout.displays[0].is_streamed);
        let problem = if display_fails { "unavailable: no compositor" } else { "denied: no screencast" };
        let Some(Message::HostSetup(setup)) = link.next(T).await else { panic!("no HostSetup") };
        assert_eq!(setup.video_problem, problem);
        assert_eq!(rig.session.video_error().as_deref(), Some(problem));
        assert_eq!(rig.platform.display.live(), 0);
        assert!(rig.session.video_stats().is_none());
        assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
        link.send(Message::PointerMove(PointerMove { x: 10.0, y: 10.0, dx: 1.0, dy: 0.0, buttons: 0 }));
        assert!(eventually(T, || !rig.actions().is_empty()).await);
        rig.session.stop().await;
    }
}

// MARK: Version skew (Swift: `VersionSkewLoopbackTests`)

fn v4() -> VersionList {
    VersionList::supported().capped(Some(4))
}

fn both() -> VersionList {
    VersionList::supported().clone()
}

fn v5_only() -> VersionList {
    VersionList::new(VersionList::supported().entries().iter().copied().filter(|e| e.version == 5))
}

fn skew(client: VersionList, host: VersionList) -> RigOptions {
    RigOptions { client_versions: client, config: HostConfig { versions: host, ..wifi_config() }, ..Default::default() }
}

fn mac_setup(screen: RequirementState) -> SetupReport {
    SetupReport {
        items: vec![(Requirement::ScreenCapture, screen), (Requirement::InputInjection, RequirementState::Granted)],
        has_other_display: true,
    }
}

#[tokio::test]
async fn both_newest_the_ipad_hears_the_setup_and_its_changes() {
    let mut rig = Rig::new(skew(both(), both())).await;
    rig.platform.fake.setup.set(mac_setup(RequirementState::Missing));
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert_eq!(link.version, NEWEST_VERSION);
    assert!(link.hello_ack().await.is_some());
    let Some(Message::HostSetup(setup)) = link.first(T, |m| matches!(m, Message::HostSetup(_))).await else {
        panic!("no HostSetup")
    };
    assert_eq!(setup.missing(), [SetupRequirement::ScreenRecording]);
    assert!(setup.has_other_display);
    assert_eq!(rig.session.peer_version_note(), None);
    // The owner fixes it: the next check tells the iPad, and an unchanged one sends nothing.
    rig.platform.fake.setup.set(mac_setup(RequirementState::Granted));
    rig.session.setup_changed();
    rig.session.setup_changed();
    let Some(Message::HostSetup(setup)) = link.first(T, |m| matches!(m, Message::HostSetup(_))).await else {
        panic!("no second HostSetup")
    };
    assert!(setup.missing().is_empty());
    assert_eq!(link.first(Duration::from_millis(200), |m| matches!(m, Message::HostSetup(_))).await, None);
    rig.session.stop().await;
}

/// v5: `HostStats` every interval the iPad asks for (clamped to 100 ms at least), until it asks for 0.
#[tokio::test]
async fn the_ipad_asks_for_host_stats_and_stops_them() {
    let mut rig = Rig::new(skew(both(), both())).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert!(link.hello_ack().await.is_some());
    let is_stats = |m: &Message| matches!(m, Message::HostStats(_));
    assert_eq!(link.first(Duration::from_millis(200), is_stats).await, None, "none before the iPad asks");
    link.send(Message::StatsRequest(StatsRequest { interval_ms: 1 }));
    let started = std::time::Instant::now();
    for _ in 0..3 {
        assert!(link.first(T, is_stats).await.is_some());
    }
    assert!(started.elapsed() >= Duration::from_millis(190), "1 ms is clamped to 100: {:?}", started.elapsed());
    link.send(Message::StatsRequest(StatsRequest { interval_ms: 0 }));
    tokio::time::sleep(Duration::from_millis(150)).await;
    while link.first(Duration::from_millis(10), is_stats).await.is_some() {}
    assert_eq!(link.first(Duration::from_millis(300), is_stats).await, None, "stopped");
    rig.session.stop().await;
}

#[tokio::test]
async fn an_older_ipad_works_with_a_newer_host_which_says_what_updating_adds() {
    let mut rig = Rig::new(skew(v4(), both())).await;
    rig.platform.fake.setup.set(mac_setup(RequirementState::Missing));
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert_eq!(link.version, 4);
    assert!(link.hello_ack().await.is_some());
    assert!(rig.statuses.reaches(&HostStatus::connected_usb("iPad16,6"), T).await);
    // Input flows as in v4, and HostSetup (a v4 message) reaches it.
    link.send(key(0x04, true));
    assert!(eventually(T, || !rig.actions().is_empty()).await);
    assert!(link.first(T, |m| matches!(m, Message::HostSetup(_))).await.is_some());
    // The host's status says what updating adds.
    assert_eq!(
        rig.session.peer_version_note().as_deref(),
        Some(
            "lain on the iPad is older (protocol v4): update it for the host's video stats on the iPad, dictation \
             and the on-screen keyboard, the computer's sound on the iPad"
        )
    );
    rig.session.stop().await;
}

#[tokio::test]
async fn a_newer_ipad_works_with_an_older_host() {
    let mut rig = Rig::new(skew(both(), v4())).await;
    let mut link = rig.usb.next_link(T).await.expect("a USB link");
    assert_eq!(link.version, 4);
    assert!(link.hello_ack().await.is_some());
    assert!(link.first(T, |m| matches!(m, Message::HostSetup(_))).await.is_some());
    assert_eq!(link.first(Duration::from_millis(200), |m| matches!(m, Message::HostStats(_))).await, None);
    assert_eq!(rig.session.peer_version_note(), None, "from the host's side nothing is missing");
    rig.session.stop().await;
}

#[tokio::test]
async fn no_common_version_names_the_side_to_update() {
    let mut rig = Rig::new(skew(v5_only(), v4())).await;
    let gap = HostStatus::version_gap(&VersionGap::PeerNewer { peer: "protocol v5".into() }, &v4());
    assert!(rig.statuses.reaches(&gap, T).await);
    assert!(rig.status().title().contains("update lain on this computer"));
    assert!(rig.actions().is_empty());
    assert!(rig.usb.next_link(Duration::from_millis(100)).await.is_none());
    rig.session.stop().await;
}
