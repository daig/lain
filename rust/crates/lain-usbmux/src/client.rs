use std::collections::HashSet;
use std::io;
use std::path::PathBuf;
use std::time::Duration;

use bytes::{Buf, BytesMut};
use plist::Value;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

use crate::protocol::{self, HEADER_SIZE, Packet};
use crate::{UsbMuxDevice, UsbMuxError, UsbMuxEvent};

/// Where usbmuxd listens, on macOS and with libimobiledevice alike (Swift: `USBMuxClient.defaultSocketPath`;
/// libimobiledevice: `USBMUXD_SOCKET_FILE`).
pub const DEFAULT_SOCKET_PATH: &str = "/var/run/usbmuxd";

/// The tag lain puts on every request; each request has its own socket, so one tag is enough (as in Swift).
const TAG: u32 = 1;

/// A client for usbmuxd (Swift: `USBMuxClient`). Each call opens its own socket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsbMuxClient {
    pub socket_path: PathBuf,
    /// How long to wait for the daemon's reply to a request (Swift: `timeoutSeconds`, 5 s). After a successful
    /// `Connect` no timeout applies. It matters on Linux: libimobiledevice's daemon has no timer of its own
    /// for a device that never answers the connection's SYN.
    pub timeout: Duration,
}

impl Default for UsbMuxClient {
    fn default() -> Self {
        Self::new(DEFAULT_SOCKET_PATH)
    }
}

impl UsbMuxClient {
    pub fn new(socket_path: impl Into<PathBuf>) -> Self {
        Self { socket_path: socket_path.into(), timeout: Duration::from_secs(5) }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    /// Connects to TCP `port` on the device. After the daemon's `Result` of 0 the returned socket is a raw pipe
    /// to that port, owned by the caller (Swift: `connect(deviceID:port:)`, which returns a file descriptor). A
    /// non-zero result is [`UsbMuxError::Result`]: 2 for an unknown device, 3 when nothing listens on the port.
    pub async fn connect(&self, device_id: u32, port: u16) -> Result<UnixStream, UsbMuxError> {
        let exchange = async {
            let mut stream = self.open().await?;
            send(&mut stream, &protocol::connect(TAG, device_id, port)).await?;
            // Read exactly one packet: anything after it is the device's data, which belongs to the caller.
            let reply = read_one(&mut stream).await?;
            expect_ok(&reply, "connect")?;
            Ok(stream)
        };
        self.within(exchange).await
    }

    /// The USB devices attached now, from `ListDevices`. Network attachments are left out, as in
    /// [`UsbMuxClient::listen`]. Swift's client has no such call.
    pub async fn list_devices(&self) -> Result<Vec<UsbMuxDevice>, UsbMuxError> {
        let exchange = async {
            let mut stream = self.open().await?;
            send(&mut stream, &protocol::list_devices(TAG)).await?;
            let reply = read_one(&mut stream).await?;
            if reply.message_type() == Some("Result") {
                // A daemon that doesn't know the command answers with a Result instead.
                let n = reply.unsigned("Number").unwrap_or(protocol::result::BAD_COMMAND);
                return Err(UsbMuxError::Result(n));
            }
            let list = reply
                .plist
                .get("DeviceList")
                .and_then(Value::as_array)
                .ok_or_else(|| UsbMuxError::Protocol("list devices: no DeviceList".into()))?;
            Ok(list
                .iter()
                .filter_map(Value::as_dictionary)
                .filter_map(UsbMuxDevice::from_attached)
                .filter_map(|(device, is_usb)| is_usb.then_some(device))
                .collect())
        };
        self.within(exchange).await
    }

    /// Starts listening for attach and detach events. Returns once the daemon has accepted the `Listen`; the
    /// devices already attached are then reported first (Swift: `events()`).
    ///
    /// Intended difference: Swift's `events()` returns its stream at once and delivers a failure to connect or
    /// a refused `Listen` through it; here those are this call's error, and the wait for the `Listen` reply is
    /// bounded by [`UsbMuxClient::timeout`] (Swift has no timeout there).
    pub async fn listen(&self) -> Result<UsbMuxEvents, UsbMuxError> {
        let exchange = async {
            let mut stream = self.open().await?;
            send(&mut stream, &protocol::listen(TAG)).await?;
            let mut reader = PacketReader::default();
            let ack = reader.read(&mut stream).await?;
            expect_ok(&ack, "listen")?;
            Ok(UsbMuxEvents { stream, reader, usb_devices: HashSet::new() })
        };
        self.within(exchange).await
    }

    async fn open(&self) -> Result<UnixStream, UsbMuxError> {
        UnixStream::connect(&self.socket_path)
            .await
            .map_err(|source| UsbMuxError::Unavailable { path: self.socket_path.clone(), source })
    }

    async fn within<T>(&self, f: impl Future<Output = Result<T, UsbMuxError>>) -> Result<T, UsbMuxError> {
        tokio::time::timeout(self.timeout, f).await.unwrap_or(Err(UsbMuxError::Timeout(self.timeout)))
    }
}

/// Requires `reply` to be a `Result` of 0 (Swift: the checks after each request).
fn expect_ok(reply: &Packet, what: &str) -> Result<(), UsbMuxError> {
    let number = match reply.message_type() {
        Some("Result") => reply.unsigned("Number"),
        _ => None,
    };
    match number {
        Some(protocol::result::OK) => Ok(()),
        Some(n) => Err(UsbMuxError::Result(n)),
        None => Err(UsbMuxError::Protocol(format!("{what}: unexpected {}", reply.message_type().unwrap_or("?")))),
    }
}

async fn send(stream: &mut UnixStream, packet: &Packet) -> Result<(), UsbMuxError> {
    let bytes = packet.encode()?;
    stream.write_all(&bytes).await.map_err(|e| UsbMuxError::io("send", e))
}

/// An end of stream is [`UsbMuxError::Closed`], wherever it falls (Swift: `readExactly`).
fn read_error(e: io::Error) -> UsbMuxError {
    match e.kind() {
        io::ErrorKind::UnexpectedEof | io::ErrorKind::NotConnected => UsbMuxError::Closed,
        _ => UsbMuxError::io("recv", e),
    }
}

/// Reads exactly one packet and nothing past it.
async fn read_one(stream: &mut (impl AsyncRead + Unpin)) -> Result<Packet, UsbMuxError> {
    let mut header = [0u8; HEADER_SIZE];
    stream.read_exact(&mut header).await.map_err(read_error)?;
    let header = protocol::decode_header(&header)?;
    let mut body = vec![0; header.body_length];
    stream.read_exact(&mut body).await.map_err(read_error)?;
    Packet::decode_body(&body, header.tag)
}

/// Buffers a packet stream so that reading is cancel-safe: a `read` dropped mid-packet loses nothing.
#[derive(Debug, Default)]
struct PacketReader {
    buffer: BytesMut,
}

impl PacketReader {
    /// The next packet. A malformed header fails as soon as its 16 bytes are in.
    async fn read(&mut self, stream: &mut (impl AsyncRead + Unpin)) -> Result<Packet, UsbMuxError> {
        loop {
            if let Some(packet) = self.parse()? {
                return Ok(packet);
            }
            if stream.read_buf(&mut self.buffer).await.map_err(read_error)? == 0 {
                return Err(UsbMuxError::Closed);
            }
        }
    }

