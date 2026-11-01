//! The client against the fake daemon (Swift: `LainUSBMuxTests/USBMuxTests.swift`, `AgainstFakeDaemon`).

use std::time::Duration;

use lain_usbmux::fake::{FakeDevice, FakeTarget, FakeUsbMuxd};
use lain_usbmux::protocol::{self, result};
use lain_usbmux::{UsbMuxClient, UsbMuxDevice, UsbMuxError, UsbMuxEvent, UsbMuxEvents};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UnixListener};
use tokio::sync::mpsc;
use tokio::time::timeout;

const WAIT: Duration = Duration::from_secs(5);

/// What the fake's `Attached` reports, as Swift's fake does.
fn fake_device(id: u32, serial: &str) -> UsbMuxDevice {
    UsbMuxDevice { product_id: Some(4779), connection_speed: Some(480_000_000), ..UsbMuxDevice::new(id, serial) }
}

async fn next(events: &mut UsbMuxEvents) -> Option<UsbMuxEvent> {
    timeout(WAIT, events.next()).await.expect("an event in time").expect("no error")
}

/// A TCP echo server on an ephemeral loopback port (Swift: `EchoServer`).
async fn echo_server() -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        while let Ok((mut c, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (mut r, mut w) = c.split();
                let _ = tokio::io::copy(&mut r, &mut w).await;
            });
        }
    });
    addr
}

/// A TCP address with nothing listening.
async fn dead_address() -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    listener.local_addr().unwrap()
}

#[tokio::test]
async fn listen_reports_usb_devices_and_detaches() {
    let mux = FakeUsbMuxd::start(
        vec![FakeDevice::usb(5, "IPAD"), FakeDevice::network(9, "WIFI")],
        FakeTarget::Tcp(dead_address().await),
    )
    .unwrap();
    let mut events = mux.client().listen().await.unwrap();
    assert_eq!(next(&mut events).await, Some(UsbMuxEvent::Attached(fake_device(5, "IPAD"))));
    mux.detach(9); // network device: filtered
    mux.detach(5);
    assert_eq!(next(&mut events).await, Some(UsbMuxEvent::Detached { device_id: 5 }));
    mux.attach(FakeDevice::usb(6, "IPAD2"));
    assert_eq!(next(&mut events).await, Some(UsbMuxEvent::Attached(fake_device(6, "IPAD2"))));
    // A detach of a device the stream never reported is skipped.
    mux.detach(77);
    mux.detach(6);
    assert_eq!(next(&mut events).await, Some(UsbMuxEvent::Detached { device_id: 6 }));
}

#[tokio::test]
async fn a_restart_ends_the_stream_and_listening_again_replays_the_devices() {
    let mux = FakeUsbMuxd::start(vec![FakeDevice::usb(5, "IPAD")], FakeTarget::Tcp(dead_address().await)).unwrap();
    let mut events = mux.client().listen().await.unwrap();
    assert_eq!(next(&mut events).await, Some(UsbMuxEvent::Attached(fake_device(5, "IPAD"))));
    mux.restart();
    assert_eq!(next(&mut events).await, None);
    let mut events = mux.client().listen().await.unwrap();
    assert_eq!(next(&mut events).await, Some(UsbMuxEvent::Attached(fake_device(5, "IPAD"))));
}

#[tokio::test]
async fn an_exited_daemon_is_unavailable_until_relaunched() {
    let mux = FakeUsbMuxd::start(vec![FakeDevice::usb(5, "IPAD")], FakeTarget::Tcp(dead_address().await)).unwrap();
    let mut events = mux.client().listen().await.unwrap();
    assert!(next(&mut events).await.is_some());
    mux.exit();
    assert_eq!(next(&mut events).await, None);
    // The stale socket refuses connections, as libimobiledevice's leaves it.
    let err = mux.client().listen().await.unwrap_err();
    assert!(
        matches!(&err, UsbMuxError::Unavailable { source, .. } if source.kind() == std::io::ErrorKind::ConnectionRefused),
        "{err:?}"
    );
    mux.relaunch().unwrap();
    let mut events = mux.client().listen().await.unwrap();
    assert_eq!(next(&mut events).await, Some(UsbMuxEvent::Attached(fake_device(5, "IPAD"))));
}

