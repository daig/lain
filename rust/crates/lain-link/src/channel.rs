//! Framed messages over a [`ByteStream`]. Swift: `MessageChannel.swift`.

use std::fmt;
use std::sync::atomic::{AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use futures::Stream;
use lain_platform::clock;
use lain_proto::{
    Envelope, FrameHeader, FrameParser, HANDSHAKE_VERSION, HEADER_SIZE, HeaderFlags, Lowered, Message, MessageCodec,
    ProtocolError, VersionList,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc, watch};

use crate::stream::constant_time_eq;
use crate::{ByteStream, LinkTransport, SendError, TransportError};

/// How long a closing channel may still spend writing what was queued before it (and shutting the stream
/// down) before it gives up and drops the stream. Swift has no bound (a close waits behind blocked writes);
/// one is needed here so that no task outlives a close or drop by more than this.
pub const CLOSE_LINGER: Duration = Duration::from_secs(2);

/// How much a channel reads from its stream at once.
const READ_CHUNK: usize = 64 * 1024;

/// How many bytes of received frames (header and payload) a channel holds unread before it stops reading
/// its stream: one frame of the largest size the protocol allows. Past it the reader waits until
/// [`MessageChannel::recv`] takes messages, so the peer meets the stream's own backpressure (TCP's window,
/// usbmuxd's, a memory pipe's). Invisible on the wire.
///
/// Difference from Swift, whose `MessageChannel` buffers received messages without bound (`pending`): a
/// peer that hasn't authenticated yet (a video connection waiting for its realtime, an acceptor's
/// connection before delivery) could otherwise make this side hold any amount of memory.
pub const INBOUND_BUFFER: usize = HEADER_SIZE + FrameHeader::MAX_PAYLOAD_LENGTH as usize;

/// Why a channel closed: the first cause wins and is the one every observer sees. Swift reports a close as
/// `(any Error)?` to the close handler; this names each cause.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CloseReason {
    /// [`MessageChannel::close`], [`ChannelSender::close`], or the [`MessageChannel`] was dropped.
    Local,
    /// The peer closed its end (EOF).
    PeerClosed,
    /// Reading or writing failed.
    Io(String),
    /// Bytes that don't parse; the stream can't be resynchronized. `VersionMismatch` here is a legacy
    /// peer's frame (answered first, on an acceptor's channel).
    Malformed(ProtocolError),
    /// A frame in another layer's version than the channel's (PROTOCOL-VERSIONING §3.2), e.g. "a ping frame
    /// in v4 on a channel at v3".
    WrongVersion(String),
}

impl CloseReason {
    /// The close as Swift's close handler reports it: a legacy frame as `versionMismatch(remote:)`, a
    /// wrong-version frame as `unexpectedMessage`, an I/O failure as itself, anything else as a clean close
    /// ([`TransportError::Closed`] standing in for Swift's `nil`).
    pub fn error(&self) -> TransportError {
        match self {
            Self::Malformed(ProtocolError::VersionMismatch { remote }) => {
                TransportError::VersionMismatch { remote: *remote }
            }
            Self::WrongVersion(why) => TransportError::UnexpectedMessage(why.clone()),
            Self::Io(why) => TransportError::Io(why.clone()),
            Self::Local | Self::PeerClosed | Self::Malformed(_) => TransportError::Closed,
        }
    }

    /// What a receive reports once the channel is closed (Swift's `next`): a legacy peer's frame as
    /// `versionMismatch(remote:)`, anything else as `closed`.
    fn receive_error(&self) -> TransportError {
        match self {
            Self::Malformed(ProtocolError::VersionMismatch { remote }) => {
                TransportError::VersionMismatch { remote: *remote }
            }
            _ => TransportError::Closed,
        }
    }
}

impl fmt::Display for CloseReason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Local => f.write_str("closed here"),
            Self::PeerClosed => f.write_str("closed by the peer"),
            Self::Io(why) => write!(f, "i/o: {why}"),
            Self::Malformed(e) => write!(f, "{e}"),
            Self::WrongVersion(why) => f.write_str(why),
        }
    }
}

/// How a [`MessageChannel`] starts.
#[derive(Debug, Clone, Default)]
pub struct ChannelOptions {
    /// For logs.
    pub label: String,
    /// An acceptor's channel (§7.7 D29): a first frame in a version this build doesn't implement (a legacy
    /// peer's) is answered with `Error(versionMismatch)` framed in that version, which the peer can parse,
    /// before the channel closes. Swift: `answeringVersionMismatch`.
    pub answer_version_mismatch: bool,
    /// The session version, for a channel that skips the handshake (tests); `None` starts in the handshake
    /// layer.
    pub version: Option<u8>,
}

