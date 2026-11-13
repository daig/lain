//! Payloads for every message in §7.5, as explicit little-endian structs. Each type round-trips through
//! [`WireMessage::encode`] / [`WireMessage::decode`]; [`Message`](crate::Message) is the tagged union the
//! codec works with. Swift: `Messages.swift` and `ConnectionKind.swift`.
//!
//! Swift's nested types are flattened: `DisplayLayout.Display` is [`LayoutDisplay`], `HostSetup.Item` is
//! [`SetupItem`], `ErrorMessage.Code` is [`ErrorCode`], and so on; each says which it mirrors.

use crate::io::{ByteReader, ByteWriter};
use crate::{HANDSHAKE_VERSION, MessageType, ProtocolError, Result, VersionList};

/// One message payload. Swift: `WireMessage`.
pub trait WireMessage: Sized {
    const TYPE: MessageType;
    /// Writes the payload at `w.version()`.
    fn encode(&self, w: &mut ByteWriter);
    /// Reads the payload at `r.version()`, lifting fields the version doesn't have to their defaults. It
    /// doesn't check for trailing bytes: [`ByteReader::finish`] does.
    fn decode(r: &mut ByteReader<'_>) -> Result<Self>;
}

// MARK: - Shared value types

wire_enum! {
    /// The three connections of a session (§7.1); carried in `ChannelHello`. Swift: `ConnectionKind`.
    pub enum ConnectionKind: "ConnectionKind" {
        /// control + input + cursor
        Realtime = 0,
        /// video + frame acks
        Video = 1,
        Audio = 2,
    }
}

wire_enum! {
    /// Swift: `KeyboardType`.
    pub enum KeyboardType: "KeyboardType" { Unknown = 0, Ansi = 1, Iso = 2, Jis = 3 }
}

wire_enum! {
    /// Swift: `VideoCodec`.
    pub enum VideoCodec: "VideoCodec" { Hevc = 1 }
}

wire_enum! {
    /// Values match HEVC chroma_format_idc. Swift: `ChromaFormat`.
    pub enum ChromaFormat: "ChromaFormat" { Yuv420 = 1, Yuv444 = 3 }
}

wire_enum! {
    /// Swift: `DisplayMode`.
    pub enum DisplayMode: "DisplayMode" { Extend = 0, Primary = 1, CaptureExisting = 2 }
}

wire_enum! {
    /// Swift: `AudioEncoding`.
    pub enum AudioEncoding: "AudioEncoding" { Pcm16Le = 0 }
}

wire_flags! {
    /// Swift: `DecodeCapabilities`.
    pub struct DecodeCapabilities(u32) {
        const HEVC_MAIN = 1 << 0;
        /// Test-decoded at startup with hardware required (S3c).
        const HEVC_MAIN_444_10_HARDWARE = 1 << 1;
    }
}

wire_flags! {
    /// macOS-style modifier state carried with key and pointer events. Swift: `ModifierFlags`.
    pub struct ModifierFlags(u32) {
        const CAPS_LOCK = 1 << 0;
        const SHIFT = 1 << 1;
        const CONTROL = 1 << 2;
        const OPTION = 1 << 3;
        const COMMAND = 1 << 4;
        const FUNCTION = 1 << 5;
    }
}

wire_enum! {
    /// NSEvent-style scroll/gesture phase. Swift: `GesturePhase`.
    pub enum GesturePhase: "GesturePhase" { None = 0, MayBegin = 1, Began = 2, Changed = 3, Ended = 4, Cancelled = 5 }
}

wire_enum! {
    /// Scroll momentum phase, synthesized by the client (§6.4). Swift: `MomentumPhase`.
    pub enum MomentumPhase: "MomentumPhase" { None = 0, Began = 1, Changed = 2, Ended = 3 }
}

wire_enum! {
    /// Swift: `MouseButton`.
    pub enum MouseButton: "MouseButton" { Left = 0, Right = 1, Other = 2 }
}

// MARK: - Control

/// The first frame on every connection (handshake layer, frozen: PROTOCOL-VERSIONING §3.1). The dialer
/// offers its versions; the acceptor answers `ChannelAccept`. Swift: `ChannelHello`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelHello {
    /// The dialer's versions with their digests (Swift's default: `VersionList.offered`, here
    /// [`VersionList::offered`], passed explicitly).
    pub versions: VersionList,
    pub connection_kind: ConnectionKind,
    /// Random per session; ties the three connections together.
    pub session_token: [u8; ChannelHello::TOKEN_SIZE],
    /// HMAC-SHA256 over [`authenticated_bytes`](Self::authenticated_bytes), keyed by the pairing secret
    /// (computed in `lain-link`). All zeros requests pairing (§7.6); only the USB path accepts that.
    pub hmac: [u8; ChannelHello::MAC_SIZE],
}

