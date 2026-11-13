//! Message types, header flags and the 24-byte frame header. Swift: `FrameHeader.swift`.

use crate::io::ByteReader;
use crate::{HANDSHAKE_VERSION, HEADER_SIZE, MAGIC, NEWEST_VERSION, ProtocolError, Result, SUPPORTED_VERSIONS};

/// Message types (§7.5). Two layers (PROTOCOL-VERSIONING §3): the frozen handshake (`ChannelHello`,
/// `ChannelAccept`, `Pair`, and `Error` before a version is agreed), framed in header version 0xFF; and the
/// session messages, framed in the negotiated version. Reserved, never reuse: 0x03 `Start`, 0x04 `Stop`, 0x08
/// `Stats`, 0x09 `ConfigUpdate`, 0x0A `DisplayChanged`, 0x22 `VideoFragment`, 0x23 `VideoNack`, 0x60
/// `ProbeRequest`, 0x61 `ProbeAck`. Swift: `MessageType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[repr(u8)]
pub enum MessageType {
    ChannelHello = 0x00,
    Hello = 0x01,
    HelloAck = 0x02,
    Ping = 0x05,
    Pong = 0x06,
    KeyframeRequest = 0x07,
    Error = 0x0B,
    Pair = 0x0C,
    DisplayLayout = 0x0D,
    ChannelAccept = 0x0E,
    /// v4: the host's setup state (permissions, why there's no video).
    HostSetup = 0x0F,
    /// v5: the iPad asks for host stats.
    StatsRequest = 0x10,
    /// v5: the host's video stats, while the iPad asks.
    HostStats = 0x11,
    VideoConfig = 0x20,
    VideoFrame = 0x21,
    FrameAck = 0x24,
    /// v6: the host's sound format, on the audio channel.
    AudioConfig = 0x30,
    /// v6: a few milliseconds of the host's sound.
    AudioPacket = 0x31,
    CursorShape = 0x40,
    CursorSelect = 0x41,
    CursorWarp = 0x42,
    KeyEvent = 0x50,
    PointerMove = 0x51,
    PointerButton = 0x52,
    Scroll = 0x53,
    Gesture = 0x54,
    ReleaseAll = 0x55,
    /// v6: text for the host to type (dictation, the on-screen keyboard).
    TextInput = 0x56,
}

impl MessageType {
    /// Every type, in Swift's declaration order (`allCases`).
    pub const ALL: &'static [Self] = &[
        Self::ChannelHello,
        Self::Hello,
        Self::HelloAck,
        Self::Ping,
        Self::Pong,
        Self::KeyframeRequest,
        Self::Error,
        Self::Pair,
        Self::DisplayLayout,
        Self::ChannelAccept,
        Self::HostSetup,
        Self::StatsRequest,
        Self::HostStats,
        Self::VideoConfig,
        Self::VideoFrame,
        Self::FrameAck,
        Self::AudioConfig,
        Self::AudioPacket,
        Self::CursorShape,
        Self::CursorSelect,
        Self::CursorWarp,
        Self::KeyEvent,
        Self::PointerMove,
        Self::PointerButton,
        Self::Scroll,
        Self::Gesture,
        Self::ReleaseAll,
        Self::TextInput,
    ];

    pub const fn raw(self) -> u8 {
        self as u8
    }

    pub fn from_raw(raw: u8) -> Option<Self> {
        Self::ALL.iter().copied().find(|t| t.raw() == raw)
    }

    /// The Swift case name (`"\(type)"`): the golden-bytes keys and the text of errors.
    pub const fn name(self) -> &'static str {
        match self {
            Self::ChannelHello => "channelHello",
            Self::Hello => "hello",
            Self::HelloAck => "helloAck",
            Self::Ping => "ping",
            Self::Pong => "pong",
            Self::KeyframeRequest => "keyframeRequest",
            Self::Error => "error",
            Self::Pair => "pair",
            Self::DisplayLayout => "displayLayout",
            Self::ChannelAccept => "channelAccept",
            Self::HostSetup => "hostSetup",
            Self::StatsRequest => "statsRequest",
            Self::HostStats => "hostStats",
            Self::VideoConfig => "videoConfig",
            Self::VideoFrame => "videoFrame",
            Self::FrameAck => "frameAck",
            Self::AudioConfig => "audioConfig",
            Self::AudioPacket => "audioPacket",
            Self::CursorShape => "cursorShape",
            Self::CursorSelect => "cursorSelect",
            Self::CursorWarp => "cursorWarp",
            Self::KeyEvent => "keyEvent",
            Self::PointerMove => "pointerMove",
            Self::PointerButton => "pointerButton",
            Self::Scroll => "scroll",
            Self::Gesture => "gesture",
            Self::ReleaseAll => "releaseAll",
            Self::TextInput => "textInput",
        }
    }

    /// Sent in handshake frames (header version 0xFF). `Error` is both: a refusal before a version is
    /// agreed, and a session message after.
    pub const fn is_handshake(self) -> bool {
        matches!(self, Self::ChannelHello | Self::ChannelAccept | Self::Pair | Self::Error)
    }

    /// Sent in session frames, at the negotiated version.
    pub const fn is_session(self) -> bool {
        !matches!(self, Self::ChannelHello | Self::ChannelAccept | Self::Pair)
    }

    /// The first session version the message exists in.
    pub const fn since(self) -> u8 {
        match self {
            Self::HostSetup => 4,
            Self::StatsRequest | Self::HostStats => 5,
            Self::TextInput | Self::AudioConfig | Self::AudioPacket => 6,
            _ => 3,
        }
    }

    /// Whether the message can be framed in header version `version`.
    pub const fn exists_in(self, version: u8) -> bool {
        if version == HANDSHAKE_VERSION { self.is_handshake() } else { self.is_session() && self.since() <= version }
    }

    /// The version [`MessageCodec`](crate::MessageCodec) frames it in when none is given: handshake messages
    /// in 0xFF, session messages (`Error` too) in the newest version.
    pub const fn default_version(self) -> u8 {
        if self.is_session() { NEWEST_VERSION } else { HANDSHAKE_VERSION }
    }
}

