//! The message union, lowering to a version, decoding, and the stream parser. Swift: `Message.swift`.

use crate::io::{ByteReader, ByteWriter};
use crate::messages::*;
use crate::{FrameHeader, HANDSHAKE_VERSION, HEADER_SIZE, HeaderFlags, MessageType, ProtocolError, Result};

macro_rules! messages {
    ($($variant:ident($payload:ident)),+ $(,)?) => {
        /// Every message in §7.5 as one tagged union: the newest version's model (PROTOCOL-VERSIONING §3.3).
        /// Swift: `Message`.
        #[derive(Debug, Clone, PartialEq)]
        pub enum Message {
            $($variant($payload)),+
        }

        impl Message {
            /// The message's type.
            pub fn ty(&self) -> MessageType {
                match self {
                    $(Self::$variant(_) => <$payload as WireMessage>::TYPE),+
                }
            }

            /// Writes the payload (no header) at `w.version()`.
            pub fn encode_payload(&self, w: &mut ByteWriter) {
                match self {
                    $(Self::$variant(m) => m.encode(w)),+
                }
            }

            fn decode_payload(ty: MessageType, r: &mut ByteReader<'_>) -> Result<Self> {
                Ok(match ty {
                    $(MessageType::$variant => Self::$variant(<$payload as WireMessage>::decode(r)?)),+
                })
            }
        }

        $(
            impl From<$payload> for Message {
                fn from(m: $payload) -> Self {
                    Self::$variant(m)
                }
            }
        )+
    };
}

messages! {
    ChannelHello(ChannelHello),
    ChannelAccept(ChannelAccept),
    Hello(Hello),
    HelloAck(HelloAck),
    Ping(Ping),
    Pong(Pong),
    KeyframeRequest(KeyframeRequest),
    Error(ErrorMessage),
    Pair(Pair),
    DisplayLayout(DisplayLayout),
    HostSetup(HostSetup),
    VideoConfig(VideoConfig),
    VideoFrame(VideoFrame),
    FrameAck(FrameAck),
    CursorShape(CursorShape),
    CursorSelect(CursorSelect),
    CursorWarp(CursorWarp),
    KeyEvent(KeyEvent),
    PointerMove(PointerMove),
    PointerButton(PointerButton),
    Scroll(Scroll),
    Gesture(Gesture),
    ReleaseAll(ReleaseAll),
}

impl Message {
    /// Header flags implied by the payload: a keyframe `VideoFrame` sets [`HeaderFlags::KEYFRAME`]. The
    /// refinement flag is the sender's to add (it passes explicit flags).
    pub fn implied_flags(&self) -> HeaderFlags {
        match self {
            Self::VideoFrame(f) if f.is_keyframe => HeaderFlags::KEYFRAME,
            _ => HeaderFlags::EMPTY,
        }
    }

    /// Lifts a payload of `version` into the model: fields the version doesn't have get their defaults.
    /// The payload must be consumed exactly. A type that doesn't exist at `version` is `UnknownType`.
    pub fn decode(ty: MessageType, payload: &[u8], version: u8) -> Result<Self> {
        if !ty.exists_in(version) {
            return Err(ProtocolError::UnknownType(ty.raw()));
        }
        let mut r = ByteReader::new(payload, version);
        let m = Self::decode_payload(ty, &mut r)?;
        r.finish()?;
        Ok(m)
    }

    /// A guess at the payload's size, for the buffer.
    fn size_hint(&self) -> usize {
        64 + match self {
            Self::VideoFrame(f) => f.data.len(),
            Self::CursorShape(c) => c.pixels.len(),
            Self::VideoConfig(c) => c.parameter_sets.iter().map(|p| p.len() + 4).sum(),
            _ => 0,
        }
    }
}

/// A decoded message with its header. Swift: `Envelope`.
#[derive(Debug, Clone, PartialEq)]
pub struct Envelope {
    pub header: FrameHeader,
    pub message: Message,
}

/// A message written at one version (lower, PROTOCOL-VERSIONING §3.3). Swift: `Lowered`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Lowered {
    /// Everything the message holds exists at that version: the full frame.
    Exact(Vec<u8>),
    /// Advisory fields the version doesn't have were left out (named in `dropped`): the full frame.
    Projected { bytes: Vec<u8>, dropped: Vec<&'static str> },
    /// The message, or something it holds, doesn't exist at that version: not sendable there.
    Unrepresentable(String),
}

impl Lowered {
    /// The frame, unless unrepresentable.
    pub fn bytes(&self) -> Option<&[u8]> {
        match self {
            Self::Exact(b) | Self::Projected { bytes: b, .. } => Some(b),
            Self::Unrepresentable(_) => None,
        }
    }

    pub fn into_bytes(self) -> Option<Vec<u8>> {
        match self {
            Self::Exact(b) | Self::Projected { bytes: b, .. } => Some(b),
            Self::Unrepresentable(_) => None,
        }
    }
}

/// Framing whole messages. Swift: `MessageCodec`.
pub struct MessageCodec;

