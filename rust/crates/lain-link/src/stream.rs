//! What a channel runs over, and how streams are dialed. Swift: `ByteStream.swift`, `MemoryStream.swift`,
//! `PairingBoundStream` and `LinkTransport` (`Security.swift`, `Link.swift`, `NetworkStream.swift`).

use std::future::Future;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};

use lain_proto::ConnectionKind;
use tokio::io::{AsyncRead, AsyncWrite, DuplexStream, ReadBuf};
use tokio::sync::mpsc;

use crate::{DialError, TransportError};

/// What a link runs over, read from its realtime connection (§7.7): USB through usbmuxd (§7.2), or a
/// network path with its interface (`None` if unknown) and whether it is peer-to-peer. Swift:
/// `LinkTransport`. Linux has no AWDL, so `peer_to_peer` is false for every path the Linux host makes; the
/// case is kept so the type means what Swift's does.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub enum LinkTransport {
    #[default]
    Usb,
    Network {
        interface: Option<String>,
        peer_to_peer: bool,
    },
}

/// A reliable, ordered byte pipe a [`MessageChannel`](crate::MessageChannel) runs over: a usbmuxd pipe
/// (`tokio::net::UnixStream`), TCP, TLS (wrapped in [`BoundStream`]), or memory (`DuplexStream`).
/// Swift: `ByteStream`, with `PairingBoundStream.isBound(toSecret:)` and `LinkTransport(stream:)` folded in
/// as provided methods.
///
/// Difference from Swift: Swift's `ByteStream` is callback-based (`start`/`write`/`close`); here a stream
/// is any tokio `AsyncRead + AsyncWrite`, and the channel owns the reading and writing (one task each).
pub trait ByteStream: AsyncRead + AsyncWrite + Unpin + Send + 'static {
    /// The pairing secret the transport authenticated (Wi-Fi TLS-PSK, §7.7 D29); `None` when the transport
    /// can't tell, as for USB, whose `ChannelHello` HMAC under a stored secret then decides alone.
    ///
    /// Swift: `PairingBoundStream.isBound(toSecret:)`. Difference: the stream gives the secret rather than
    /// answering for one, because a channel hands its stream to its reader and writer tasks at once and so
    /// captures this at construction; [`MessageChannel::is_bound_to_secret`](crate::MessageChannel::is_bound_to_secret)
    /// then answers Swift's question, comparing in constant time.
    fn pairing_secret(&self) -> Option<&[u8]> {
        None
    }

    /// What this stream runs over. Swift: `LinkTransport(stream:)`: a Network.framework stream's path,
    /// anything else USB. Here: [`LinkTransport::Usb`] unless the stream (a [`BoundStream`]) says otherwise.
    fn link_transport(&self) -> LinkTransport {
        LinkTransport::Usb
    }

    /// Sets the kernel send buffer (SO_SNDBUF), where the stream is a socket; others ignore it. Swift:
    /// `SocketStream.setSendBufferSize`, used by `HostLink` on the video connection (§7.3).
    fn set_send_buffer_size(&self, bytes: usize) -> io::Result<()> {
        let _ = bytes;
        Ok(())
    }
}

impl ByteStream for tokio::net::UnixStream {
    fn set_send_buffer_size(&self, bytes: usize) -> io::Result<()> {
        socket2::SockRef::from(self).set_send_buffer_size(bytes)
    }
}

/// Plain TCP: tests, and a future fake iPad. Its transport is [`LinkTransport::Usb`], as Swift's
/// `SocketStream` (the loopback TCP of the client's USB listener) is; a Wi-Fi stream says its path through
/// [`BoundStream`].
impl ByteStream for tokio::net::TcpStream {
    fn set_send_buffer_size(&self, bytes: usize) -> io::Result<()> {
        socket2::SockRef::from(self).set_send_buffer_size(bytes)
    }
}

/// Memory (Swift: `MemoryStream`); see [`memory_pair`].
impl ByteStream for DuplexStream {}

impl ByteStream for Box<dyn ByteStream> {
    fn pairing_secret(&self) -> Option<&[u8]> {
        (**self).pairing_secret()
    }
    fn link_transport(&self) -> LinkTransport {
        (**self).link_transport()
    }
    fn set_send_buffer_size(&self, bytes: usize) -> io::Result<()> {
        (**self).set_send_buffer_size(bytes)
    }
}

/// A stream whose transport already authenticated its peer with a key derived from one pairing secret
/// (Wi-Fi TLS-PSK, §7.7 D29), with the path it runs over. [`LinkAcceptor`](crate::LinkAcceptor) takes only
/// that secret's `ChannelHello` on it. `lain-wifi` wraps its `tokio_openssl::SslStream<TcpStream>` in one,
/// with the secret its PSK identity proved; tests wrap a `DuplexStream`. Swift: a `PairingBoundStream`
/// (`NetworkStream` with its `pskIdentity`).
///
/// Difference from Swift: Swift's `NetworkStream` compares PSK identities (`WiFiPSK(secret:).identity ==
/// pskIdentity`); this holds the secret the identity named (`lain-wifi` looks it up in its identity → secret
/// map) and compares secrets. The same pairing passes either way, short of an identity collision (64 bits).
pub struct BoundStream<S> {
    inner: S,
    secret: Option<Vec<u8>>,
    transport: LinkTransport,
}

