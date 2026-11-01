//! A stand-in for usbmuxd: the same plist protocol on a Unix socket in a temporary directory, with `Connect`
//! bridged to a TCP port or handed to the test, so the USB path runs end to end without an iPad.
//!
//! Mirrors Swift's `FakeUSBMuxd` (`LainTestSupport/FakeUSBMuxd.swift`). Intended differences, each for tests
//! of the Linux host:
//! - [`FakeTarget::Handoff`] gives the daemon's end of a connected pipe to the test instead of bridging to TCP.
//! - `ListDevices` is answered, with every device (USB or not), as both real daemons do.
//! - A `Connect` without `PortNumber` gets `Result` 1, as libimobiledevice answers it (Swift's fake: 3).
//! - [`FakeUsbMuxd::exit`] and [`FakeUsbMuxd::relaunch`] model libimobiledevice's daemon exiting when the last
//!   device goes and udev starting it again: while it's gone, the socket file stays but refuses connections.
//! - [`FakeUsbMuxd::detach`] closes that device's `Connect` pipes, as libimobiledevice's `device_remove()` tears
//!   down every connection of the removed device; [`FakeUsbMuxd::exit`] and [`FakeUsbMuxd::stop`] close them all.
//! - [`FakeUsbMuxd::inject`] writes raw bytes to every listener, for malformed-packet tests.
//! - A new listener's `Result` and initial `Attached`s are queued under the same lock that registers it, so an
//!   `attach` racing a `Listen` is never lost or reported twice.

use std::io;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::task::Poll;

use plist::{Dictionary, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpStream, UnixListener, UnixStream};
use tokio::sync::mpsc;
use tokio::task::AbortHandle;

use crate::protocol::{self, HEADER_SIZE, Packet, result};

/// A device the fake reports (Swift: `FakeUSBMuxd.Device`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FakeDevice {
    pub device_id: u32,
    pub serial_number: String,
    /// `"USB"`, or e.g. `"Network"` (which the client filters out).
    pub connection_type: String,
    /// false: `Connect` is refused, as on a device without lain running (an iPhone, say).
    pub accepts_connect: bool,
}

impl FakeDevice {
    /// A USB device that accepts connections.
    pub fn usb(device_id: u32, serial_number: impl Into<String>) -> Self {
        Self { device_id, serial_number: serial_number.into(), connection_type: "USB".into(), accepts_connect: true }
    }

    /// A network attachment, as Apple's daemon reports Wi-Fi sync devices.
    pub fn network(device_id: u32, serial_number: impl Into<String>) -> Self {
        Self { connection_type: "Network".into(), ..Self::usb(device_id, serial_number) }
    }

    /// The same device, refusing every `Connect`.
    pub fn refusing(self) -> Self {
        Self { accepts_connect: false, ..self }
    }
}

/// Where a successful `Connect` goes.
#[derive(Debug, Clone)]
pub enum FakeTarget {
    /// Bridged to this TCP address, like Swift's `targetPort` on 127.0.0.1. Nothing listening there means
    /// `Result` 3.
    Tcp(SocketAddr),
    /// Handed to the test: after `Result` 0 a stream bridged to the client's socket is sent here. A closed
    /// receiver means `Result` 3.
    Handoff(mpsc::UnboundedSender<FakeConnection>),
}

/// A connection the fake accepted, for [`FakeTarget::Handoff`]. Bytes written to `stream` reach the client's
/// socket, and the reverse.
#[derive(Debug)]
pub struct FakeConnection {
    pub device_id: u32,
    /// The port the client asked for, in host order.
    pub port: u16,
    pub stream: UnixStream,
}

enum ListenerMessage {
    Bytes(Vec<u8>),
    Close,
}

struct Listener {
    id: u64,
    tx: mpsc::UnboundedSender<ListenerMessage>,
}

/// A `Connect` pipe: the task bridging the client's socket to its target, which owns both ends.
struct Pipe {
    device_id: u32,
    task: AbortHandle,
}

struct State {
    devices: Vec<FakeDevice>,
    listeners: Vec<Listener>,
    next_listener: u64,
    connects: usize,
    /// Client connections being served (a request, or a `Listen`).
    tasks: Vec<AbortHandle>,
    pipes: Vec<Pipe>,
    /// The daemon's socket while it runs. Dropped under the lock, so a connect after `exit` is refused at once.
    listener: Option<UnixListener>,
    /// Counts binds; tasks of an earlier run neither accept nor open pipes.
    generation: u64,
    accept_task: Option<AbortHandle>,
    stopped: bool,
}

impl State {
    fn running(&self, generation: u64) -> bool {
        self.listener.is_some() && self.generation == generation
    }