impl ChannelHello {
    pub const TOKEN_SIZE: usize = 16;
    pub const MAC_SIZE: usize = 32;

    /// The bytes the HMAC covers: everything before it (version list, kind, token).
    pub fn authenticated_bytes(&self) -> Vec<u8> {
        let mut w = ByteWriter::new(HANDSHAKE_VERSION);
        w.version_list(&self.versions);
        w.u8(self.connection_kind.raw());
        w.raw(&self.session_token);
        w.into_bytes()
    }
}

impl WireMessage for ChannelHello {
    const TYPE: MessageType = MessageType::ChannelHello;
    fn encode(&self, w: &mut ByteWriter) {
        w.version_list(&self.versions);
        w.u8(self.connection_kind.raw());
        w.raw(&self.session_token);
        w.raw(&self.hmac);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self {
            versions: r.version_list()?,
            connection_kind: r.enum_value()?,
            session_token: r.raw_array()?,
            hmac: r.raw_array()?,
        })
    }
}

/// The acceptor's answer to an authenticated `ChannelHello`, on every connection (handshake layer, frozen:
/// PROTOCOL-VERSIONING §3.1): the version the session runs at, the highest common to both lists with equal
/// digests, or 0 when there is none (then the connection closes). Decoding rejects a choice outside the
/// acceptor's own list. Swift: `ChannelAccept`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelAccept {
    /// 0: no common version.
    pub chosen: u8,
    /// The acceptor's own versions.
    pub versions: VersionList,
}

impl WireMessage for ChannelAccept {
    const TYPE: MessageType = MessageType::ChannelAccept;
    fn encode(&self, w: &mut ByteWriter) {
        w.u8(self.chosen);
        w.version_list(&self.versions);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        let chosen = r.u8()?;
        let versions = r.version_list()?;
        if chosen != 0 && !versions.versions().contains(&chosen) {
            return Err(ProtocolError::Malformed(format!("chose v{chosen} outside its list")));
        }
        Ok(Self { chosen, versions })
    }
}

/// Swift: `Hello`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hello {
    pub device_model: String,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub scale: u8,
    pub max_refresh_rate: u16,
    pub decode_capabilities: DecodeCapabilities,
    pub keyboard_type: KeyboardType,
}

impl WireMessage for Hello {
    const TYPE: MessageType = MessageType::Hello;
    fn encode(&self, w: &mut ByteWriter) {
        w.string(&self.device_model);
        w.u32(self.pixel_width);
        w.u32(self.pixel_height);
        w.u8(self.scale);
        w.u16(self.max_refresh_rate);
        w.u32(self.decode_capabilities.0);
        w.u8(self.keyboard_type.raw());
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self {
            device_model: r.string()?,
            pixel_width: r.u32()?,
            pixel_height: r.u32()?,
            scale: r.u8()?,
            max_refresh_rate: r.u16()?,
            decode_capabilities: DecodeCapabilities(r.u32()?),
            keyboard_type: r.enum_value()?,
        })
    }
}

/// Swift: `HelloAck`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HelloAck {
    pub codec: VideoCodec,
    pub chroma: ChromaFormat,
    pub bit_depth: u8,
    pub display_mode: DisplayMode,
    pub bitrate: u32,
    pub refresh_rate: u16,
    /// The host display's size in points: the client's cursor space (§6.3).
    pub display_point_width: u32,
    pub display_point_height: u32,
    pub audio_sample_rate: u32,
    pub audio_channels: u8,
    pub audio_encoding: AudioEncoding,
    pub double_click_interval_ms: u32,
    pub key_repeat_delay_ms: u32,
    pub key_repeat_interval_ms: u32,
    /// The host's current keyboard input source (D18), e.g. "com.apple.keylayout.Colemak" (Swift:
    /// `macInputSource`).
    pub mac_input_source: String,
    /// The host's stable id, a canonical uppercase UUID (Bonjour TXT `id`, §7.7). Over USB the client stores
    /// the link's secret under `mac:<hostId>` for Wi-Fi; over Wi-Fi it must be the dialed id. Empty: unknown.
    pub host_id: String,
    /// The host's name, for the client's status.
    pub host_name: String,
}

