//! One TLS-PSK connection, either end, and the dialer. Swift: `NetworkStream`, `NetworkStreamDialer` and
//! `WiFiLinkDialer` (`NetworkStream.swift`).

use std::fmt;
use std::net::SocketAddr;
use std::pin::Pin;
use std::time::Duration;

use lain_link::{BoundStream, ByteStream, DialError, LinkTransport, StreamDialer, TransportError};
use lain_platform::clock::now_ns;
use lain_proto::ConnectionKind;
use openssl::ssl::{Ssl, SslContext};
use tokio::net::TcpStream;
use tokio_openssl::SslStream;

use crate::error::classify;
use crate::tls::{check_negotiated, chosen, client_context};
use crate::{NegotiatedTls, WiFiError, WiFiPsk, ifaddrs, socket};

/// TLS over TCP: what a [`WiFiConnection`]'s [`BoundStream`] wraps.
pub type TlsStream = SslStream<TcpStream>;

/// A TCP + TLS-PSK connection whose handshake is done, with what it negotiated: the listener hands these
/// over, and the dialer returns them. Swift: `NetworkStream`, handed out only once ready.
///
/// Difference from Swift: no `NetworkPath` (kind, `NWInterface`, endpoints); the path is the
/// [`LinkTransport`] its stream carries (the interface that owns the local address; never peer-to-peer,
/// Linux has no AWDL) and the two socket addresses. The close (Swift's flush-then-cancel with a 1.5 s
/// deadline) is the reader's: `lain-link`'s channel shuts the stream down (TLS `close_notify`, then FIN)
/// within its `CLOSE_LINGER`.
pub struct WiFiConnection {
    /// Bound to the pairing secret TLS proved (on the host: the one the PSK callback chose for the
    /// identity the client offered; on a dialer: its own, when it has it).
    pub stream: BoundStream<TlsStream>,
    pub tls: NegotiatedTls,
    /// The PSK identity TLS authenticated: the dialer's own, or the one the client offered the listener.
    pub psk_identity: String,
    /// Start to done: TCP and TLS for a dial; TLS alone for an accepted connection. Swift: `handshakeNs`.
    pub handshake_ns: u64,
    pub local_addr: SocketAddr,
    pub peer_addr: SocketAddr,
}

impl WiFiConnection {
    /// `Network { interface, peer_to_peer: false }`. Swift: `NetworkPath.linkTransport`.
    pub fn transport(&self) -> LinkTransport {
        self.stream.link_transport()
    }

    /// The stream as `lain-link` takes it: the boundary with `lain-host`.
    pub fn into_byte_stream(self) -> Box<dyn ByteStream> {
        Box::new(self.stream)
    }

    /// The TCP socket under TLS.
    pub fn tcp(&self) -> &TcpStream {
        self.stream.get_ref().get_ref()
    }
}

impl fmt::Debug for WiFiConnection {
    /// Never the secret.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WiFiConnection")
            .field("tls", &self.tls)
            .field("psk_identity", &self.psk_identity)
            .field("transport", &self.transport())
            .field("local_addr", &self.local_addr)
            .field("peer_addr", &self.peer_addr)
            .finish_non_exhaustive()
    }
}

/// The transport of a socket whose local address is `local`.
fn transport_of(local: SocketAddr) -> LinkTransport {
    LinkTransport::Network { interface: ifaddrs::interface_owning(local), peer_to_peer: false }
}

fn tls_error(e: openssl::error::ErrorStack) -> WiFiError {
    WiFiError::Tls(e.to_string())
}

/// The server side of one handshake on an accepted socket (no deadline: the listener bounds it). Only
/// [`NegotiatedTls::REQUIRED`] opens, and the stream is bound to the secret the PSK callback recorded for
/// this connection, which must name the identity OpenSSL reports. Swift: `NetworkStream.Core.open` on an
/// accepted connection, then `becameReady`.
pub(crate) async fn accept_tls(context: &SslContext, tcp: TcpStream, started_ns: u64) -> Result<WiFiConnection, WiFiError> {
    let local_addr = tcp.local_addr()?;
    let peer_addr = tcp.peer_addr()?;
    let mut stream = SslStream::new(Ssl::new(context).map_err(tls_error)?, tcp).map_err(tls_error)?;
    Pin::new(&mut stream).accept().await.map_err(|e| classify(&e))?;
    let tls = check_negotiated(stream.ssl())?;
    let chosen = chosen(stream.ssl()).ok_or_else(|| WiFiError::Tls("the PSK callback recorded no pairing".into()))?;
    if stream.ssl().psk_identity() != Some(chosen.identity.as_bytes()) {
        return Err(WiFiError::Tls("the PSK identity changed after the callback chose it".into()));
    }
    let handshake_ns = now_ns().saturating_sub(started_ns);
    let stream = BoundStream::new(stream, chosen.secret, transport_of(local_addr));
    Ok(WiFiConnection { stream, tls, psk_identity: chosen.identity, handshake_ns, local_addr, peer_addr })
}