    /// The daemon going away: the socket refuses connections and every connection it had ends.
    fn shut_down(&mut self) {
        self.listener = None;
        close_listeners(self);
        if let Some(task) = self.accept_task.take() {
            task.abort();
        }
        for task in self.tasks.drain(..) {
            task.abort();
        }
        for pipe in self.pipes.drain(..) {
            pipe.task.abort();
        }
    }
}

struct Inner {
    state: Mutex<State>,
    target: FakeTarget,
    expected_port: u16,
    socket_path: PathBuf,
}

impl Inner {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// A fake usbmuxd (Swift: `FakeUSBMuxd`). Must be created inside a tokio runtime; its tasks end with
/// [`FakeUsbMuxd::stop`] or when it's dropped.
pub struct FakeUsbMuxd {
    inner: Arc<Inner>,
    _dir: tempfile::TempDir,
}

impl std::fmt::Debug for FakeUsbMuxd {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FakeUsbMuxd").field("socket_path", &self.inner.socket_path).finish_non_exhaustive()
    }
}

impl FakeUsbMuxd {
    /// Starts a fake whose `Connect` must ask for port 47800 (lain's USB port).
    pub fn start(devices: Vec<FakeDevice>, target: FakeTarget) -> io::Result<Self> {
        Self::start_expecting(devices, target, 47800)
    }

    /// Starts a fake whose `Connect` must ask for `expected_port` (Swift: `expectedPort`); any other port is
    /// refused with `Result` 3.
    pub fn start_expecting(devices: Vec<FakeDevice>, target: FakeTarget, expected_port: u16) -> io::Result<Self> {
        let dir = tempfile::Builder::new().prefix("lain-fakemux").tempdir()?;
        let socket_path = dir.path().join("usbmuxd");
        let inner = Arc::new(Inner {
            state: Mutex::new(State {
                devices,
                listeners: Vec::new(),
                next_listener: 0,
                connects: 0,
                tasks: Vec::new(),
                pipes: Vec::new(),
                listener: None,
                generation: 0,
                accept_task: None,
                stopped: false,
            }),
            target,
            expected_port,
            socket_path,
        });
        bind(&inner)?;
        Ok(Self { inner, _dir: dir })
    }

    /// The socket to give [`crate::UsbMuxClient::new`].
    pub fn socket_path(&self) -> &Path {
        &self.inner.socket_path
    }

    /// A client for this fake.
    pub fn client(&self) -> crate::UsbMuxClient {
        crate::UsbMuxClient::new(self.socket_path())
    }

    /// Successful `Connect`s so far (Swift: `connectCount`).
    pub fn connect_count(&self) -> usize {
        self.inner.lock().connects
    }

    /// Adds a device and tells every listener (Swift: `attach`).
    pub fn attach(&self, device: FakeDevice) {
        let mut s = self.inner.lock();
        let bytes = encode(&attached_packet(&device));
        s.devices.retain(|d| d.device_id != device.device_id);
        s.devices.push(device);
        broadcast(&mut s, &bytes);
    }

    /// Removes a device, closes its `Connect` pipes and tells every listener (Swift: `detach`, which leaves the
    /// pipes open).
    pub fn detach(&self, device_id: u32) {
        let mut s = self.inner.lock();
        s.devices.retain(|d| d.device_id != device_id);
        s.pipes.retain(|p| {
            if p.device_id == device_id {
                p.task.abort();
            }
            p.device_id != device_id
        });
        let mut d = Dictionary::new();
        d.insert("MessageType".into(), "Detached".into());
        d.insert("DeviceID".into(), u64::from(device_id).into());
        broadcast(&mut s, &encode(&Packet::new(0, d)));
    }

    /// Writes raw bytes to every listener, for malformed-packet tests.
    pub fn inject(&self, bytes: &[u8]) {
        broadcast(&mut self.inner.lock(), bytes);
    }

    /// The daemon restarting, as its clients see it: every `Listen` connection is dropped (their event streams
    /// end), and a client that listens again gets the attached devices reported afresh (Swift: `restart`).
    pub fn restart(&self) {
        close_listeners(&mut self.inner.lock());
    }

    /// libimobiledevice's daemon exiting (after the last device is detached, with `--enable-exit`): every
    /// connection ends (listeners and `Connect` pipes alike), and from the moment this returns new connections
    /// are refused, while the socket file stays behind, as the real one leaves it. The devices are kept, for
    /// [`FakeUsbMuxd::relaunch`].
    pub fn exit(&self) {
        self.inner.lock().shut_down();
    }