impl ChannelOptions {
    pub fn new(label: impl Into<String>) -> Self {
        Self { label: label.into(), ..Self::default() }
    }
}

enum Command {
    Frame(Vec<u8>),
    Close,
}

struct Outbox {
    next_sequence: u32,
    commands: mpsc::UnboundedSender<Command>,
}

struct Shared {
    label: String,
    /// The negotiated version; 0 while in the handshake layer (0 is never a version).
    version: AtomicU8,
    outbox: Mutex<Outbox>,
    reason: watch::Sender<Option<CloseReason>>,
    /// Framed bytes queued for the writer and not yet written to the stream.
    pending_bytes: AtomicUsize,
    transport: LinkTransport,
    pairing_secret: Option<Vec<u8>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Shared {
    fn version(&self) -> Option<u8> {
        match self.version.load(Ordering::Acquire) {
            0 => None,
            v => Some(v),
        }
    }

    fn reason(&self) -> Option<CloseReason> {
        self.reason.borrow().clone()
    }

    /// Records the first close cause and tells the writer, which sends what is queued and then shuts the
    /// stream down; the reader stops at once.
    fn close_with(&self, reason: CloseReason) {
        let outbox = lock(&self.outbox);
        let first = self.reason.send_if_modified(|current| {
            if current.is_some() {
                return false;
            }
            *current = Some(reason.clone());
            true
        });
        if first {
            match &reason {
                CloseReason::Local | CloseReason::PeerClosed => {
                    tracing::debug!(channel = %self.label, "closing: {reason}")
                }
                _ => tracing::error!(channel = %self.label, "closing: {reason}"),
            }
            let _ = outbox.commands.send(Command::Close);
        }
        drop(outbox);
    }

    /// Queues one frame, stamping its sequence number under the lock so that sequence order is send order.
    /// `bytes` is a full frame whose sequence field is overwritten.
    fn enqueue(&self, mut bytes: Vec<u8>) -> Result<(), SendError> {
        let mut outbox = lock(&self.outbox);
        if self.reason.borrow().is_some() {
            return Err(SendError::Closed);
        }
        let sequence = outbox.next_sequence;
        outbox.next_sequence = sequence.wrapping_add(1);
        bytes[8..12].copy_from_slice(&sequence.to_le_bytes());
        self.pending_bytes.fetch_add(bytes.len(), Ordering::AcqRel);
        outbox.commands.send(Command::Frame(bytes)).map_err(|_| SendError::Closed)
    }

    fn send(&self, message: &Message, flags: Option<HeaderFlags>) -> Result<(), SendError> {
        let version = self.version().unwrap_or(HANDSHAKE_VERSION);
        match MessageCodec::lower(message, version, 0, clock::now_ns(), flags) {
            Lowered::Exact(bytes) | Lowered::Projected { bytes, .. } => self.enqueue(bytes),
            Lowered::Unrepresentable(why) => {
                tracing::error!(channel = %self.label, "not sent: {why}");
                Err(SendError::Unrepresentable(why))
            }
        }
    }
}

/// Framed messages over a [`ByteStream`] (§7.4), with a reader task and a writer task. Swift:
/// `MessageChannel`.
///
/// Every channel starts in the handshake layer: it sends and accepts only handshake frames (header version
/// 0xFF) until [`set_version`](Self::set_version) fixes the version the link negotiated; from then on it
/// writes every message at that version and accepts only frames in it (PROTOCOL-VERSIONING §3.2). A frame in
/// any other version closes the channel. Each frame's version is checked when it is received
/// ([`recv`](Self::recv)), not when it is parsed, so a version set after reading one frame applies to the
/// next even if it already arrived.
///
/// Bytes that don't parse close the channel. A frame in a version this build doesn't implement (a legacy
/// peer's) closes it with [`TransportError::VersionMismatch`], so a one-sided update says why instead of just
/// dropping the link.
///
/// **Sending** ([`send`](Self::send), also through a cloneable [`ChannelSender`]) never blocks or awaits: it
/// frames the message, stamps the sequence number and [`lain_platform::clock::now_ns`], and queues it for
/// the writer task, in call order. Nothing below bounds that queue, as in Swift (whose socket send queue is
/// unbounded too); the video channel keeps it short the way Swift does: frames go out only within the
/// `FrameAck` window (at most a couple unacknowledged, `lain-media`), and `HostLink` makes the video
/// socket's kernel send buffer small ([`HostLink::VIDEO_SEND_BUFFER`](crate::HostLink::VIDEO_SEND_BUFFER),
/// §7.3), so a slow client's acks pace the frames instead of buffers piling up below the app.
/// [`pending_bytes`](Self::pending_bytes) tells how much is queued and not yet written, for a sender that
/// wants to look.
///
/// **Receiving**: messages are buffered until read (up to [`INBOUND_BUFFER`] bytes; then the channel stops
/// reading its stream, and so notices the peer's close only once some are read), with [`recv`](Self::recv),
/// [`recv_timeout`](Self::recv_timeout) (Swift: `next(timeoutSeconds:)`), or as a stream
/// ([`into_stream`](Self::into_stream); Swift: `setHandler`).
///
/// **Closing**: one [`CloseReason`] surfaces whatever the cause: [`close`](Self::close), dropping the
/// channel, the peer's EOF, an I/O failure or a protocol violation. A close sends what is already queued
/// first (within [`CLOSE_LINGER`]), as Swift's does. Messages received before the close can still be read.
///
/// Must be created inside a tokio runtime (it spawns its two tasks).
pub struct MessageChannel {
    shared: Arc<Shared>,
    /// Each message with its share of [`INBOUND_BUFFER`], given back when it is read.
    inbound: mpsc::UnboundedReceiver<(Envelope, OwnedSemaphorePermit)>,
    /// A frame in the wrong version was received: nothing more is delivered (Swift clears its buffer).
    violated: bool,
}

impl MessageChannel {
    /// A channel in the handshake layer that doesn't answer legacy frames: a dialer's.
    pub fn new(stream: impl ByteStream, label: impl Into<String>) -> Self {
        Self::with_options(stream, ChannelOptions::new(label))
    }

