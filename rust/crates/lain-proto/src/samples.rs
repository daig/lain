//! Swift: `ProtocolSamples.swift`, ported field for field. The schema digests and the golden bytes depend on
//! every value and on the order, so nothing here changes: a new field gets a new value
//! (PROTOCOL-VERSIONING §6).

use std::sync::LazyLock;

use crate::messages::*;
use crate::{Message, VersionEntry, VersionList};

/// One representative value of every message type, with a non-default value in every field. Swift:
/// `ProtocolSamples`.
pub struct ProtocolSamples;

/// `Array(a..<b)` as a fixed-size array.
fn seq<const N: usize>(start: u8) -> [u8; N] {
    std::array::from_fn(|i| start + i as u8)
}

impl ProtocolSamples {
    /// A canonical host id, as `UUID().uuidString` writes it.
    pub const HOST_ID: &'static str = "0B5D5C4E-6A1F-4E53-9C2D-7F3A8E91B264";

    /// A version list with fixed digests (never [`VersionList::offered`]: its digests are made from these).
    pub fn versions() -> VersionList {
        VersionList::new([
            VersionEntry { version: 3, digest: seq(1) },  // Array(1...8)
            VersionEntry { version: 4, digest: seq(11) }, // Array(11...18)
        ])
    }

    /// The samples, in Swift's order.
    pub fn all() -> &'static [Message] {
        static ALL: LazyLock<Vec<Message>> = LazyLock::new(build);
        &ALL
    }
}

