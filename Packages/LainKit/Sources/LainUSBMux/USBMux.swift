#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// Client for `/var/run/usbmuxd` (§7.2). Each `connect` opens its own socket; after a `Result` of 0
/// the socket is a raw pipe to the device's TCP port.
public struct USBMuxClient: Sendable {
    public static let defaultSocketPath = "/var/run/usbmuxd"
    public var socketPath: String
    /// How long to wait for the daemon's `Result`.
    public var timeoutSeconds: Int

    public init(socketPath: String = USBMuxClient.defaultSocketPath, timeoutSeconds: Int = 5) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
    }

    /// Connects to `port` on the device. Returns a connected, blocking file descriptor the caller owns.
    public func connect(deviceID: Int, port: UInt16) async throws(USBMuxError) -> Int32 {
        let result: Result<Int32, USBMuxError> = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Result { () throws(USBMuxError) -> Int32 in try connectBlocking(deviceID: deviceID, port: port) })
            }
        }
        return try result.get()
    }

    func connectBlocking(deviceID: Int, port: UInt16) throws(USBMuxError) -> Int32 {
        let fd = try PosixIO.connectUnix(socketPath)
        do throws(USBMuxError) {
            PosixIO.setReceiveTimeout(fd, seconds: timeoutSeconds)
            try PosixIO.writeAll(fd, try encode(USBMuxProtocol.connect(tag: 1, deviceID: deviceID, port: port)))
            let reply = try readPacket(fd)
            guard reply.messageType == "Result", let n = reply.plist["Number"] as? Int else {
                throw USBMuxError.protocolError("unexpected \(reply.messageType ?? "?")")
            }
            guard n == 0 else { throw USBMuxError.result(n) }
            PosixIO.setReceiveTimeout(fd, seconds: 0)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    /// Attach/detach events for USB devices. The daemon reports already-attached devices first.
    /// Cancelling the consuming task closes the socket.
    public func events() -> AsyncThrowingStream<USBMuxEvent, any Error> {
        AsyncThrowingStream { continuation in
            let fdBox = Mutex<Int32>(-1)
            continuation.onTermination = { _ in
                fdBox.withLock { fd in if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) } }
            }
            let path = socketPath
            Thread.detachNewThread {
                var usbDevices = Set<Int>()
                do throws(USBMuxError) {
                    let fd = try PosixIO.connectUnix(path)
                    fdBox.withLock { $0 = fd }
                    defer {
                        fdBox.withLock { $0 = -1 }
                        Darwin.close(fd)
                    }
                    try PosixIO.writeAll(fd, try encode(USBMuxProtocol.listen(tag: 1)))
                    let ack = try readPacket(fd)
                    guard ack.messageType == "Result", let n = ack.plist["Number"] as? Int else {
                        throw .protocolError("listen: \(ack.messageType ?? "?")")
                    }
                    guard n == 0 else { throw .result(n) }
                    while true {
                        let p = try readPacket(fd)
                        guard let (event, isUSB) = USBMuxEvent.from(p) else { continue }
                        switch event {
                        case .attached(let d) where isUSB:
                            usbDevices.insert(d.deviceID)
                            continuation.yield(event)
                        case .detached(let id) where usbDevices.remove(id) != nil:
                            continuation.yield(event)
                        default:
                            continue
                        }
                    }
                } catch {
                    continuation.finish(throwing: error == .closed ? nil : error)
                }
            }
        }
    }

    private func encode(_ p: USBMuxProtocol.Packet) throws(USBMuxError) -> [UInt8] {
        do { return try USBMuxProtocol.encode(p) } catch { throw .protocolError("encode") }
    }

    private func readPacket(_ fd: Int32) throws(USBMuxError) -> USBMuxProtocol.Packet {
        let header = try PosixIO.readExactly(fd, USBMuxProtocol.headerSize)
        let (length, tag) = try USBMuxProtocol.decodeHeader(header)
        return try USBMuxProtocol.decodeBody(try PosixIO.readExactly(fd, length), tag: tag)
    }
}

/// Minimal blocking POSIX helpers for the usbmuxd control exchange.
public enum PosixIO {
    public static func connectUnix(_ path: String) throws(USBMuxError) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .posix("socket", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = try unixAddress(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw .posix("connect \(path)", e)
        }
        return fd
    }

    public static func unixAddress(_ path: String) throws(USBMuxError) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw .posix("path too long", ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
            buf[bytes.count] = 0
        }
        return addr
    }

    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) throws(USBMuxError) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + offset, bytes.count - offset, 0) }
            if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { throw .posix("send", errno) }
        }
    }

    public static func readExactly(_ fd: Int32, _ count: Int) throws(USBMuxError) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = out.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress! + offset, count - offset, 0) }
            if n > 0 { offset += n } else if n == 0 { throw .closed } else if errno == EINTR { continue } else {
                throw errno == EAGAIN ? .posix("recv timeout", errno) : errno == ENOTCONN || errno == EBADF ? .closed : .posix("recv", errno)
            }
        }
        return out
    }

    public static func setReceiveTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}
#endif