#[tokio::test]
async fn connect_becomes_a_raw_pipe() {
    let mux = FakeUsbMuxd::start(vec![FakeDevice::usb(5, "IPAD")], FakeTarget::Tcp(echo_server().await)).unwrap();
    let mut pipe = mux.client().connect(5, 47800).await.unwrap();
    pipe.write_all(b"hello lain").await.unwrap();
    let mut buf = [0u8; 10];
    timeout(WAIT, pipe.read_exact(&mut buf)).await.unwrap().unwrap();
    assert_eq!(&buf, b"hello lain");
    assert_eq!(mux.connect_count(), 1);
}

#[tokio::test]
async fn connect_hands_off_the_pipe() {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let mux = FakeUsbMuxd::start(vec![FakeDevice::usb(5, "IPAD")], FakeTarget::Handoff(tx)).unwrap();
    let mut pipe = mux.client().connect(5, 47800).await.unwrap();
    let mut far = timeout(WAIT, rx.recv()).await.unwrap().unwrap();
    assert_eq!((far.device_id, far.port), (5, 47800));
    pipe.write_all(b"ping").await.unwrap();
    let mut buf = [0u8; 4];
    far.stream.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"ping");
    far.stream.write_all(b"pong").await.unwrap();
    pipe.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"pong");
    assert_eq!(mux.connect_count(), 1);
}

#[tokio::test]
async fn connect_errors() {
    let mux = FakeUsbMuxd::start(
        vec![FakeDevice::usb(5, "IPAD"), FakeDevice::usb(3, "IPHONE").refusing()],
        FakeTarget::Tcp(dead_address().await),
    )
    .unwrap();
    let client = mux.client();
    let code = |r: Result<_, UsbMuxError>| match r {
        Err(UsbMuxError::Result(n)) => n,
        other => panic!("expected a result, got {other:?}"),
    };
    assert_eq!(code(client.connect(99, 47800).await), result::BAD_DEVICE);
    assert_eq!(code(client.connect(5, 1234).await), result::CONNECTION_REFUSED);
    let refused = client.connect(5, 47800).await; // nothing listening
    assert!(refused.as_ref().unwrap_err().is_connection_refused());
    assert_eq!(code(client.connect(3, 47800).await), result::CONNECTION_REFUSED); // the device refuses
    assert_eq!(mux.connect_count(), 0);
    let missing = UsbMuxClient::new(mux.socket_path().with_file_name("no-such-mux")).connect(5, 47800).await;
    assert!(
        matches!(&missing, Err(UsbMuxError::Unavailable { source, .. }) if source.kind() == std::io::ErrorKind::NotFound),
        "{missing:?}"
    );
}

#[tokio::test]
async fn list_devices_reports_usb_devices() {
    let mux = FakeUsbMuxd::start(
        vec![FakeDevice::usb(5, "IPAD"), FakeDevice::network(9, "WIFI")],
        FakeTarget::Tcp(dead_address().await),
    )
    .unwrap();
    assert_eq!(mux.client().list_devices().await.unwrap(), vec![fake_device(5, "IPAD")]);
    mux.detach(5);
    assert_eq!(mux.client().list_devices().await.unwrap(), vec![]);
}

#[tokio::test]
async fn malformed_events_end_the_stream_with_an_error() {
    let mux = FakeUsbMuxd::start(vec![], FakeTarget::Tcp(dead_address().await)).unwrap();
    // A wrong message type in the header (the binary protocol's MESSAGE_DEVICE_ADD).
    let mut events = mux.client().listen().await.unwrap();
    let mut bad = protocol::result_packet(0, 0).encode().unwrap();
    bad[8] = 4;
    mux.inject(&bad);
    assert!(matches!(timeout(WAIT, events.next()).await.unwrap(), Err(UsbMuxError::Protocol(_))));

    // A body that isn't a plist dictionary.
    let mut events = mux.client().listen().await.unwrap();
    let mut junk = 20u32.to_le_bytes().to_vec();
    junk.extend_from_slice(&[1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0]);
    junk.extend_from_slice(b"junk");
    mux.inject(&junk);
    assert!(matches!(timeout(WAIT, events.next()).await.unwrap(), Err(UsbMuxError::Protocol(_))));

    // Unknown messages and unreadable events are skipped, split across writes.
    let mut events = mux.client().listen().await.unwrap();
    let mut paired = plist::Dictionary::new();
    paired.insert("MessageType".into(), "Paired".into());
    paired.insert("DeviceID".into(), 5u64.into());
    let paired = protocol::Packet::new(0, paired).encode().unwrap();
    mux.inject(&paired[..10]);
    mux.inject(&paired[10..]);
    mux.attach(FakeDevice::usb(5, "IPAD"));
    assert_eq!(next(&mut events).await, Some(UsbMuxEvent::Attached(fake_device(5, "IPAD"))));
}

