//! The TLS-PSK listener. Swift: `NetworkStreamListener` (`NetworkStream.swift`).

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use lain_platform::clock::now_ns;
use openssl::ssl::SslContext;
use socket2::{Domain, Protocol, Socket, Type};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::{AbortHandle, JoinHandle};

use crate::connection::accept_tls;
use crate::pending::{DropReports, PendingHandshakes};
use crate::tls::server_context;
use crate::{PskTable, WiFiConnection, WiFiError, socket};

/// Where and how a [`TlsPskListener`] listens. Swift: `NetworkStreamOptions` (the listener's half) and
/// `NetworkStreamListener`'s constants.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ListenerOptions {
    /// The default is the dual-stack wildcard `[::]:0` (IPv4 arrives IPv4-mapped; any free port, which the
    /// daemon advertises). If IPv6 is unavailable, the wildcard falls back to `0.0.0.0`. Tests pass
    /// [`loopback`](Self::loopback). Swift: the wildcard bind, `loopbackOnly`.
    pub bind: SocketAddr,
    /// From accept to TLS done. A real client needs milliseconds. Swift:
    /// `NetworkStreamListener.handshakeTimeout`.
    pub handshake_timeout: Duration,
    /// Handshakes in progress at once, in total and per remote address. Swift:
    /// `maxPendingHandshakes`, `maxPendingHandshakesPerHost`.
    pub max_pending: usize,
    pub max_pending_per_host: usize,
}

impl ListenerOptions {
    pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(3);
    pub const MAX_PENDING: usize = 32;
    pub const MAX_PENDING_PER_HOST: usize = 8;

    /// `127.0.0.1`, any port: nothing leaves the machine. Swift: `NetworkStreamOptions.loopback`.
    pub fn loopback() -> Self {
        Self { bind: SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), ..Self::default() }
    }
}

impl Default for ListenerOptions {
    fn default() -> Self {
        Self {
            bind: SocketAddr::from((Ipv6Addr::UNSPECIFIED, 0)),
            handshake_timeout: Self::HANDSHAKE_TIMEOUT,
            max_pending: Self::MAX_PENDING,
            max_pending_per_host: Self::MAX_PENDING_PER_HOST,
        }
    }
}

/// What a listener does with a connection whose handshake is done. It must not block (it runs in the
/// handshake's task); the [`WiFiListener`](crate::WiFiListener) passes it on with `try_send`.
pub type OnAccept = Arc<dyn Fn(WiFiConnection) + Send + Sync>;

/// How many rejections [`TlsPskListener::bind`]'s receiver holds; beyond, they are only logged.
pub const REJECTIONS_BUFFER: usize = 16;

/// Accepts TLS-PSK connections (§7.7, D29) with the PSKs of a live [`PskTable`]. Each accepted connection
/// is handed to `on_accept` only once its handshake is done (TLS 1.2, 0xCCAC, a PSK the table holds); one
/// that isn't done within [`ListenerOptions::handshake_timeout`] is dropped, so the acceptor's own
/// `ChannelHello` deadline measures the same thing as on USB. Every socket gets [`socket`]'s TCP options.
/// Swift: `NetworkStreamListener`.
///
/// Anyone on the LAN can connect, so unauthenticated handshakes are capped: at most `max_pending` at once,
/// `max_pending_per_host` per remote address; past a cap the oldest goes, the same address's first,
/// silently. Failed handshakes are logged and sent to the rejections receiver, at most 5 a second, with a
/// summary of the rest.
///
/// [`cancel`](Self::cancel), or dropping it, stops listening and drops every pending handshake at once;
/// connections already handed over stay up. Must be used inside a tokio runtime.
///
/// Differences from Swift: no Bonjour advertisement (the daemon advertises through `lain-platform`'s
/// `Advertiser`) and no state events: binding is synchronous, so [`bind`](Self::bind) either listens or
/// fails. Its PSKs are live ([`PskTable`]), where Network.framework fixes them at creation.
pub struct TlsPskListener {
    local_addr: SocketAddr,
    shared: Arc<Shared>,
    accept_loop: JoinHandle<()>,
}

struct Shared {
    context: SslContext,
    table: PskTable,
    handshake_timeout: Duration,
    on_accept: OnAccept,
    rejections: mpsc::Sender<WiFiError>,
    intake: Mutex<Intake>,
}