    pub fn with_options<S: ByteStream>(stream: S, options: ChannelOptions) -> Self {
        let transport = stream.link_transport();
        let pairing_secret = stream.pairing_secret().map(<[u8]>::to_vec);
        let (commands, command_rx) = mpsc::unbounded_channel();
        let (inbound_tx, inbound) = mpsc::unbounded_channel();
        let shared = Arc::new(Shared {
            label: options.label,
            version: AtomicU8::new(options.version.unwrap_or(0)),
            outbox: Mutex::new(Outbox { next_sequence: 0, commands }),
            reason: watch::Sender::new(None),
            pending_bytes: AtomicUsize::new(0),
            transport,
            pairing_secret,
        });
        let (read, write) = tokio::io::split(stream);
        let budget = Arc::new(Semaphore::new(INBOUND_BUFFER));
        tokio::spawn(read_loop(read, shared.clone(), inbound_tx, budget, options.answer_version_mismatch));
        tokio::spawn(write_loop(write, shared.clone(), command_rx));
        Self { shared, inbound, violated: false }
    }

    pub fn label(&self) -> &str {
        &self.shared.label
    }

    /// The negotiated version; `None` while in the handshake layer.
    pub fn version(&self) -> Option<u8> {
        self.shared.version()
    }

    /// Leaves the handshake layer: from now on messages go out, and must come in, at `version`. Call it
    /// before reading the first session message.
    ///
    /// # Panics
    /// If `version` is 0, which is never a version.
    pub fn set_version(&self, version: u8) {
        assert_ne!(version, 0, "0 is not a protocol version");
        self.shared.version.store(version, Ordering::Release);
    }

    /// Frames and queues a message at the channel's version (the handshake's until `set_version`). Never
    /// blocks or awaits. A message that doesn't exist at that version isn't sent
    /// ([`SendError::Unrepresentable`]): callers check the feature first (`Link::supports`), so that is a
    /// bug, logged.
    pub fn send(&self, message: &Message) -> Result<(), SendError> {
        self.shared.send(message, None)
    }

    /// [`send`](Self::send) with explicit header flags (`None`: those the message implies).
    pub fn send_with_flags(&self, message: &Message, flags: Option<HeaderFlags>) -> Result<(), SendError> {
        self.shared.send(message, flags)
    }

    /// A cloneable handle that sends on this channel (and can close it), for other tasks. It doesn't keep
    /// the channel open: dropping the `MessageChannel` closes it.
    pub fn sender(&self) -> ChannelSender {
        ChannelSender { shared: self.shared.clone() }
    }