impl std::fmt::Display for MessageType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

wire_flags! {
    /// Header flags. Swift: `HeaderFlags`.
    pub struct HeaderFlags(u16) {
        const KEYFRAME = 1 << 0;
        const FRAGMENT = 1 << 1;
        const RETRANSMIT = 1 << 2;
        const REFINEMENT = 1 << 3;
    }
}

/// The 24-byte little-endian header that starts every message (§7.4): magic u16, version u8, type u8,
/// flags u16, reserved u16 (zero), sequence u32, timestamp u64, payload length u32. Swift: `FrameHeader`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHeader {
    pub version: u8,
    pub ty: MessageType,
    pub flags: HeaderFlags,
    /// Per-channel sequence number.
    pub sequence: u32,
    /// The sender's monotonic clock in ns (Swift: `CLOCK_UPTIME_RAW`; here `CLOCK_MONOTONIC`).
    pub timestamp_ns: u64,
    pub payload_length: u32,
}

impl FrameHeader {
    pub const SIZE: usize = HEADER_SIZE;
    /// Upper bound on a single payload; a 2752×2064 keyframe is ~1.3 MB (§13).
    pub const MAX_PAYLOAD_LENGTH: u32 = 32 << 20;

    /// The header bytes.
    pub fn to_bytes(&self) -> [u8; HEADER_SIZE] {
        let mut b = [0u8; HEADER_SIZE];
        b[0..2].copy_from_slice(&MAGIC.to_le_bytes());
        b[2] = self.version;
        b[3] = self.ty.raw();
        b[4..6].copy_from_slice(&self.flags.0.to_le_bytes());
        // 6..8: reserved, zero
        b[8..12].copy_from_slice(&self.sequence.to_le_bytes());
        b[12..20].copy_from_slice(&self.timestamp_ns.to_le_bytes());
        b[20..24].copy_from_slice(&self.payload_length.to_le_bytes());
        b
    }

    /// Decodes and validates the header at the start of `bytes`. Checks, in order: length, magic, version,
    /// type, reserved, size. The version must be the handshake's or one this build implements; which one a
    /// channel accepts is the channel's business.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() < HEADER_SIZE {
            return Err(ProtocolError::Truncated);
        }
        let mut r = ByteReader::new(&bytes[..HEADER_SIZE], HANDSHAKE_VERSION);
        let magic = r.u16()?;
        if magic != MAGIC {
            return Err(ProtocolError::BadMagic(magic));
        }
        let version = r.u8()?;
        if version != HANDSHAKE_VERSION && !SUPPORTED_VERSIONS.contains(&version) {
            return Err(ProtocolError::VersionMismatch { remote: version });
        }
        let raw_type = r.u8()?;
        let ty = MessageType::from_raw(raw_type).ok_or(ProtocolError::UnknownType(raw_type))?;
        let flags = HeaderFlags(r.u16()?);
        if r.u16()? != 0 {
            return Err(ProtocolError::ReservedNonZero);
        }
        let sequence = r.u32()?;
        let timestamp_ns = r.u64()?;
        let payload_length = r.u32()?;
        if payload_length > Self::MAX_PAYLOAD_LENGTH {
            return Err(ProtocolError::PayloadTooLarge(payload_length));
        }
        Ok(Self { version, ty, flags, sequence, timestamp_ns, payload_length })
    }
}