struct Intake {
    /// Handshakes in progress, oldest first: their tasks, to abort.
    pending: PendingHandshakes<AbortHandle>,
    cancelled: bool,
    drops: DropReports,
}

impl Shared {
    fn intake(&self) -> MutexGuard<'_, Intake> {
        self.intake.lock().unwrap_or_else(|e| e.into_inner())
    }
}

impl TlsPskListener {
    /// Binds and starts accepting. The receiver gets failed handshakes (rate-limited; dropping it is fine).
    pub fn bind(
        table: PskTable,
        options: &ListenerOptions,
        on_accept: impl Fn(WiFiConnection) + Send + Sync + 'static,
    ) -> io::Result<(Self, mpsc::Receiver<WiFiError>)> {
        let context = server_context(table.clone()).map_err(io::Error::other)?;
        let listener = TcpListener::from_std(bind_socket(options.bind)?)?;
        let local_addr = listener.local_addr()?;
        let (rejections, rejected) = mpsc::channel(REJECTIONS_BUFFER);
        let shared = Arc::new(Shared {
            context,
            table,
            handshake_timeout: options.handshake_timeout,
            on_accept: Arc::new(on_accept),
            rejections,
            intake: Mutex::new(Intake {
                pending: PendingHandshakes::new(options.max_pending, options.max_pending_per_host),
                cancelled: false,
                drops: DropReports::default(),
            }),
        });
        let accept_loop = tokio::spawn(accept_loop(listener, shared.clone()));
        tracing::info!("Wi-Fi listener on {local_addr}: PSK identities {}", shared.table.identities().join(", "));
        Ok((Self { local_addr, shared, accept_loop }, rejected))
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub fn port(&self) -> u16 {
        self.local_addr.port()
    }

    /// The table its handshakes read.
    pub fn table(&self) -> &PskTable {
        &self.shared.table
    }

    /// Accepted connections still in their handshake.
    pub fn pending_handshakes(&self) -> usize {
        self.shared.intake().pending.len()
    }

    /// Stops listening and drops pending handshakes; streams already handed over stay up. Idempotent.
    pub fn cancel(&self) {
        self.accept_loop.abort();
        let pending = {
            let mut intake = self.shared.intake();
            intake.cancelled = true;
            intake.pending.remove_all()
        };
        pending.iter().for_each(AbortHandle::abort);
    }
}

impl Drop for TlsPskListener {
    fn drop(&mut self) {
        self.cancel();
    }
}

impl std::fmt::Debug for TlsPskListener {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TlsPskListener")
            .field("local_addr", &self.local_addr)
            .field("table", &self.shared.table)
            .finish_non_exhaustive()
    }
}

/// A listening socket: `SO_REUSEADDR`, dual-stack for the IPv6 wildcard, falling back to the IPv4
/// wildcard when IPv6 is unavailable.
fn bind_socket(addr: SocketAddr) -> io::Result<std::net::TcpListener> {
    match bind_exactly(addr) {
        Err(e) if addr.ip() == IpAddr::V6(Ipv6Addr::UNSPECIFIED) && e.raw_os_error() == Some(libc::EAFNOSUPPORT) => {
            tracing::warn!("Wi-Fi listener: no IPv6 ({e}); listening on IPv4 only");
            bind_exactly(SocketAddr::from((Ipv4Addr::UNSPECIFIED, addr.port())))
        }
        other => other,
    }
}

fn bind_exactly(addr: SocketAddr) -> io::Result<std::net::TcpListener> {
    let socket = Socket::new(Domain::for_address(addr), Type::STREAM, Some(Protocol::TCP))?;
    if addr.is_ipv6() {
        socket.set_only_v6(false)?;
    }
    socket.set_reuse_address(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&addr.into())?;
    socket.listen(128)?;
    Ok(socket.into())
}

/// How long the accept loop rests after an accept error (out of descriptors, say), so it can't spin.
const ACCEPT_ERROR_PAUSE: Duration = Duration::from_millis(100);

async fn accept_loop(listener: TcpListener, shared: Arc<Shared>) {
    loop {
        match listener.accept().await {
            Ok((tcp, peer)) => admit(&shared, tcp, peer),
            Err(e) => {
                tracing::warn!("Wi-Fi listener: accept failed: {e}");
                tokio::time::sleep(ACCEPT_ERROR_PAUSE).await;
            }
        }
    }
}