    fn parse(&mut self) -> Result<Option<Packet>, UsbMuxError> {
        let Some(header) = self.buffer.first_chunk::<HEADER_SIZE>() else { return Ok(None) };
        let header = protocol::decode_header(header)?;
        if self.buffer.len() < HEADER_SIZE + header.body_length {
            self.buffer.reserve(HEADER_SIZE + header.body_length - self.buffer.len());
            return Ok(None);
        }
        self.buffer.advance(HEADER_SIZE);
        let body = self.buffer.split_to(header.body_length);
        Packet::decode_body(&body, header.tag).map(Some)
    }
}

/// The attach and detach events of one `Listen` connection (Swift: the stream `events()` returns). Dropping
/// it closes the socket.
///
/// Only USB devices are reported: an attachment whose `ConnectionType` isn't `"USB"` is skipped, and so is a
/// `Detached` for any device this stream hasn't reported, as in Swift. Other messages are skipped too.
#[derive(Debug)]
pub struct UsbMuxEvents {
    stream: UnixStream,
    reader: PacketReader,
    usb_devices: HashSet<u32>,
}

impl UsbMuxEvents {
    /// The next event. `Ok(None)` means the daemon closed the connection (it exited or restarted; Swift ends
    /// the stream without an error then); the caller listens again to have the attached devices replayed. A
    /// malformed packet is an error, after which the stream is unusable. Cancel-safe.
    pub async fn next(&mut self) -> Result<Option<UsbMuxEvent>, UsbMuxError> {
        loop {
            let packet = match self.reader.read(&mut self.stream).await {
                Ok(p) => p,
                Err(UsbMuxError::Closed) => return Ok(None),
                Err(e) => return Err(e),
            };
            let Some((event, is_usb)) = UsbMuxEvent::from_packet(&packet) else {
                tracing::debug!(message_type = packet.message_type(), "usbmuxd: skipped a packet");
                continue;
            };
            match &event {
                UsbMuxEvent::Attached(d) if is_usb => {
                    self.usb_devices.insert(d.device_id);
                }
                UsbMuxEvent::Detached { device_id } if self.usb_devices.remove(device_id) => {}
                _ => continue,
            }
            return Ok(Some(event));
        }
    }
}