/// Dials one address over TCP + TLS-PSK with one pairing's PSK (§7.7): tests, and a fake iPad. Swift:
/// `NetworkStreamDialer`, and `WiFiLinkDialer` as a [`StreamDialer`] for `lain-link`'s `LinkDialer`.
///
/// Differences from Swift:
/// - It dials a socket address, not a Bonjour service, so there is nothing to resolve and no path to pin:
///   `WiFiLinkDialer`'s pinning of video and audio to realtime's interface has no counterpart (the kernel
///   routes all three to one address alike).
/// - Realtime is marked DSCP EF ([`socket::REALTIME_DSCP`]) where Swift sets the `.interactiveVoice`
///   service class; there is no switch to turn it off (Swift's `interactiveRealtime`, a bench knob).
#[derive(Clone)]
pub struct WiFiDialer {
    addr: SocketAddr,
    psk: WiFiPsk,
    secret: Option<Vec<u8>>,
    timeout: Duration,
}

impl WiFiDialer {
    /// Swift: `NetworkStreamDialer.defaultTimeout`.
    pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);

    /// With the PSK of `secret`; its streams are bound to `secret`.
    pub fn new(addr: SocketAddr, secret: &[u8]) -> Self {
        Self { addr, psk: WiFiPsk::new(secret), secret: Some(secret.to_vec()), timeout: Self::DEFAULT_TIMEOUT }
    }

    /// With any PSK (tests: a known identity with the wrong key); its streams are unbound.
    pub fn with_psk(addr: SocketAddr, psk: WiFiPsk) -> Self {
        Self { addr, psk, secret: None, timeout: Self::DEFAULT_TIMEOUT }
    }

    /// TCP and TLS must be done within this.
    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn psk(&self) -> &WiFiPsk {
        &self.psk
    }

    /// Connects and completes TLS within the timeout. Dropping the future drops the connection. Swift:
    /// `NetworkStream.connect` (`kind` picks the service class).
    pub async fn connect(&self, kind: Option<ConnectionKind>) -> Result<WiFiConnection, WiFiError> {
        let result = match tokio::time::timeout(self.timeout, self.connect_now(kind)).await {
            Ok(result) => result,
            Err(_) => Err(WiFiError::Timeout),
        };
        if let Err(e) = &result {
            tracing::info!("dial {} failed: {e}", self.addr);
        }
        result
    }

    async fn connect_now(&self, kind: Option<ConnectionKind>) -> Result<WiFiConnection, WiFiError> {
        let started_ns = now_ns();
        let tcp = TcpStream::connect(self.addr).await?;
        socket::configure(&tcp)?;
        if kind == Some(ConnectionKind::Realtime) {
            socket::mark_realtime(&tcp)?;
        }
        let local_addr = tcp.local_addr()?;
        let peer_addr = tcp.peer_addr()?;
        let context = client_context(&self.psk).map_err(tls_error)?;
        let mut stream = SslStream::new(Ssl::new(&context).map_err(tls_error)?, tcp).map_err(tls_error)?;
        Pin::new(&mut stream).connect().await.map_err(|e| classify(&e))?;
        let tls = check_negotiated(stream.ssl())?;
        let handshake_ns = now_ns().saturating_sub(started_ns);
        let transport = transport_of(local_addr);
        let stream = match &self.secret {
            Some(secret) => BoundStream::new(stream, secret.clone(), transport),
            None => BoundStream::unbound(stream, transport),
        };
        Ok(WiFiConnection {
            stream,
            tls,
            psk_identity: self.psk.identity().to_owned(),
            handshake_ns,
            local_addr,
            peer_addr,
        })
    }
}

impl fmt::Debug for WiFiDialer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("WiFiDialer").field("addr", &self.addr).field("psk", &self.psk).finish_non_exhaustive()
    }
}

impl StreamDialer for WiFiDialer {
    type Stream = BoundStream<TlsStream>;

    /// A failure is [`TransportError::Dial`] carrying the [`WiFiError`] (`downcast_ref::<WiFiError>()`).
    async fn dial(&self, kind: ConnectionKind) -> Result<Self::Stream, TransportError> {
        self.connect(Some(kind)).await.map(|c| c.stream).map_err(|e| TransportError::Dial(DialError::new(e)))
    }
}

/// Dials `addr` with the PSK of `secret`: one connection, no kind (best effort). Swift:
/// `NetworkStreamDialer(endpoint:psk:).connect(kind: nil)`.
pub async fn connect(addr: SocketAddr, secret: &[u8]) -> Result<WiFiConnection, WiFiError> {
    WiFiDialer::new(addr, secret).connect(None).await
}