/// What the per-host cap counts: the remote address without its port, IPv4-mapped addresses as IPv4.
/// Swift: `NetworkStreamListener.remoteHost(of:)`.
pub(crate) fn remote_host(peer: SocketAddr) -> String {
    peer.ip().to_canonical().to_string()
}

/// Starts the handshake of an accepted socket, admitted past the caps. Admission and the task's start
/// happen under one lock, so the task can't finish before it is pending.
fn admit(shared: &Arc<Shared>, tcp: TcpStream, peer: SocketAddr) {
    if let Err(e) = socket::configure(&tcp) {
        tracing::debug!("Wi-Fi listener: socket options for {peer}: {e}");
    }
    let host = remote_host(peer);
    let (evicted, summarize) = {
        let mut intake = shared.intake();
        if intake.cancelled {
            return;
        }
        let key = intake.pending.next_key();
        let task = tokio::spawn(handshake(shared.clone(), key, tcp));
        let (admitted, evicted) = intake.pending.admit(task.abort_handle(), &host);
        debug_assert_eq!(admitted, key);
        let summarize = intake.drops.evicted(evicted.len());
        (evicted, summarize)
    };
    // Aborting drops the evicted task's socket at once.
    evicted.iter().for_each(AbortHandle::abort);
    if summarize {
        summarize_later(shared.clone());
    }
}

async fn handshake(shared: Arc<Shared>, key: u64, tcp: TcpStream) {
    let started_ns = now_ns();
    let result =
        match tokio::time::timeout(shared.handshake_timeout, accept_tls(&shared.context, tcp, started_ns)).await {
            Ok(result) => result,
            Err(_) => Err(WiFiError::Timeout),
        };
    let was_pending = shared.intake().pending.remove(key).is_some();
    match result {
        // Dropped by a cancel just now: not handed over (dropping it closes it).
        Ok(_) if !was_pending => {}
        Ok(connection) => {
            tracing::debug!(
                "Wi-Fi: {} authenticated {} in {:.1} ms",
                connection.peer_addr,
                connection.psk_identity,
                connection.handshake_ns as f64 / 1e6
            );
            (shared.on_accept)(connection);
        }
        // Not pending any more (a cancel): not a rejection.
        Err(_) if !was_pending => {}
        Err(error) => {
            let (report, summarize) = shared.intake().drops.rejected(now_ns());
            if summarize {
                summarize_later(shared.clone());
            }
            if report {
                tracing::info!("Wi-Fi: dropped a connection before handover: {error}");
                let _ = shared.rejections.try_send(error);
            }
        }
    }
}

/// One notice for what went unreported, a window after the first of it.
fn summarize_later(shared: Arc<Shared>) {
    tokio::spawn(async move {
        tokio::time::sleep(DropReports::WINDOW).await;
        let (unreported, evicted) = shared.intake().drops.take_summary();
        tracing::info!(
            "Wi-Fi handshake flood: {evicted} pending handshakes evicted, {unreported} failed handshakes not reported"
        );
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Swift: `NetworkStreamPolicy.thePerAddressCapCountsAddressesNotPorts`.
    #[test]
    fn the_per_address_cap_counts_addresses_not_ports() {
        let host = |s: &str| remote_host(s.parse().unwrap());
        assert_eq!(host("127.0.0.1:50001"), host("127.0.0.1:50002"));
        assert_eq!(host("127.0.0.1:1"), "127.0.0.1");
        assert_ne!(host("192.168.1.20:1"), host("192.168.1.21:1"));
        // A dual-stack socket's IPv4 peers count as IPv4.
        assert_eq!(host("[::ffff:192.168.1.20]:1"), "192.168.1.20");
        assert_eq!(host("[fe80::1]:1"), "fe80::1");
    }

    #[test]
    fn the_default_is_the_dual_stack_wildcard() {
        let options = ListenerOptions::default();
        assert_eq!(options.bind, "[::]:0".parse().unwrap());
        assert_eq!(options.handshake_timeout, Duration::from_secs(3));
        assert_eq!((options.max_pending, options.max_pending_per_host), (32, 8));
        assert_eq!(ListenerOptions::loopback().bind, "127.0.0.1:0".parse().unwrap());
    }
}