fn build() -> Vec<Message> {
    let host_id = ProtocolSamples::HOST_ID.to_owned();
    let versions = ProtocolSamples::versions();
    vec![
        Message::ChannelHello(ChannelHello {
            versions: versions.clone(),
            connection_kind: ConnectionKind::Video,
            session_token: seq(0),
            hmac: seq(100),
        }),
        Message::ChannelAccept(ChannelAccept { chosen: 4, versions }),
        Message::Hello(Hello {
            device_model: "iPad16,6 ✓".into(),
            pixel_width: 2752,
            pixel_height: 2064,
            scale: 2,
            max_refresh_rate: 120,
            decode_capabilities: DecodeCapabilities::HEVC_MAIN | DecodeCapabilities::HEVC_MAIN_444_10_HARDWARE,
            keyboard_type: KeyboardType::Iso,
        }),
        Message::HelloAck(HelloAck {
            codec: VideoCodec::Hevc,
            chroma: ChromaFormat::Yuv444,
            bit_depth: 10,
            display_mode: DisplayMode::Primary,
            bitrate: 60_000_000,
            refresh_rate: 120,
            display_point_width: 1376,
            display_point_height: 1032,
            audio_sample_rate: 48_000,
            audio_channels: 2,
            audio_encoding: AudioEncoding::Pcm16Le,
            double_click_interval_ms: 500,
            key_repeat_delay_ms: 225,
            key_repeat_interval_ms: 30,
            mac_input_source: "com.apple.keylayout.Colemak".into(),
            host_id: host_id.clone(),
            host_name: "Mac mini ✓".into(),
        }),
        Message::Ping(Ping { id: 7, sent_at_ns: 123_456_789_012 }),
        Message::Pong(Pong { id: 7, ping_sent_at_ns: 1, received_at_ns: u64::MAX - 1, sent_at_ns: u64::MAX }),
        Message::KeyframeRequest(KeyframeRequest { reason: KeyframeReason::DecodeError, last_good_frame_id: 41 }),
        Message::Error(ErrorMessage { code: ErrorCode::BUSY, message: "a USB session is live".into() }),
        Message::Pair(Pair { secret: seq(200), host_id }),
        Message::DisplayLayout(DisplayLayout {
            displays: vec![
                LayoutDisplay { display_id: 2, x: 0.0, y: 0.0, width: 1680.0, height: 1050.0, is_streamed: false },
                LayoutDisplay { display_id: 18, x: 0.0, y: 1050.0, width: 1376.0, height: 1032.0, is_streamed: true },
                LayoutDisplay { display_id: 3, x: -1920.0, y: 0.0, width: 1920.0, height: 1200.0, is_streamed: false },
            ],
        }),
        Message::HostSetup(HostSetup {
            items: vec![
                SetupItem { requirement: SetupRequirement::ScreenRecording, state: SetupState::Missing },
                SetupItem { requirement: SetupRequirement::Accessibility, state: SetupState::Granted },
                SetupItem { requirement: SetupRequirement::LocalNetwork, state: SetupState::Unknown },
                SetupItem { requirement: SetupRequirement::StartAtLogin, state: SetupState::Missing },
            ],
            video_problem: "Screen Recording is off ✓".into(),
            has_other_display: true,
        }),
        Message::StatsRequest(StatsRequest { interval_ms: 250 }),
        Message::HostStats(HostStats {
            encode_p50_us: 3_100,
            encode_p95_us: 5_400,
            ack_rtt_p50_us: 7_900,
            ack_rtt_p95_us: HostStats::NONE,
            captured: 7_200,
            encoded: 7_150,
            sent: 7_149,
            dropped_before_encode: 50,
            encode_failures: 1,
            keyframes: 3,
            refinements: 412,
            in_flight: 1,
            peak_in_flight: 2,
            bits_per_second: 48_000_000,
        }),
        Message::VideoConfig(VideoConfig {
            config_id: 3,
            codec: VideoCodec::Hevc,
            chroma: ChromaFormat::Yuv444,
            bit_depth: 10,
            width: 2752,
            height: 2064,
            full_range: true,
            color_primaries: 12,
            transfer_function: 13,
            matrix: 1,
            parameter_sets: vec![vec![0x40, 0x01], vec![0x42, 0x01, 0x01], vec![0x44, 0x01]],
        }),
        Message::VideoFrame(VideoFrame {
            frame_id: 99,
            config_id: 3,
            capture_time_ns: 10,
            encode_done_ns: 20,
            is_keyframe: true,
            data: vec![0, 0, 0, 3, 0x26, 0x01, 0xAF],
        }),
        Message::FrameAck(FrameAck { frame_id: 99, received_at_ns: 30, bytes: 1_200_000 }),
        Message::CursorShape(CursorShape {
            shape_id: 2,
            pixel_width: 2,
            pixel_height: 1,
            scale: 2,
            hotspot_x: 0.5,
            hotspot_y: 1.25,
            pixels: vec![1, 2, 3, 4, 5, 6, 7, 8],
        }),
        Message::CursorSelect(CursorSelect { shape_id: 2, visible: false }),
        Message::CursorWarp(CursorWarp { x: 688.5, y: -3.0 }),
        Message::KeyEvent(KeyEvent {
            usage_page: KeyEvent::KEYBOARD_PAGE,
            usage: 0x2B,
            is_down: true,
            is_repeat: true,
            modifiers: ModifierFlags::COMMAND | ModifierFlags::SHIFT,
        }),
        Message::PointerMove(PointerMove { x: 100.25, y: 1031.75, dx: -7.0, dy: 97.0, buttons: 0b01 }),
        Message::PointerButton(PointerButton {
            button: MouseButton::Right,
            is_down: true,
            click_count: 2,
            x: 1.0,
            y: 2.0,
            modifiers: ModifierFlags::CONTROL,
        }),
        Message::Scroll(Scroll {
            dx: 0.5,
            dy: -12.25,
            phase: GesturePhase::Ended,
            momentum_phase: MomentumPhase::Changed,
        }),
        Message::Gesture(Gesture { kind: GestureKind::Rotate, phase: GesturePhase::Changed, value: 0.125 }),
        Message::ReleaseAll(ReleaseAll { reason: ReleaseReason::PointerLockLost }),
        Message::AudioConfig(AudioConfig { sample_rate: 48_000, channels: 2, encoding: AudioEncoding::Pcm16Le }),
        Message::AudioPacket(AudioPacket {
            capture_time_ns: 123_456_789,
            samples: vec![0x01, 0x80, 0xFF, 0x7F, 0x00, 0x00, 0x34, 0x12],
        }),
        Message::TextInput(TextInput {
            text: "naïve café ✓\n\t{x}".into(),
            modifiers: ModifierFlags::CONTROL | ModifierFlags::OPTION,
        }),
    ]
}