impl WireMessage for HelloAck {
    const TYPE: MessageType = MessageType::HelloAck;
    fn encode(&self, w: &mut ByteWriter) {
        w.u8(self.codec.raw());
        w.u8(self.chroma.raw());
        w.u8(self.bit_depth);
        w.u8(self.display_mode.raw());
        w.u32(self.bitrate);
        w.u16(self.refresh_rate);
        w.u32(self.display_point_width);
        w.u32(self.display_point_height);
        w.u32(self.audio_sample_rate);
        w.u8(self.audio_channels);
        w.u8(self.audio_encoding.raw());
        w.u32(self.double_click_interval_ms);
        w.u32(self.key_repeat_delay_ms);
        w.u32(self.key_repeat_interval_ms);
        w.string(&self.mac_input_source);
        w.string(&self.host_id);
        w.string(&self.host_name);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self {
            codec: r.enum_value()?,
            chroma: r.enum_value()?,
            bit_depth: r.u8()?,
            display_mode: r.enum_value()?,
            bitrate: r.u32()?,
            refresh_rate: r.u16()?,
            display_point_width: r.u32()?,
            display_point_height: r.u32()?,
            audio_sample_rate: r.u32()?,
            audio_channels: r.u8()?,
            audio_encoding: r.enum_value()?,
            double_click_interval_ms: r.u32()?,
            key_repeat_delay_ms: r.u32()?,
            key_repeat_interval_ms: r.u32()?,
            mac_input_source: r.string()?,
            host_id: r.string()?,
            host_name: r.string()?,
        })
    }
}

/// NTP-style exchange for RTT and clock offset (§9): Ping carries t0. Swift: `Ping`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ping {
    pub id: u32,
    pub sent_at_ns: u64,
}

impl WireMessage for Ping {
    const TYPE: MessageType = MessageType::Ping;
    fn encode(&self, w: &mut ByteWriter) {
        w.u32(self.id);
        w.u64(self.sent_at_ns);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { id: r.u32()?, sent_at_ns: r.u64()? })
    }
}

/// Pong carries t0 plus the responder's t1/t2. Swift: `Pong`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pong {
    pub id: u32,
    /// t0: the Ping's sender time, echoed.
    pub ping_sent_at_ns: u64,
    /// t1: when the Ping arrived (responder clock).
    pub received_at_ns: u64,
    /// t2: when this Pong was sent (responder clock).
    pub sent_at_ns: u64,
}

impl WireMessage for Pong {
    const TYPE: MessageType = MessageType::Pong;
    fn encode(&self, w: &mut ByteWriter) {
        w.u32(self.id);
        w.u64(self.ping_sent_at_ns);
        w.u64(self.received_at_ns);
        w.u64(self.sent_at_ns);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { id: r.u32()?, ping_sent_at_ns: r.u64()?, received_at_ns: r.u64()?, sent_at_ns: r.u64()? })
    }
}

wire_enum! {
    /// Swift: `KeyframeRequest.Reason`.
    pub enum KeyframeReason: "Reason" { Startup = 0, DecodeError = 1, SequenceGap = 2, Resumed = 3 }
}

/// Swift: `KeyframeRequest`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyframeRequest {
    pub reason: KeyframeReason,
    /// Last frame the client decoded correctly (0 if none).
    pub last_good_frame_id: u32,
}

impl WireMessage for KeyframeRequest {
    const TYPE: MessageType = MessageType::KeyframeRequest;
    fn encode(&self, w: &mut ByteWriter) {
        w.u8(self.reason.raw());
        w.u32(self.last_good_frame_id);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { reason: r.enum_value()?, last_good_frame_id: r.u32()? })
    }
}

/// An `Error` code: any value travels, but only known ones are accepted in session frames. Swift:
/// `ErrorMessage.Code`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ErrorCode(pub u16);

impl ErrorCode {
    /// Answered only to a legacy peer (a version before negotiation), framed in its version.
    pub const VERSION_MISMATCH: Self = Self(1);
    pub const AUTHENTICATION_FAILED: Self = Self(2);
    // 3 (permissionMissing) and 4 (displayUnavailable) are reserved: defined in v1–v2, never sent.
    pub const INTERNAL: Self = Self(5);
    /// The host won't start this session now: another is live (e.g. over USB, which is preferred) or it is
    /// backing off. Retry later (§7.7).
    pub const BUSY: Self = Self(6);

    /// The Swift name of a known code.
    pub const fn name(self) -> Option<&'static str> {
        match self.0 {
            1 => Some("versionMismatch"),
            2 => Some("authenticationFailed"),
            5 => Some("internal"),
            6 => Some("busy"),
            _ => None,
        }
    }

    pub const fn is_known(self) -> bool {
        self.name().is_some()
    }
}

/// "busy", or "code 7" for an unknown code (as Swift describes it).
impl std::fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.name() {
            Some(name) => f.write_str(name),
            None => write!(f, "code {}", self.0),
        }
    }
}

/// A refusal or failure. In handshake frames (before a version is agreed) any code is accepted, so a newer
/// peer's reason still arrives; in session frames the code must be known (PROTOCOL-VERSIONING §3.1). Swift:
/// `ErrorMessage`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ErrorMessage {
    pub code: ErrorCode,
    pub message: String,
}

