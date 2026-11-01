//! Links over real sockets: the client's loopback TCP listener (Swift: `LinkEstablishment` and
//! `theClientListenerSetsNoDelayOnEveryAcceptedSocket`, which dial `ClientLinkListener` over TCP), and the
//! host's USB path over Unix sockets, which is what `lain-usbmux`'s `connect` returns (Swift:
//! `USBPathIntegration.theHostsUSBVideoStreamKeepsItsSmallSendBuffer`). Real time, no hardware.

mod common;

use std::os::unix::net::UnixStream as StdUnixStream;
use std::sync::{Arc, Mutex};

use common::*;
use lain_link::*;
use lain_platform::fake::MemorySecretStore;
use lain_proto::*;

/// Dials 127.0.0.1:`port`. Swift: `LoopbackDialer`.
struct LoopbackDialer(u16);

impl StreamDialer for LoopbackDialer {
    type Stream = tokio::net::TcpStream;
    async fn dial(&self, _kind: ConnectionKind) -> Result<Self::Stream, TransportError> {
        tokio::net::TcpStream::connect(("127.0.0.1", self.0)).await.map_err(|e| TransportError::Dial(DialError::new(e)))
    }
}

#[tokio::test]
async fn the_host_pairs_with_the_client_listener_over_tcp_then_reuses_the_secret() {
    let client_secrets = store(&[]);
    let (listener, mut events) =
        ClientLinkListener::bind(Some(0), client_secrets.clone(), PairingAccounts::USB_HOST, true, offered())
            .await
            .unwrap();
    let port = listener.port();
    assert_ne!(port, 0);
    let host_secrets = store(&[]);
    let versions = offered();
    for expect_paired in [true, false] {
        let opening = HostLink::open(LoopbackDialer(port), &host_secrets, "IPAD", expect_paired, "", &versions);
        let answering = async {
            let accepted = next(&mut events.links, T).await.unwrap();
            accepted.link.realtime.send(&Message::Hello(sample_hello())).unwrap();
            accepted
        };
        let (opened, mut accepted) = tokio::join!(opening, answering);
        let (mut link, hello, paired) = opened.unwrap();
        assert_eq!(hello, sample_hello());
        assert_eq!(paired, expect_paired);
        assert_eq!(accepted.paired, expect_paired);
        assert_eq!(accepted.link.session_token, link.session_token);
        assert_eq!(accepted.link.transport, LinkTransport::Usb);
        assert_eq!(client_secrets.snapshot().get("host"), host_secrets.snapshot().get("IPAD"));
        // The link works on every connection.
        for (a, d) in accepted.link.channels_mut().into_iter().zip(link.channels_mut()) {
            a.send(&ping(1, 0)).unwrap();
            assert_eq!(d.recv_timeout(T).await.unwrap().message, ping(1, 0));
        }
        link.close();
        assert!(tokio::time::timeout(T, accepted.link.realtime.closed()).await.is_ok());
    }

    // After cancel nothing is accepted any more.
    listener.cancel();
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    if let Ok(stream) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await {
        let channel = MessageChannel::new(stream, "late");
        assert!(tokio::time::timeout(T, channel.closed()).await.is_ok());
    }
}

/// Dials over Unix socket pairs, as usbmuxd's `Connect` gives the host a Unix socket; keeps a duplicate of
/// each dialed socket so the test can read its options afterwards.
struct UnixDialer {
    acceptor: Arc<LinkAcceptor<MemorySecretStore>>,
    dialed: Arc<Mutex<Vec<(ConnectionKind, StdUnixStream)>>>,
}

impl StreamDialer for UnixDialer {
    type Stream = tokio::net::UnixStream;
    async fn dial(&self, kind: ConnectionKind) -> Result<Self::Stream, TransportError> {
        let (near, far) = StdUnixStream::pair()?;
        self.dialed.lock().unwrap().push((kind, near.try_clone()?));
        for s in [&near, &far] {
            s.set_nonblocking(true)?;
        }
        self.acceptor.accept(tokio::net::UnixStream::from_std(far)?);
        Ok(tokio::net::UnixStream::from_std(near)?)
    }
}

fn send_buffer(socket: &StdUnixStream) -> usize {
    socket2::SockRef::from(socket).send_buffer_size().unwrap()
}

#[tokio::test]
async fn the_hosts_usb_video_stream_keeps_its_small_send_buffer() {
    let client = Acceptor::client(store(&[]), true, offered()).answering_hello();
    let dialed = Arc::new(Mutex::new(Vec::new()));
    let dialer = UnixDialer { acceptor: client.acceptor.clone(), dialed: dialed.clone() };
    let default = send_buffer(&StdUnixStream::pair().unwrap().0);
    let (_link, hello, paired) =
        HostLink::open(dialer, &store(&[]), "IPAD-SERIAL", true, "", &offered()).await.unwrap();
    assert!(paired && hello == sample_hello());
    let dialed = dialed.lock().unwrap();
    let kinds: Vec<_> = dialed.iter().map(|(k, _)| *k).collect();
    assert_eq!(kinds, [ConnectionKind::Realtime, ConnectionKind::Video, ConnectionKind::Audio]);
    for (kind, socket) in dialed.iter() {
        let size = send_buffer(socket);
        if *kind == ConnectionKind::Video {
            // §7.3; Linux reports twice the request.
            assert_eq!(size, 2 * HostLink::VIDEO_SEND_BUFFER);
        } else {
            assert_eq!(size, default, "{kind:?} keeps the default");
        }
    }
}