impl MessageCodec {
    /// Header + payload at `version` (a session version, or [`HANDSHAKE_VERSION`]), or why it can't be.
    /// `flags` `None`: [`Message::implied_flags`].
    ///
    /// # Panics
    /// If the payload is 4 GiB or longer (Swift traps too). Payloads over
    /// [`FrameHeader::MAX_PAYLOAD_LENGTH`] are written, as in Swift, and refused by the receiver.
    pub fn lower(
        message: &Message,
        version: u8,
        sequence: u32,
        timestamp_ns: u64,
        flags: Option<HeaderFlags>,
    ) -> Lowered {
        let ty = message.ty();
        if !ty.exists_in(version) {
            return Lowered::Unrepresentable(format!("{ty} doesn't exist in v{version}"));
        }
        // One buffer: the header's place, then the payload, then the header written into its place. Swift
        // writes the payload separately and copies it; the bytes are the same.
        let mut w = ByteWriter::with_capacity(HEADER_SIZE + message.size_hint(), version);
        w.raw(&[0; HEADER_SIZE]);
        message.encode_payload(&mut w);
        let (mut bytes, dropped, refused) = w.into_parts();
        if let Some(why) = refused {
            return Lowered::Unrepresentable(why);
        }
        let payload_length = u32::try_from(bytes.len() - HEADER_SIZE).expect("payload of 4 GiB or more");
        let header = FrameHeader {
            version,
            ty,
            flags: flags.unwrap_or_else(|| message.implied_flags()),
            sequence,
            timestamp_ns,
            payload_length,
        };
        bytes[..HEADER_SIZE].copy_from_slice(&header.to_bytes());
        if dropped.is_empty() { Lowered::Exact(bytes) } else { Lowered::Projected { bytes, dropped } }
    }

    /// Header + payload, ready to write. `version` `None`: the type's default
    /// ([`MessageType::default_version`]). Channels use [`lower`](Self::lower) instead.
    ///
    /// # Panics
    /// If the message isn't representable at that version (Swift: `preconditionFailure`).
    pub fn encode(
        message: &Message,
        sequence: u32,
        timestamp_ns: u64,
        flags: Option<HeaderFlags>,
        version: Option<u8>,
    ) -> Vec<u8> {
        let version = version.unwrap_or_else(|| message.ty().default_version());
        match Self::lower(message, version, sequence, timestamp_ns, flags) {
            Lowered::Exact(b) | Lowered::Projected { bytes: b, .. } => b,
            Lowered::Unrepresentable(why) => panic!("{why}"),
        }
    }

    /// `Error(versionMismatch)` framed in a legacy peer's own version `remote`, which it can parse (the
    /// `Error` payload is the same in every version), so a one-sided update says why (PROTOCOL-VERSIONING §7).
    pub fn legacy_version_mismatch(remote: u8, why: &str, sequence: u32, timestamp_ns: u64) -> Vec<u8> {
        let mut body = ByteWriter::new(HANDSHAKE_VERSION);
        ErrorMessage { code: ErrorCode::VERSION_MISMATCH, message: why.to_owned() }.encode(&mut body);
        let body = body.into_bytes();
        let header = FrameHeader {
            version: remote,
            ty: MessageType::Error,
            flags: HeaderFlags::EMPTY,
            sequence,
            timestamp_ns,
            payload_length: body.len() as u32,
        };
        let mut out = Vec::with_capacity(HEADER_SIZE + body.len());
        out.extend_from_slice(&header.to_bytes());
        out.extend_from_slice(&body);
        out
    }

    /// Decodes exactly one complete message, at the version its header names.
    pub fn decode(bytes: &[u8]) -> Result<Envelope> {
        let header = FrameHeader::decode(bytes)?;
        let payload = &bytes[HEADER_SIZE..];
        let declared = header.payload_length as usize;
        if payload.len() != declared {
            return Err(if payload.len() < declared {
                ProtocolError::Truncated
            } else {
                ProtocolError::Malformed("length mismatch".into())
            });
        }
        let message = Message::decode(header.ty, payload, header.version)?;
        Ok(Envelope { header, message })
    }
}

/// Reassembles messages from a byte stream (TCP delivers arbitrary chunks). Any error is fatal for the
/// connection: the stream can't be resynchronized. Swift: `FrameParser`.
#[derive(Debug, Default, Clone)]
pub struct FrameParser {
    buffer: Vec<u8>,
    start: usize,
}

impl FrameParser {
    /// Compact once this many consumed bytes sit at the front of the buffer.
    const COMPACT_AFTER: usize = 1 << 20;

    pub fn new() -> Self {
        Self::default()
    }

    /// Bytes received but not yet returned as messages.
    pub fn buffered_byte_count(&self) -> usize {
        self.buffer.len() - self.start
    }

    pub fn append(&mut self, bytes: &[u8]) {
        if self.start > 0 && self.start == self.buffer.len() {
            self.buffer.clear();
            self.start = 0;
        }
        self.buffer.extend_from_slice(bytes);
    }

    /// The next complete message, or `None` if more bytes are needed. The header is validated as soon as
    /// its 24 bytes are in, so an oversized length or a legacy version fails before the payload arrives.
    /// Swift's name; not an `Iterator`, since an error ends the stream rather than being one item of it.
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Result<Option<Envelope>> {
        if self.buffered_byte_count() < HEADER_SIZE {
            return Ok(None);
        }
        let header = FrameHeader::decode(&self.buffer[self.start..])?;
        let end = self.start + HEADER_SIZE + header.payload_length as usize;
        if self.buffer.len() < end {
            return Ok(None);
        }
        let message = Message::decode(header.ty, &self.buffer[self.start + HEADER_SIZE..end], header.version)?;
        self.start = end;
        if self.start > Self::COMPACT_AFTER {
            self.buffer.drain(..self.start);
            self.start = 0;
        }
        Ok(Some(Envelope { header, message }))
    }
}