impl WireMessage for ErrorMessage {
    const TYPE: MessageType = MessageType::Error;
    fn encode(&self, w: &mut ByteWriter) {
        w.u16(self.code.0);
        w.string(&self.message);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        let code = ErrorCode(r.u16()?);
        if !code.is_known() && r.version() != HANDSHAKE_VERSION {
            return Err(ProtocolError::Malformed(format!("error code {}", code.0)));
        }
        Ok(Self { code, message: r.string()? })
    }
}

/// USB pairing (§7.6, D13): sent by the host on the realtime connection right after a pairing
/// `ChannelHello` (all-zero HMAC). The client stores the secret; its `Hello` confirms it. Swift: `Pair`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pair {
    pub secret: [u8; Pair::SECRET_SIZE],
    /// The host's id, as in `HelloAck`: the client stores the secret for USB and for Wi-Fi
    /// (`mac:<hostId>`) together, so a cable pull can't leave a stale Wi-Fi secret (§7.7). Empty: unknown.
    pub host_id: String,
}

impl Pair {
    pub const SECRET_SIZE: usize = 32;
}

impl WireMessage for Pair {
    const TYPE: MessageType = MessageType::Pair;
    fn encode(&self, w: &mut ByteWriter) {
        w.raw(&self.secret);
        w.string(&self.host_id);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { secret: r.raw_array()?, host_id: r.string()? })
    }
}

/// One display of a [`DisplayLayout`]. Swift: `DisplayLayout.Display`.
#[derive(Debug, Clone, PartialEq)]
pub struct LayoutDisplay {
    pub display_id: u32,
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    /// The display shown on the iPad (at most one).
    pub is_streamed: bool,
}

/// Every host display in global point coordinates (top-left origin, main display at 0,0), so the client's
/// cursor can roam the whole desktop while only the streamed display is shown (§5.1, §6.3). Sent after
/// `HelloAck` and whenever the arrangement changes. At most 255 displays are written. Swift: `DisplayLayout`.
#[derive(Debug, Clone, PartialEq)]
pub struct DisplayLayout {
    pub displays: Vec<LayoutDisplay>,
}

impl WireMessage for DisplayLayout {
    const TYPE: MessageType = MessageType::DisplayLayout;
    fn encode(&self, w: &mut ByteWriter) {
        let n = self.displays.len().min(255);
        w.u8(n as u8);
        for d in &self.displays[..n] {
            w.u32(d.display_id);
            w.f64(d.x);
            w.f64(d.y);
            w.f64(d.width);
            w.f64(d.height);
            w.bool(d.is_streamed);
        }
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        let n = usize::from(r.u8()?);
        if r.remaining() < n * 37 {
            return Err(ProtocolError::Truncated);
        }
        let mut displays = Vec::with_capacity(n);
        for _ in 0..n {
            displays.push(LayoutDisplay {
                display_id: r.u32()?,
                x: r.f64()?,
                y: r.f64()?,
                width: r.f64()?,
                height: r.f64()?,
                is_streamed: r.bool()?,
            });
        }
        Ok(Self { displays })
    }
}

wire_enum! {
    /// Swift: `HostSetup.Requirement` (Mac permissions; the Linux host sends only those that apply).
    pub enum SetupRequirement: "Requirement" { ScreenRecording = 0, Accessibility = 1, LocalNetwork = 2, StartAtLogin = 3 }
}

wire_enum! {
    /// Swift: `HostSetup.State`.
    pub enum SetupState: "State" {
        Granted = 0,
        Missing = 1,
        /// The host can't tell.
        Unknown = 2,
    }
}

/// Swift: `HostSetup.Item`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SetupItem {
    pub requirement: SetupRequirement,
    pub state: SetupState,
}

/// v4: the host's setup state, so the iPad can say what's missing and where to fix it. Sent after
/// `HelloAck` and whenever it changes, only to peers with [`ProtocolFeature::HostSetup`](crate::ProtocolFeature).
/// At most 255 items are written. Swift: `HostSetup`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostSetup {
    pub items: Vec<SetupItem>,
    /// Why the live session has no video, for the owner (empty: it has video, or it's starting).
    pub video_problem: String,
    /// The host has a display besides lain's, where its setup window shows.
    pub has_other_display: bool,
}

impl HostSetup {
    /// The state of `requirement`, if listed (the first item wins).
    pub fn state_of(&self, requirement: SetupRequirement) -> Option<SetupState> {
        self.items.iter().find(|i| i.requirement == requirement).map(|i| i.state)
    }

    /// The requirements listed as missing, in order.
    pub fn missing(&self) -> Vec<SetupRequirement> {
        self.items.iter().filter(|i| i.state == SetupState::Missing).map(|i| i.requirement).collect()
    }
}