    /// Closes after already-queued messages have been sent.
    pub fn close(&self) {
        self.shared.close_with(CloseReason::Local);
    }

    /// Why the channel closed; `None` while open.
    pub fn close_reason(&self) -> Option<CloseReason> {
        self.shared.reason()
    }

    /// Waits until the channel closes, and says why.
    pub async fn closed(&self) -> CloseReason {
        wait_closed(&self.shared).await
    }

    /// What the stream runs over (Swift: `LinkTransport(stream: channel.stream)`).
    pub fn link_transport(&self) -> &LinkTransport {
        &self.shared.transport
    }

    /// Whether `secret` is the pairing the stream's transport authenticated; true when it can't tell (USB).
    /// Constant-time. Swift: `(channel.stream as? PairingBoundStream)?.isBound(toSecret:) ?? true`.
    pub fn is_bound_to_secret(&self, secret: &[u8]) -> bool {
        self.shared.pairing_secret.as_deref().is_none_or(|bound| constant_time_eq(bound, secret))
    }

    /// Framed bytes queued and not yet written to the stream.
    pub fn pending_bytes(&self) -> usize {
        self.shared.pending_bytes.load(Ordering::Acquire)
    }

    /// The next message. Messages received before a close are still delivered; after them, a close caused
    /// by a legacy peer's frame is [`TransportError::VersionMismatch`] and any other is
    /// [`TransportError::Closed`] ([`close_reason`](Self::close_reason) says more). A frame in the wrong
    /// layer's version closes the channel ([`CloseReason::WrongVersion`]) and is `Closed` here, as in Swift.
    /// Cancel-safe.
    pub async fn recv(&mut self) -> Result<Envelope, TransportError> {
        if self.violated {
            return Err(TransportError::Closed);
        }
        match self.inbound.recv().await {
            Some((env, _unread)) => {
                let version = self.shared.version();
                let expected = version.unwrap_or(HANDSHAKE_VERSION);
                if env.header.version == expected {
                    return Ok(env);
                }
                let layer = version.map_or_else(|| "the handshake".to_owned(), |v| format!("v{v}"));
                let why = format!("a {} frame in v{} on a channel at {layer}", env.header.ty, env.header.version);
                self.violated = true;
                self.shared.close_with(CloseReason::WrongVersion(why));
                Err(TransportError::Closed)
            }
            None => Err(self.shared.reason().map_or(TransportError::Closed, |r| r.receive_error())),
        }
    }

    /// [`recv`](Self::recv) within `timeout`, else [`TransportError::Timeout`] (the channel stays open).
    /// Swift: `next(timeoutSeconds:)`.
    pub async fn recv_timeout(&mut self, timeout: Duration) -> Result<Envelope, TransportError> {
        tokio::time::timeout(timeout, self.recv()).await.unwrap_or(Err(TransportError::Timeout))
    }

    /// Every message from now on, as a stream that ends when the channel closes (keep a
    /// [`sender`](Self::sender) to learn why). Dropping the stream closes the channel. Swift: `setHandler`.
    pub fn into_stream(self) -> impl Stream<Item = Envelope> + Send + 'static {
        futures::stream::unfold(self, |mut channel| async move { channel.recv().await.ok().map(|env| (env, channel)) })
    }
}

impl Drop for MessageChannel {
    fn drop(&mut self) {
        self.shared.close_with(CloseReason::Local);
    }
}

impl fmt::Debug for MessageChannel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MessageChannel")
            .field("label", &self.shared.label)
            .field("version", &self.version())
            .field("closed", &self.close_reason())
            .finish()
    }
}

/// Sends on a [`MessageChannel`] from anywhere; cloneable. Doesn't keep the channel open. Swift's
/// `MessageChannel` is itself a shared reference; here the receiving end is owned and this is the shared
/// part.
#[derive(Clone)]
pub struct ChannelSender {
    shared: Arc<Shared>,
}

impl ChannelSender {
    /// [`MessageChannel::send`].
    pub fn send(&self, message: &Message) -> Result<(), SendError> {
        self.shared.send(message, None)
    }

    /// [`MessageChannel::send_with_flags`].
    pub fn send_with_flags(&self, message: &Message, flags: Option<HeaderFlags>) -> Result<(), SendError> {
        self.shared.send(message, flags)
    }

    pub fn version(&self) -> Option<u8> {
        self.shared.version()
    }

