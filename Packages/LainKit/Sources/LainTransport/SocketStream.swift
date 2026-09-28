import Darwin
import Dispatch
import Synchronization

/// A connected stream socket (TCP, or a usbmuxd pipe on the Mac). Reads come from a dispatch read
/// source on the receive queue; writes run in order on a private send queue.
public final class SocketStream: ByteStream {
    public let fd: Int32
    private let sendQueue: DispatchQueue

    private struct State {
        var started = false
        var closed = false
        var source: (any DispatchSourceRead)?
        var queue: DispatchQueue?
        var onClose: (@Sendable ((any Error)?) -> Void)?
    }
    private let state = Mutex(State())

    public init(fd: Int32, label: String = "lain.socket") {
        self.fd = fd
        sendQueue = DispatchQueue(label: label + ".send", qos: .userInteractive)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// TCP_NODELAY (§7.1: set on the iPad side of the realtime connection). No-op on Unix sockets.
    public func setNoDelay() {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Keeps the kernel send buffer small so frames don't pile up below the app (§7.3).
    public func setSendBufferSize(_ bytes: Int) {
        var n = Int32(bytes)
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &n, socklen_t(MemoryLayout<Int32>.size))
    }

    public var sendBufferSize: Int {
        var n: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &n, &len)
        return Int(n)
    }

    public func start(queue: DispatchQueue, onBytes: @escaping @Sendable ([UInt8]) -> Void,
                      onClose: @escaping @Sendable ((any Error)?) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let buffer = ReadBuffer(size: 256 * 1024)
        let fd = fd
        source.setEventHandler { [weak self] in
            while true {
                let n = Darwin.recv(fd, buffer.base, buffer.size, MSG_DONTWAIT)
                if n > 0 {
                    onBytes(Array(UnsafeRawBufferPointer(start: buffer.base, count: n)))
                    if n < buffer.size { return }
                } else if n == 0 {
                    self?.finish(nil)
                    return
                } else {
                    let e = errno
                    if e == EINTR { continue }
                    if e != EAGAIN && e != EWOULDBLOCK { self?.finish(TransportError.posix("recv", e)) }
                    return
                }
            }
        }
        source.setCancelHandler { [sendQueue] in
            buffer.free()
            sendQueue.async { Darwin.close(fd) }   // after any queued writes
        }
        let alreadyClosed = state.withLock { s in
            precondition(!s.started, "SocketStream.start called twice")
            s.started = true
            guard !s.closed else { return true }
            s.source = source
            s.queue = queue
            s.onClose = onClose
            return false
        }
        if alreadyClosed {
            queue.async { onClose(TransportError.closed) }
            return
        }
        source.activate()
    }

    public func write(_ bytes: [UInt8]) {
        sendQueue.async { [self] in
            guard !state.withLock({ $0.closed }) else { return }
            var offset = 0
            let failure: Int32? = bytes.withUnsafeBytes { p in
                while offset < p.count {
                    let n = Darwin.send(fd, p.baseAddress! + offset, p.count - offset, 0)
                    if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return errno }
                }
                return nil
            }
            if let failure { finish(TransportError.posix("send", failure)) }
        }
    }

    public func close() {
        sendQueue.async { [self] in finish(nil) }
    }

    private func finish(_ error: (any Error)?) {
        let taken = state.withLock { s -> (source: (any DispatchSourceRead)?, queue: DispatchQueue?,
                                           onClose: (@Sendable ((any Error)?) -> Void)?, started: Bool)? in
            guard !s.closed else { return nil }
            s.closed = true
            defer { s.source = nil; s.onClose = nil }
            return (s.source, s.queue, s.onClose, s.started)
        }
        // Only the first finish touches the descriptor: once closed, its number may already belong to
        // another socket.
        guard let (source, queue, onClose, started) = taken else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        if let source {
            source.cancel()
        } else if !started {
            sendQueue.async { [fd] in Darwin.close(fd) }
        }
        if let onClose, let queue { queue.async { onClose(error) } }
    }

    deinit {
        // A stream dropped without close still releases its descriptor.
        let (started, closed) = state.withLock { ($0.started, $0.closed) }
        if !started && !closed { Darwin.close(fd) }
    }
}

/// A receive buffer owned by one read source; freed in its cancel handler.
private final class ReadBuffer: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let size: Int
    init(size: Int) {
        self.size = size
        base = .allocate(byteCount: size, alignment: 16)
    }
    func free() { base.deallocate() }
}

// MARK: - TCP

public enum TCP {
    /// Connects to 127.0.0.1:`port` (blocking; loopback connects immediately).
    public static func connectLoopback(port: UInt16) throws(TransportError) -> SocketStream {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .posix("socket", errno) }
        var addr = loopbackAddress(port: port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw .posix("connect", e)
        }
        return SocketStream(fd: fd)
    }

    static func loopbackAddress(port: UInt16) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        return addr
    }
}

/// Listens on 127.0.0.1 only (§7.2: no Local Network prompt on the iPad).
public final class TCPListener: Sendable {
    public let port: UInt16
    private let source: any DispatchSourceRead

    /// `port` 0 picks an ephemeral port (tests).
    public init(port: UInt16, queue: DispatchQueue, onAccept: @escaping @Sendable (SocketStream) -> Void) throws(TransportError) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .posix("socket", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = TCP.loopbackAddress(port: port)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw .posix("bind/listen \(port)", e)
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.port = UInt16(bigEndian: actual.sin_port)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                // Accepted sockets inherit O_NONBLOCK on Darwin; streams expect blocking writes.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                onAccept(SocketStream(fd: client, label: "lain.accepted"))
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.activate()
    }

    public func cancel() { source.cancel() }
}