impl WireMessage for HostSetup {
    const TYPE: MessageType = MessageType::HostSetup;
    fn encode(&self, w: &mut ByteWriter) {
        let n = self.items.len().min(255);
        w.u8(n as u8);
        for item in &self.items[..n] {
            w.u8(item.requirement.raw());
            w.u8(item.state.raw());
        }
        w.string(&self.video_problem);
        w.bool(self.has_other_display);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        let n = usize::from(r.u8()?);
        let mut items = Vec::with_capacity(n.min(r.remaining() / 2));
        for _ in 0..n {
            items.push(SetupItem { requirement: r.enum_value()?, state: r.enum_value()? });
        }
        Ok(Self { items, video_problem: r.string()?, has_other_display: r.bool()? })
    }
}

/// v5: the iPad asks for [`HostStats`] every `interval_ms` (0: stop), while it shows them. Only to peers with
/// [`ProtocolFeature::HostStats`](crate::ProtocolFeature). Swift: `StatsRequest`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StatsRequest {
    /// Clamped by the host to [`HostStats::INTERVAL_RANGE`]; 0 stops them.
    pub interval_ms: u32,
}

impl WireMessage for StatsRequest {
    const TYPE: MessageType = MessageType::StatsRequest;
    fn encode(&self, w: &mut ByteWriter) {
        w.u32(self.interval_ms);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { interval_ms: r.u32()? })
    }
}

/// v5: what only the host knows about the video path (encode times, frames held back before the encoder,
/// frames in flight), sent every [`StatsRequest::interval_ms`] while the iPad asks. Counters run from the start
/// of the session's video; a time not measured yet is [`HostStats::NONE`]. Swift: `HostStats`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostStats {
    /// Submit → encoded, in microseconds.
    pub encode_p50_us: u32,
    pub encode_p95_us: u32,
    /// Frame sent → `FrameAck` received, on the host's clock, in microseconds.
    pub ack_rtt_p50_us: u32,
    pub ack_rtt_p95_us: u32,
    pub captured: u32,
    pub encoded: u32,
    pub sent: u32,
    /// Replaced in the host's latest-wins slot before the encoder took them (backpressure).
    pub dropped_before_encode: u32,
    pub encode_failures: u32,
    pub keyframes: u32,
    pub refinements: u32,
    /// Sent and not yet acknowledged, now and at most.
    pub in_flight: u8,
    pub peak_in_flight: u8,
    /// Over the last second.
    pub bits_per_second: u32,
}

impl HostStats {
    /// A time not measured yet.
    pub const NONE: u32 = u32::MAX;
    /// The intervals the host honours, in milliseconds.
    pub const INTERVAL_RANGE: std::ops::RangeInclusive<u32> = 100..=5000;
}

impl Default for HostStats {
    fn default() -> Self {
        Self {
            encode_p50_us: Self::NONE,
            encode_p95_us: Self::NONE,
            ack_rtt_p50_us: Self::NONE,
            ack_rtt_p95_us: Self::NONE,
            captured: 0,
            encoded: 0,
            sent: 0,
            dropped_before_encode: 0,
            encode_failures: 0,
            keyframes: 0,
            refinements: 0,
            in_flight: 0,
            peak_in_flight: 0,
            bits_per_second: 0,
        }
    }
}

impl WireMessage for HostStats {
    const TYPE: MessageType = MessageType::HostStats;
    fn encode(&self, w: &mut ByteWriter) {
        for v in [
            self.encode_p50_us,
            self.encode_p95_us,
            self.ack_rtt_p50_us,
            self.ack_rtt_p95_us,
            self.captured,
            self.encoded,
            self.sent,
            self.dropped_before_encode,
            self.encode_failures,
            self.keyframes,
            self.refinements,
        ] {
            w.u32(v);
        }
        w.u8(self.in_flight);
        w.u8(self.peak_in_flight);
        w.u32(self.bits_per_second);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self {
            encode_p50_us: r.u32()?,
            encode_p95_us: r.u32()?,
            ack_rtt_p50_us: r.u32()?,
            ack_rtt_p95_us: r.u32()?,
            captured: r.u32()?,
            encoded: r.u32()?,
            sent: r.u32()?,
            dropped_before_encode: r.u32()?,
            encode_failures: r.u32()?,
            keyframes: r.u32()?,
            refinements: r.u32()?,
            in_flight: r.u8()?,
            peak_in_flight: r.u8()?,
            bits_per_second: r.u32()?,
        })
    }
}

// MARK: - Video