    pub fn close(&self) {
        self.shared.close_with(CloseReason::Local);
    }

    pub fn close_reason(&self) -> Option<CloseReason> {
        self.shared.reason()
    }

    pub async fn closed(&self) -> CloseReason {
        wait_closed(&self.shared).await
    }

    pub fn pending_bytes(&self) -> usize {
        self.shared.pending_bytes.load(Ordering::Acquire)
    }
}

impl fmt::Debug for ChannelSender {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ChannelSender").field("label", &self.shared.label).finish()
    }
}

async fn wait_closed(shared: &Shared) -> CloseReason {
    let mut rx = shared.reason.subscribe();
    // The sender lives in `shared`, which the caller holds, so this can't fail.
    let reason = rx.wait_for(Option::is_some).await.map(|r| r.clone()).ok().flatten();
    reason.unwrap_or(CloseReason::Local)
}

async fn read_loop<R: AsyncRead + Unpin>(
    mut read: R,
    shared: Arc<Shared>,
    inbound: mpsc::UnboundedSender<(Envelope, OwnedSemaphorePermit)>,
    budget: Arc<Semaphore>,
    answer_version_mismatch: bool,
) {
    let mut closing = shared.reason.subscribe();
    let mut parser = FrameParser::new();
    let mut parsed_any = false;
    let mut buf = vec![0u8; READ_CHUNK];
    loop {
        let n = tokio::select! {
            biased;
            _ = closing.wait_for(Option::is_some) => return,
            n = read.read(&mut buf) => n,
        };
        let n = match n {
            Ok(0) => return shared.close_with(CloseReason::PeerClosed),
            Ok(n) => n,
            Err(e) => return shared.close_with(CloseReason::Io(e.to_string())),
        };
        parser.append(&buf[..n]);
        loop {
            match parser.next() {
                Ok(Some(env)) => {
                    parsed_any = true;
                    // Waits, reading no further, while the unread messages fill INBOUND_BUFFER. A frame is at
                    // most INBOUND_BUFFER bytes (the parser refuses larger ones), so it always fits eventually.
                    let size = HEADER_SIZE + env.header.payload_length as usize;
                    let permit = tokio::select! {
                        biased;
                        _ = closing.wait_for(Option::is_some) => return,
                        permit = budget.clone().acquire_many_owned(size as u32) => permit,
                    };
                    let Ok(permit) = permit else { return }; // never closed
                    let _ = inbound.send((env, permit));
                }
                Ok(None) => break,
                Err(error) => {
                    if let ProtocolError::VersionMismatch { remote } = error
                        && answer_version_mismatch
                        && !parsed_any
                    {
                        let why = format!("lain here speaks protocol {}", VersionList::supported());
                        let answer = MessageCodec::legacy_version_mismatch(remote, &why, 0, clock::now_ns());
                        let _ = shared.enqueue(answer);
                    }
                    // After the answer: a close sends what is queued first.
                    return shared.close_with(CloseReason::Malformed(error));
                }
            }
        }
    }
}

async fn write_loop<W: AsyncWrite + Unpin>(
    mut write: W,
    shared: Arc<Shared>,
    mut commands: mpsc::UnboundedReceiver<Command>,
) {
    let mut closing = shared.reason.subscribe();
    // Fires CLOSE_LINGER after the channel starts closing: whatever is still being written is abandoned.
    let linger = async move {
        let _ = closing.wait_for(Option::is_some).await;
        tokio::time::sleep(CLOSE_LINGER).await;
    };
    tokio::pin!(linger);
    loop {
        let command = tokio::select! {
            biased;
            _ = &mut linger => return,
            command = commands.recv() => command,
        };
        let bytes = match command {
            Some(Command::Frame(bytes)) => bytes,
            Some(Command::Close) | None => break,
        };
        let written = tokio::select! {
            _ = &mut linger => return,
            r = write.write_all(&bytes) => r,
        };
        shared.pending_bytes.fetch_sub(bytes.len(), Ordering::AcqRel);
        if let Err(e) = written {
            shared.close_with(CloseReason::Io(e.to_string()));
            return;
        }
        if commands.is_empty() {
            let flushed = tokio::select! {
                _ = &mut linger => return,
                r = write.flush() => r,
            };
            if let Err(e) = flushed {
                shared.close_with(CloseReason::Io(e.to_string()));
                return;
            }
        }
    }
    tokio::select! {
        _ = &mut linger => {}
        _ = write.shutdown() => {}
    }
}