impl<S> BoundStream<S> {
    /// Bound to `secret`, the pairing the transport authenticated.
    pub fn new(inner: S, secret: impl Into<Vec<u8>>, transport: LinkTransport) -> Self {
        Self { inner, secret: Some(secret.into()), transport }
    }

    /// Only the path, no binding: TLS didn't say which pairing it authenticated (Swift: a `NetworkStream`
    /// whose `pskIdentity` is nil, bound to every secret).
    pub fn unbound(inner: S, transport: LinkTransport) -> Self {
        Self { inner, secret: None, transport }
    }

    pub fn get_ref(&self) -> &S {
        &self.inner
    }

    pub fn get_mut(&mut self) -> &mut S {
        &mut self.inner
    }

    pub fn into_inner(self) -> S {
        self.inner
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for BoundStream<S> {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for BoundStream<S> {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
    fn poll_write_vectored(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bufs: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write_vectored(cx, bufs)
    }
    fn is_write_vectored(&self) -> bool {
        self.inner.is_write_vectored()
    }
}

/// The send buffer isn't reachable through a generic `S` (a TLS stream wraps the socket): set SO_SNDBUF on
/// the socket before wrapping it.
impl<S: AsyncRead + AsyncWrite + Unpin + Send + 'static> ByteStream for BoundStream<S> {
    fn pairing_secret(&self) -> Option<&[u8]> {
        self.secret.as_deref()
    }
    fn link_transport(&self) -> LinkTransport {
        self.transport.clone()
    }
}

pub(crate) fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Each end's buffer in [`memory_pair`]: a writer waits while this much is unread.
pub const MEMORY_STREAM_BUFFER: usize = 256 * 1024;

/// An in-memory stream pair, for loopback tests and fakes. Swift: `MemoryStream.pair()`.
///
/// Difference from Swift: a `MemoryStream` buffers without bound; a tokio duplex holds at most
/// [`MEMORY_STREAM_BUFFER`] unread bytes per direction, beyond which its writer (the channel's writer task,
/// never the caller of `send`) waits. Bytes written before the far end reads are buffered, as in Swift.
pub fn memory_pair() -> (DuplexStream, DuplexStream) {
    tokio::io::duplex(MEMORY_STREAM_BUFFER)
}

/// Opens byte streams to the peer, one per connection of a link: usbmuxd `Connect` over USB (in
/// `lain-host`, on `lain-usbmux`), TLS over Wi-Fi (`lain-wifi`'s client), memory in tests. Swift:
/// `StreamDialer`; `dial()` and its default `dial(kind:)` are one method, which a Wi-Fi dialer uses to mark
/// realtime traffic and keep the three connections on one path.
pub trait StreamDialer: Send + Sync + 'static {
    type Stream: ByteStream;

    /// A dialer's own failure is [`TransportError::Dial`], carrying its error ([`DialError::new`]).
    fn dial(&self, kind: ConnectionKind) -> impl Future<Output = Result<Self::Stream, TransportError>> + Send;
}

/// One connection a [`MemoryDialer`] opened: the far end, for the test's acceptor.
#[derive(Debug)]
pub struct MemoryConnection {
    pub kind: ConnectionKind,
    pub stream: DuplexStream,
}

/// A [`StreamDialer`] whose every dial makes a [`memory_pair`] and hands the far end to whoever holds the
/// receiver (an acceptor, a fake peer). No Swift counterpart: Swift's tests dial loopback TCP.
#[derive(Debug, Clone)]
pub struct MemoryDialer {
    far_ends: mpsc::UnboundedSender<MemoryConnection>,
}

impl MemoryDialer {
    /// The dialer, and the far ends of what it dials.
    pub fn new() -> (Self, mpsc::UnboundedReceiver<MemoryConnection>) {
        let (far_ends, rx) = mpsc::unbounded_channel();
        (Self { far_ends }, rx)
    }
}

impl StreamDialer for MemoryDialer {
    type Stream = DuplexStream;

    async fn dial(&self, kind: ConnectionKind) -> Result<DuplexStream, TransportError> {
        let (near, far) = memory_pair();
        self.far_ends.send(MemoryConnection { kind, stream: far }).map_err(|_| {
            TransportError::Dial(DialError::new(io::Error::new(io::ErrorKind::ConnectionRefused, "nobody accepts")))
        })?;
        Ok(near)
    }
}