    /// Starts accepting again after [`FakeUsbMuxd::exit`] (udev starting the daemon for a new device).
    pub fn relaunch(&self) -> io::Result<()> {
        bind(&self.inner)
    }

    /// Stops everything, for good: the accept loop, every listener and every `Connect` pipe.
    pub fn stop(&self) {
        let mut s = self.inner.lock();
        s.stopped = true;
        s.shut_down();
    }
}

impl Drop for FakeUsbMuxd {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Binds the socket and starts accepting, unless the fake is running or stopped.
fn bind(inner: &Arc<Inner>) -> io::Result<()> {
    let mut s = inner.lock();
    if s.stopped || s.listener.is_some() {
        return Ok(());
    }
    let _ = std::fs::remove_file(&inner.socket_path);
    s.listener = Some(UnixListener::bind(&inner.socket_path)?);
    s.generation += 1;
    let task = tokio::spawn(accept_loop(Arc::clone(inner), s.generation));
    s.accept_task = Some(task.abort_handle());
    Ok(())
}

/// Serves an accepted connection, unless the run that accepted it has ended (the stream is then dropped).
fn spawn(inner: &Arc<Inner>, generation: u64, f: impl Future<Output = ()> + Send + 'static) {
    let mut s = inner.lock();
    if !s.running(generation) {
        return;
    }
    s.tasks.retain(|t| !t.is_finished());
    let task = tokio::spawn(f);
    s.tasks.push(task.abort_handle());
}

/// Starts a `Connect` pipe for `device_id`, unless the device went or the daemon ended meanwhile (`bridge`, and
/// with it the client's socket, is then dropped). Returns whether it started.
fn open_pipe(
    inner: &Inner,
    generation: u64,
    device_id: u32,
    bridge: impl Future<Output = ()> + Send + 'static,
) -> bool {
    let mut s = inner.lock();
    s.connects += 1;
    if !s.running(generation) || !s.devices.iter().any(|d| d.device_id == device_id) {
        return false;
    }
    s.pipes.retain(|p| !p.task.is_finished());
    let task = tokio::spawn(bridge);
    s.pipes.push(Pipe { device_id, task: task.abort_handle() });
    true
}

fn encode(packet: &Packet) -> Vec<u8> {
    packet.encode().expect("the fake's packets encode")
}

fn broadcast(s: &mut State, bytes: &[u8]) {
    s.listeners.retain(|l| l.tx.send(ListenerMessage::Bytes(bytes.to_vec())).is_ok());
}

fn close_listeners(s: &mut State) {
    for l in s.listeners.drain(..) {
        let _ = l.tx.send(ListenerMessage::Close);
    }
}

/// An `Attached` event in Apple's shape (Swift: `attachedPacket`, with the same ProductID and speed).
fn attached_packet(d: &FakeDevice) -> Packet {
    Packet::new(0, attached_dictionary(d))
}

fn attached_dictionary(d: &FakeDevice) -> Dictionary {
    let mut props = Dictionary::new();
    props.insert("ConnectionType".into(), d.connection_type.as_str().into());
    props.insert("DeviceID".into(), u64::from(d.device_id).into());
    props.insert("SerialNumber".into(), d.serial_number.as_str().into());
    props.insert("ProductID".into(), 4779u64.into());
    props.insert("ConnectionSpeed".into(), 480_000_000u64.into());
    let mut out = Dictionary::new();
    out.insert("MessageType".into(), "Attached".into());
    out.insert("DeviceID".into(), u64::from(d.device_id).into());
    out.insert("Properties".into(), props.into());
    out
}

/// Accepts on the listener in the fake's state, so that `exit` can close it synchronously; ends when it's gone.
async fn accept_loop(inner: Arc<Inner>, generation: u64) {
    loop {
        let accepted = std::future::poll_fn(|cx| {
            let s = inner.lock();
            match &s.listener {
                Some(listener) if s.generation == generation => listener.poll_accept(cx).map(Some),
                _ => Poll::Ready(None),
            }
        })
        .await;
        let Some(Ok((stream, _))) = accepted else { return };
        spawn(&inner, generation, serve(Arc::clone(&inner), generation, stream));
    }
}

async fn read_request(stream: &mut UnixStream) -> Option<Packet> {
    let mut header = [0u8; HEADER_SIZE];
    stream.read_exact(&mut header).await.ok()?;
    let header = protocol::decode_header(&header).ok()?;
    let mut body = vec![0; header.body_length];
    stream.read_exact(&mut body).await.ok()?;
    Packet::decode_body(&body, header.tag).ok()
}

async fn reply(stream: &mut UnixStream, tag: u32, number: u64) {
    let _ = stream.write_all(&encode(&protocol::result_packet(tag, number))).await;
}

/// One client connection: one request, then a listener, a pipe or a close.
async fn serve(inner: Arc<Inner>, generation: u64, mut stream: UnixStream) {
    // A malformed request just closes the connection, as in Swift's fake.
    let Some(request) = read_request(&mut stream).await else { return };
    let tag = request.tag;
    match request.message_type() {
        Some("Listen") => listen(inner, stream, tag).await,
        Some("Connect") => connect(inner, generation, stream, &request).await,
        Some("ListDevices") => {
            let list: Vec<Value> = inner.lock().devices.iter().map(|d| attached_dictionary(d).into()).collect();
            let mut d = Dictionary::new();
            d.insert("DeviceList".into(), list.into());
            let _ = stream.write_all(&encode(&Packet::new(tag, d))).await;
        }
        _ => reply(&mut stream, tag, result::BAD_COMMAND).await,
    }
}

async fn listen(inner: Arc<Inner>, mut stream: UnixStream, tag: u32) {
    let (tx, mut rx) = mpsc::unbounded_channel();
    let id = {
        let mut s = inner.lock();
        let _ = tx.send(ListenerMessage::Bytes(encode(&protocol::result_packet(tag, result::OK))));
        for d in &s.devices {
            let _ = tx.send(ListenerMessage::Bytes(encode(&attached_packet(d))));
        }
        let id = s.next_listener;
        s.next_listener += 1;
        s.listeners.push(Listener { id, tx });
        id
    };
    let (mut read, mut write) = stream.split();
    let mut scratch = [0u8; 64];
    loop {
        tokio::select! {
            message = rx.recv() => match message {
                Some(ListenerMessage::Bytes(bytes)) => {
                    if write.write_all(&bytes).await.is_err() {
                        break;
                    }
                }
                Some(ListenerMessage::Close) | None => break,
            },
            // Hold the socket open for later events until the client goes away.
            n = read.read(&mut scratch) => if !matches!(n, Ok(n) if n > 0) { break },
        }
    }
    inner.lock().listeners.retain(|l| l.id != id);
}

async fn connect(inner: Arc<Inner>, generation: u64, mut stream: UnixStream, request: &Packet) {
    let tag = request.tag;
    let Some(device_id) = request.unsigned("DeviceID").and_then(|id| u32::try_from(id).ok()) else {
        return reply(&mut stream, tag, result::BAD_DEVICE).await;
    };
    // libimobiledevice: `ntohs((uint16_t)PortNumber)`.
    let Some(port) = request.unsigned("PortNumber").map(|p| u16::from_be(p as u16)) else {
        return reply(&mut stream, tag, result::BAD_COMMAND).await;
    };
    let device = inner.lock().devices.iter().find(|d| d.device_id == device_id).cloned();
    let Some(device) = device else { return reply(&mut stream, tag, result::BAD_DEVICE).await };
    if !device.accepts_connect || port != inner.expected_port {
        return reply(&mut stream, tag, result::CONNECTION_REFUSED).await;
    }
    match &inner.target {
        FakeTarget::Tcp(addr) => {
            let Ok(upstream) = TcpStream::connect(addr).await else {
                return reply(&mut stream, tag, result::CONNECTION_REFUSED).await;
            };
            reply(&mut stream, tag, result::OK).await;
            open_pipe(&inner, generation, device_id, splice(stream, upstream));
        }
        FakeTarget::Handoff(tx) => {
            // The test's end is bridged rather than the client's socket itself, so the fake can close it.
            if tx.is_closed() {
                return reply(&mut stream, tag, result::CONNECTION_REFUSED).await;
            }
            let Ok((near, far)) = UnixStream::pair() else {
                return reply(&mut stream, tag, result::CONNECTION_REFUSED).await;
            };
            reply(&mut stream, tag, result::OK).await;
            if open_pipe(&inner, generation, device_id, splice(stream, near)) {
                let _ = tx.send(FakeConnection { device_id, port, stream: far });
            }
        }
    }
}

/// Copies bytes both ways until either side closes, then closes both, like Swift's fake.
async fn splice(a: impl AsyncRead + AsyncWrite + Send, b: impl AsyncRead + AsyncWrite + Send) {
    let (mut ar, mut aw) = tokio::io::split(a);
    let (mut br, mut bw) = tokio::io::split(b);
    tokio::select! {
        _ = tokio::io::copy(&mut ar, &mut bw) => {}
        _ = tokio::io::copy(&mut br, &mut aw) => {}
    }
    let _ = aw.shutdown().await;
    let _ = bw.shutdown().await;
}