/// Colour tags use ITU-T H.273 code points (P3-D65 primaries = 12, sRGB transfer = 13, BT.709 matrix = 1).
/// Swift: `VideoConfig`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VideoConfig {
    pub config_id: u32,
    pub codec: VideoCodec,
    pub chroma: ChromaFormat,
    pub bit_depth: u8,
    pub width: u32,
    pub height: u32,
    pub full_range: bool,
    pub color_primaries: u8,
    pub transfer_function: u8,
    pub matrix: u8,
    /// VPS, SPS, PPS without start codes. At most 255 are written: where Swift traps on more, this writes
    /// the first 255.
    pub parameter_sets: Vec<Vec<u8>>,
}

impl WireMessage for VideoConfig {
    const TYPE: MessageType = MessageType::VideoConfig;
    fn encode(&self, w: &mut ByteWriter) {
        w.u32(self.config_id);
        w.u8(self.codec.raw());
        w.u8(self.chroma.raw());
        w.u8(self.bit_depth);
        w.u32(self.width);
        w.u32(self.height);
        w.bool(self.full_range);
        w.u8(self.color_primaries);
        w.u8(self.transfer_function);
        w.u8(self.matrix);
        // Intended difference: Swift's `UInt8(parameterSets.count)` traps above 255.
        let n = self.parameter_sets.len().min(255);
        w.u8(n as u8);
        for ps in &self.parameter_sets[..n] {
            w.blob(ps);
        }
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        let config_id = r.u32()?;
        let codec = r.enum_value()?;
        let chroma = r.enum_value()?;
        let bit_depth = r.u8()?;
        let width = r.u32()?;
        let height = r.u32()?;
        let full_range = r.bool()?;
        let color_primaries = r.u8()?;
        let transfer_function = r.u8()?;
        let matrix = r.u8()?;
        let n = usize::from(r.u8()?);
        let mut parameter_sets = Vec::with_capacity(n.min(r.remaining() / 4));
        for _ in 0..n {
            parameter_sets.push(r.blob()?);
        }
        Ok(Self {
            config_id,
            codec,
            chroma,
            bit_depth,
            width,
            height,
            full_range,
            color_primaries,
            transfer_function,
            matrix,
            parameter_sets,
        })
    }
}

/// One encoded frame: 4-byte big-endian length-prefixed NAL units, exactly as VideoToolbox emits them.
/// Keyframe and refinement are also header flags ([`Message::implied_flags`](crate::Message::implied_flags)).
/// Swift: `VideoFrame`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VideoFrame {
    pub frame_id: u32,
    pub config_id: u32,
    pub capture_time_ns: u64,
    pub encode_done_ns: u64,
    pub is_keyframe: bool,
    pub data: Vec<u8>,
}

impl WireMessage for VideoFrame {
    const TYPE: MessageType = MessageType::VideoFrame;
    fn encode(&self, w: &mut ByteWriter) {
        w.u32(self.frame_id);
        w.u32(self.config_id);
        w.u64(self.capture_time_ns);
        w.u64(self.encode_done_ns);
        w.bool(self.is_keyframe);
        w.blob(&self.data);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self {
            frame_id: r.u32()?,
            config_id: r.u32()?,
            capture_time_ns: r.u64()?,
            encode_done_ns: r.u64()?,
            is_keyframe: r.bool()?,
            data: r.blob()?,
        })
    }
}

/// Sent as soon as a frame has fully arrived; drives backpressure (§7.3). Swift: `FrameAck`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrameAck {
    pub frame_id: u32,
    pub received_at_ns: u64,
    pub bytes: u32,
}

impl WireMessage for FrameAck {
    const TYPE: MessageType = MessageType::FrameAck;
    fn encode(&self, w: &mut ByteWriter) {
        w.u32(self.frame_id);
        w.u64(self.received_at_ns);
        w.u32(self.bytes);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { frame_id: r.u32()?, received_at_ns: r.u64()?, bytes: r.u32()? })
    }
}

// MARK: - Cursor (H→C)

/// Sent once per unique shape (§5.4). Pixels are premultiplied BGRA, rows packed; decoding requires
/// `pixels.len() == width * height * 4`. Swift: `CursorShape`.
#[derive(Debug, Clone, PartialEq)]
pub struct CursorShape {
    pub shape_id: u32,
    pub pixel_width: u16,
    pub pixel_height: u16,
    pub scale: u8,
    /// Hotspot in points from the top-left.
    pub hotspot_x: f32,
    pub hotspot_y: f32,
    pub pixels: Vec<u8>,
}

impl CursorShape {
    /// The host keeps at most this many shapes live. When it needs another it forgets them all and resends
    /// each shape when next used, under new ids that are higher than every earlier one, so a client that
    /// keeps this many and evicts the lowest id always holds every live shape.
    pub const MAX_LIVE: usize = 64;
}

