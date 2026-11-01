//! TCP options for Wi-Fi connections. Swift: `NetworkStreamOptions` (`NetworkStream.swift`).

use std::io;
use std::time::Duration;

use socket2::{SockRef, TcpKeepalive};
use tokio::net::TcpStream;

/// TCP keepalive: the first probe after 2 s idle, then every 1 s; 4 unanswered probes drop the
/// connection, so a vanished peer ends the session in about 6 s (invariant 4). Swift:
/// `NetworkStreamOptions.keepaliveIdle`, `keepaliveInterval`, `keepaliveCount`.
pub const KEEPALIVE_IDLE: Duration = Duration::from_secs(2);
pub const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(1);
pub const KEEPALIVE_COUNT: u32 = 4;
/// How long unacknowledged data (video in flight to a vanished peer) may wait before the connection drops:
/// `TCP_USER_TIMEOUT`. Swift: `NetworkStreamOptions.connectionDropTime` (Network.framework's
/// `connectionDropTime`).
pub const CONNECTION_DROP_TIME: Duration = Duration::from_secs(6);
/// DSCP EF (46), for the dialer's realtime connection. Swift's dialer gives realtime the
/// `.interactiveVoice` service class (`NetworkStreamOptions.interactiveRealtime`), which Apple maps to its
/// voice class; on Linux the nearest is marking the packets EF (the IP TOS byte 0xB8).
pub const REALTIME_DSCP: u32 = 46;

/// `TCP_NODELAY`, keepalive and the drop time, on every Wi-Fi socket in both roles. Swift:
/// `NetworkStreamOptions.parameters(tls:)`.
///
/// Difference from Swift: no send-buffer change (Swift's `NetworkStream` sets none either), and nothing
/// about peer-to-peer interfaces (Linux has no AWDL).
pub(crate) fn configure(stream: &TcpStream) -> io::Result<()> {
    stream.set_nodelay(true)?;
    let socket = SockRef::from(stream);
    socket.set_keepalive(true)?;
    socket.set_tcp_keepalive(
        &TcpKeepalive::new().with_time(KEEPALIVE_IDLE).with_interval(KEEPALIVE_INTERVAL).with_retries(KEEPALIVE_COUNT),
    )?;
    socket.set_tcp_user_timeout(Some(CONNECTION_DROP_TIME))?;
    Ok(())
}

/// Marks a dialed realtime connection's packets with [`REALTIME_DSCP`]. Swift: `dialParameters(psk:kind:)`'s
/// `serviceClass`. The host never marks: which accepted connection is realtime is known only after its
/// `ChannelHello`, past TLS, and Swift's listener marks nothing either.
pub(crate) fn mark_realtime(stream: &TcpStream) -> io::Result<()> {
    let socket = SockRef::from(stream);
    let tos = REALTIME_DSCP << 2;
    match stream.local_addr()? {
        std::net::SocketAddr::V4(_) => socket.set_tos_v4(tos),
        std::net::SocketAddr::V6(a) => {
            socket.set_tclass_v6(tos)?;
            // An IPv4-mapped peer on an IPv6 socket sends IPv4 packets, which take IP_TOS.
            if a.ip().to_ipv4_mapped().is_some() { socket.set_tos_v4(tos) } else { Ok(()) }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Swift: `NetworkStreamPolicy.parametersCarryTheTCPAndPathPolicy` (the TCP half; the rest is
    /// Network.framework's parameters, with no Linux counterpart).
    #[tokio::test]
    async fn sockets_carry_the_tcp_policy() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (dialed, accepted) = tokio::join!(TcpStream::connect(addr), listener.accept());
        let (dialed, (accepted, _)) = (dialed.unwrap(), accepted.unwrap());
        configure(&accepted).unwrap();
        configure(&dialed).unwrap();
        mark_realtime(&dialed).unwrap();
        for stream in [&dialed, &accepted] {
            let s = SockRef::from(stream);
            assert!(stream.nodelay().unwrap());
            assert!(s.keepalive().unwrap());
            assert_eq!(s.tcp_keepalive_time().unwrap(), KEEPALIVE_IDLE);
            assert_eq!(s.tcp_keepalive_interval().unwrap(), KEEPALIVE_INTERVAL);
            assert_eq!(s.tcp_keepalive_retries().unwrap(), KEEPALIVE_COUNT);
            assert_eq!(s.tcp_user_timeout().unwrap(), Some(CONNECTION_DROP_TIME));
        }
        assert_eq!(SockRef::from(&dialed).tos_v4().unwrap(), 0xB8);
        assert_eq!(SockRef::from(&accepted).tos_v4().unwrap(), 0);
    }
}