/// A hand-rolled daemon that answers the first request on each connection with `answer`.
async fn scripted_daemon(answer: Vec<u8>) -> (tempfile::TempDir, UsbMuxClient) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("usbmuxd");
    let listener = UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        while let Ok((mut c, _)) = listener.accept().await {
            let answer = answer.clone();
            tokio::spawn(async move {
                let mut header = [0u8; 16];
                c.read_exact(&mut header).await.unwrap();
                let len = u32::from_le_bytes(header[..4].try_into().unwrap()) as usize;
                let mut body = vec![0; len - 16];
                c.read_exact(&mut body).await.unwrap();
                c.write_all(&answer).await.unwrap();
                // Hold the connection until the client goes.
                let _ = c.read(&mut [0u8; 1]).await;
            });
        }
    });
    (dir, UsbMuxClient::new(path).with_timeout(Duration::from_millis(300)))
}

#[tokio::test]
async fn malformed_replies_are_errors() {
    // Not a Result.
    let (_d, client) = scripted_daemon(protocol::listen(1).encode().unwrap()).await;
    assert!(matches!(client.connect(5, 47800).await, Err(UsbMuxError::Protocol(_))));
    assert!(matches!(client.listen().await, Err(UsbMuxError::Protocol(_))));

    // A Listen refused.
    let (_d, client) = scripted_daemon(protocol::result_packet(1, result::BAD_VERSION).encode().unwrap()).await;
    assert!(matches!(client.listen().await, Err(UsbMuxError::Result(result::BAD_VERSION))));
    assert!(matches!(client.list_devices().await, Err(UsbMuxError::Result(result::BAD_VERSION))));

    // A header announcing a body larger than allowed.
    let mut huge = protocol::result_packet(1, 0).encode().unwrap();
    huge[..4].copy_from_slice(&(16 + (1u32 << 20) + 1).to_le_bytes());
    let (_d, client) = scripted_daemon(huge).await;
    assert!(matches!(client.connect(5, 47800).await, Err(UsbMuxError::Protocol(_))));

    // A truncated reply, then silence: the timeout.
    let (_d, client) = scripted_daemon(vec![0x30, 0, 0, 0]).await;
    assert!(matches!(client.connect(5, 47800).await, Err(UsbMuxError::Timeout(_))));
    assert!(matches!(client.listen().await, Err(UsbMuxError::Timeout(_))));
}

#[tokio::test]
async fn connect_leaves_the_devices_first_bytes_in_the_pipe() {
    // The Result and the device's first bytes arrive in one write; the pipe must still start with the latter.
    let mut answer = protocol::result_packet(1, 0).encode().unwrap();
    answer.extend_from_slice(b"early");
    let (_d, client) = scripted_daemon(answer).await;
    let mut pipe = client.connect(5, 47800).await.unwrap();
    let mut buf = [0u8; 5];
    pipe.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"early");
}

#[tokio::test]
async fn next_is_cancel_safe() {
    let mux = FakeUsbMuxd::start(vec![], FakeTarget::Tcp(dead_address().await)).unwrap();
    let mut events = mux.client().listen().await.unwrap();
    let mut props = plist::Dictionary::new();
    props.insert("ConnectionType".into(), "USB".into());
    props.insert("SerialNumber".into(), "IPAD8".into());
    let mut attached = plist::Dictionary::new();
    attached.insert("MessageType".into(), "Attached".into());
    attached.insert("DeviceID".into(), 8u64.into());
    attached.insert("Properties".into(), props.into());
    let full = protocol::Packet::new(0, attached).encode().unwrap();
    // Half a packet, a read cancelled by its timeout, then the rest.
    mux.inject(&full[..20]);
    assert!(timeout(Duration::from_millis(100), events.next()).await.is_err());
    mux.inject(&full[20..]);
    assert_eq!(next(&mut events).await, Some(UsbMuxEvent::Attached(UsbMuxDevice::new(8, "IPAD8"))));
}