impl WireMessage for CursorShape {
    const TYPE: MessageType = MessageType::CursorShape;
    fn encode(&self, w: &mut ByteWriter) {
        w.u32(self.shape_id);
        w.u16(self.pixel_width);
        w.u16(self.pixel_height);
        w.u8(self.scale);
        w.f32(self.hotspot_x);
        w.f32(self.hotspot_y);
        w.blob(&self.pixels);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        let m = Self {
            shape_id: r.u32()?,
            pixel_width: r.u16()?,
            pixel_height: r.u16()?,
            scale: r.u8()?,
            hotspot_x: r.f32()?,
            hotspot_y: r.f32()?,
            pixels: r.blob()?,
        };
        if m.pixels.len() != usize::from(m.pixel_width) * usize::from(m.pixel_height) * 4 {
            return Err(ProtocolError::Malformed("cursor pixel count".into()));
        }
        Ok(m)
    }
}

/// Swift: `CursorSelect`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorSelect {
    pub shape_id: u32,
    pub visible: bool,
}

impl WireMessage for CursorSelect {
    const TYPE: MessageType = MessageType::CursorSelect;
    fn encode(&self, w: &mut ByteWriter) {
        w.u32(self.shape_id);
        w.bool(self.visible);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { shape_id: r.u32()?, visible: r.bool()? })
    }
}

/// The host moved the cursor itself; overwrite the client's position (points). Swift: `CursorWarp`.
#[derive(Debug, Clone, PartialEq)]
pub struct CursorWarp {
    pub x: f64,
    pub y: f64,
}

impl WireMessage for CursorWarp {
    const TYPE: MessageType = MessageType::CursorWarp;
    fn encode(&self, w: &mut ByteWriter) {
        w.f64(self.x);
        w.f64(self.y);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { x: r.f64()?, y: r.f64()? })
    }
}

// MARK: - Audio (H→C, the audio channel)

/// v6: the format of the [`AudioPacket`]s that follow, sent before the first and again if it changes. Only to
/// peers with [`ProtocolFeature::Audio`](crate::ProtocolFeature). Swift: `AudioConfig`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AudioConfig {
    pub sample_rate: u32,
    pub channels: u8,
    pub encoding: AudioEncoding,
}

impl WireMessage for AudioConfig {
    const TYPE: MessageType = MessageType::AudioConfig;
    fn encode(&self, w: &mut ByteWriter) {
        w.u32(self.sample_rate);
        w.u8(self.channels);
        w.u8(self.encoding.raw());
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { sample_rate: r.u32()?, channels: r.u8()?, encoding: r.enum_value()? })
    }
}

/// v6: a few milliseconds of the host's sound in the last [`AudioConfig`]'s format (interleaved), sent as it is
/// captured. Uncompressed: no codec delay, and small next to the video. Swift: `AudioPacket`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioPacket {
    /// When the host captured the first sample (its monotonic clock, ns; Swift: `CLOCK_UPTIME_RAW`).
    pub capture_time_ns: u64,
    pub samples: Vec<u8>,
}

impl WireMessage for AudioPacket {
    const TYPE: MessageType = MessageType::AudioPacket;
    fn encode(&self, w: &mut ByteWriter) {
        w.u64(self.capture_time_ns);
        w.blob(&self.samples);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { capture_time_ns: r.u64()?, samples: r.blob()? })
    }
}

// MARK: - Input (C→H)

/// A physical key (D18): HID usage page + usage. Swift: `KeyEvent`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyEvent {
    /// [`KeyEvent::KEYBOARD_PAGE`] for keyboard keys (Swift's default).
    pub usage_page: u16,
    pub usage: u16,
    pub is_down: bool,
    pub is_repeat: bool,
    /// Modifier state after this event, including any remap (§6.4).
    pub modifiers: ModifierFlags,
}

impl KeyEvent {
    /// HID usage page 7, Keyboard/Keypad.
    pub const KEYBOARD_PAGE: u16 = 0x07;
}

impl WireMessage for KeyEvent {
    const TYPE: MessageType = MessageType::KeyEvent;
    fn encode(&self, w: &mut ByteWriter) {
        w.u16(self.usage_page);
        w.u16(self.usage);
        w.bool(self.is_down);
        w.bool(self.is_repeat);
        w.u32(self.modifiers.0);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self {
            usage_page: r.u16()?,
            usage: r.u16()?,
            is_down: r.bool()?,
            is_repeat: r.bool()?,
            modifiers: ModifierFlags(r.u32()?),
        })
    }
}

/// Absolute position (points, client-authoritative) plus the raw delta (§6.3). Swift: `PointerMove`.
#[derive(Debug, Clone, PartialEq)]
pub struct PointerMove {
    pub x: f64,
    pub y: f64,
    pub dx: f32,
    pub dy: f32,
    /// Bit n set: [`MouseButton`] with raw value n held.
    pub buttons: u8,
}

impl WireMessage for PointerMove {
    const TYPE: MessageType = MessageType::PointerMove;
    fn encode(&self, w: &mut ByteWriter) {
        w.f64(self.x);
        w.f64(self.y);
        w.f32(self.dx);
        w.f32(self.dy);
        w.u8(self.buttons);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { x: r.f64()?, y: r.f64()?, dx: r.f32()?, dy: r.f32()?, buttons: r.u8()? })
    }
}

/// Swift: `PointerButton`.
#[derive(Debug, Clone, PartialEq)]
pub struct PointerButton {
    pub button: MouseButton,
    pub is_down: bool,
    /// Computed by the client with the host's double-click interval (§5.5).
    pub click_count: u8,
    pub x: f64,
    pub y: f64,
    pub modifiers: ModifierFlags,
}

impl WireMessage for PointerButton {
    const TYPE: MessageType = MessageType::PointerButton;
    fn encode(&self, w: &mut ByteWriter) {
        w.u8(self.button.raw());
        w.bool(self.is_down);
        w.u8(self.click_count);
        w.f64(self.x);
        w.f64(self.y);
        w.u32(self.modifiers.0);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self {
            button: r.enum_value()?,
            is_down: r.bool()?,
            click_count: r.u8()?,
            x: r.f64()?,
            y: r.f64()?,
            modifiers: ModifierFlags(r.u32()?),
        })
    }
}

/// Continuous pixel scroll with phases; momentum is synthesized by the client (§5.5, §6.4). Swift: `Scroll`.
#[derive(Debug, Clone, PartialEq)]
pub struct Scroll {
    pub dx: f32,
    pub dy: f32,
    pub phase: GesturePhase,
    pub momentum_phase: MomentumPhase,
}

impl WireMessage for Scroll {
    const TYPE: MessageType = MessageType::Scroll;
    fn encode(&self, w: &mut ByteWriter) {
        w.f32(self.dx);
        w.f32(self.dy);
        w.u8(self.phase.raw());
        w.u8(self.momentum_phase.raw());
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { dx: r.f32()?, dy: r.f32()?, phase: r.enum_value()?, momentum_phase: r.enum_value()? })
    }
}

wire_enum! {
    /// Swift: `Gesture.Kind`.
    pub enum GestureKind: "Kind" { Magnify = 0, Rotate = 1 }
}

/// Swift: `Gesture`.
#[derive(Debug, Clone, PartialEq)]
pub struct Gesture {
    pub kind: GestureKind,
    pub phase: GesturePhase,
    /// Magnify: scale delta; rotate: radians delta.
    pub value: f32,
}

impl WireMessage for Gesture {
    const TYPE: MessageType = MessageType::Gesture;
    fn encode(&self, w: &mut ByteWriter) {
        w.u8(self.kind.raw());
        w.u8(self.phase.raw());
        w.f32(self.value);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { kind: r.enum_value()?, phase: r.enum_value()?, value: r.f32()? })
    }
}

wire_enum! {
    /// Swift: `ReleaseAll.Reason`.
    pub enum ReleaseReason: "Reason" { FocusLost = 0, PointerLockLost = 1, Disconnect = 2, TransportSwitch = 3 }
}

/// Invariant 4: release every held key and button. Swift: `ReleaseAll`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReleaseAll {
    pub reason: ReleaseReason,
}

impl WireMessage for ReleaseAll {
    const TYPE: MessageType = MessageType::ReleaseAll;
    fn encode(&self, w: &mut ByteWriter) {
        w.u8(self.reason.raw());
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { reason: r.enum_value()? })
    }
}

/// v6: text for the host to type as if on its keyboard, whatever its layout: what was dictated, or typed on the
/// iPad's on-screen keyboard. A line feed is Return and a tab is Tab. With `modifiers`, each character is instead
/// the key that types it in the host's layout, pressed with those modifiers held (Control-C). Only from peers
/// with [`ProtocolFeature::TextInput`](crate::ProtocolFeature); long text comes in several messages
/// ([`TextInput::MAX_LENGTH`] characters each). Swift: `TextInput`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TextInput {
    pub text: String,
    /// Held while the text is typed; empty for plain text.
    pub modifiers: ModifierFlags,
}

impl TextInput {
    /// The most characters (Swift `Character`s: grapheme clusters) one message carries; the sender splits.
    pub const MAX_LENGTH: usize = 1_000;
}

impl WireMessage for TextInput {
    const TYPE: MessageType = MessageType::TextInput;
    fn encode(&self, w: &mut ByteWriter) {
        w.string(&self.text);
        w.u32(self.modifiers.0);
    }
    fn decode(r: &mut ByteReader<'_>) -> Result<Self> {
        Ok(Self { text: r.string()?, modifiers: ModifierFlags(r.u32()?) })
    }
}
