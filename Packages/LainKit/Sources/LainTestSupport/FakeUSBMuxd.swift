#if os(macOS)
import Darwin
import Foundation
import LainUSBMux
import Synchronization

/// A stand-in for `/var/run/usbmuxd` (§12.2 layer 2): speaks the same plist protocol on a Unix socket
/// and bridges `Connect` to a TCP port on 127.0.0.1, so the USB path runs end to end without an iPad.
public final class FakeUSBMuxd: Sendable {
    public struct Device: Sendable {
        public var deviceID: Int
        public var serialNumber: String
        public var connectionType: String
        /// false: `Connect` is refused, as on a device without lain running (an iPhone, say).
        public var acceptsConnect: Bool
        public init(deviceID: Int, serialNumber: String, connectionType: String = "USB", acceptsConnect: Bool = true) {
            self.deviceID = deviceID
            self.serialNumber = serialNumber
            self.connectionType = connectionType
            self.acceptsConnect = acceptsConnect
        }
    }

    public let socketPath: String
    /// Where `Connect` requests are bridged (the client listener's actual port in tests).
    public let targetPort: UInt16
    /// The port a `Connect` must ask for (in network byte order on the wire).
    public let expectedPort: UInt16

    private struct State {
        var devices: [Device]
        var listeners: [Int32] = []
        var connects = 0
        var listenFD: Int32 = -1
        var stopped = false
    }
    private let state: Mutex<State>

    public init(devices: [Device], targetPort: UInt16, expectedPort: UInt16 = 47800) throws {
        socketPath = "/tmp/lain-fakemux-\(getpid())-\(UInt32.random(in: 0 ... .max)).sock"
        self.targetPort = targetPort
        self.expectedPort = expectedPort
        state = Mutex(State(devices: devices))
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try PosixIO.unixAddress(socketPath)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(fd, 16) == 0 else { throw USBMuxError.posix("fake bind", errno) }
        state.withLock { $0.listenFD = fd }
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    /// Number of successful `Connect`s bridged so far.
    public var connectCount: Int { state.withLock { $0.connects } }

    public func stop() {
        let (fd, listeners) = state.withLock { s in
            s.stopped = true
            defer { s.listeners = [] }
            return (s.listenFD, s.listeners)
        }
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        listeners.forEach { Darwin.shutdown($0, SHUT_RDWR) }
        unlink(socketPath)
    }

    public func attach(_ device: Device) {
        let listeners = state.withLock { s in
            s.devices.append(device)
            return s.listeners
        }
        for fd in listeners { try? send(fd, attachedPacket(device)) }
    }

    public func detach(deviceID: Int) {
        let listeners = state.withLock { s in
            s.devices.removeAll { $0.deviceID == deviceID }
            return s.listeners
        }
        let p = USBMuxProtocol.Packet(tag: 0, plist: ["MessageType": "Detached", "DeviceID": deviceID])
        for fd in listeners { try? send(fd, p) }
    }

    private func acceptLoop(_ listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    private func send(_ fd: Int32, _ p: USBMuxProtocol.Packet) throws {
        try PosixIO.writeAll(fd, try USBMuxProtocol.encode(p))
    }

    private func attachedPacket(_ d: Device) -> USBMuxProtocol.Packet {
        USBMuxProtocol.Packet(tag: 0, plist: [
            "MessageType": "Attached", "DeviceID": d.deviceID,
            "Properties": ["ConnectionType": d.connectionType, "DeviceID": d.deviceID, "SerialNumber": d.serialNumber,
                           "ProductID": 4779, "ConnectionSpeed": 480_000_000] as [String: Any],
        ])
    }

    private func serve(_ fd: Int32) {
        do {
            let (length, tag) = try USBMuxProtocol.decodeHeader(try PosixIO.readExactly(fd, USBMuxProtocol.headerSize))
            let request = try USBMuxProtocol.decodeBody(try PosixIO.readExactly(fd, length), tag: tag)
            switch request.messageType {
            case "Listen":
                let devices = state.withLock { s in
                    s.listeners.append(fd)
                    return s.devices
                }
                try send(fd, USBMuxProtocol.result(tag: tag, number: 0))
                for d in devices { try send(fd, attachedPacket(d)) }
                // Hold the socket open for later events; wait for the client to go away.
                var byte: UInt8 = 0
                while Darwin.recv(fd, &byte, 1, 0) > 0 {}
                state.withLock { $0.listeners.removeAll { $0 == fd } }
                Darwin.close(fd)
            case "Connect":
                let id = request.plist["DeviceID"] as? Int
                let port = request.plist["PortNumber"] as? Int
                let device = state.withLock { s in s.devices.first { $0.deviceID == id } }
                guard let device else { try send(fd, USBMuxProtocol.result(tag: tag, number: 2)); Darwin.close(fd); return }
                guard device.acceptsConnect else {
                    try send(fd, USBMuxProtocol.result(tag: tag, number: 3)); Darwin.close(fd); return
                }
                guard port == Int(expectedPort.bigEndian) else {
                    try send(fd, USBMuxProtocol.result(tag: tag, number: 3)); Darwin.close(fd); return
                }
                guard let upstream = try? connectTCP(targetPort) else {
                    try send(fd, USBMuxProtocol.result(tag: tag, number: 3)); Darwin.close(fd); return
                }
                try send(fd, USBMuxProtocol.result(tag: tag, number: 0))
                state.withLock { $0.connects += 1 }
                splice(fd, upstream)
            default:
                try send(fd, USBMuxProtocol.result(tag: tag, number: 1))
                Darwin.close(fd)
            }
        } catch {
            Darwin.close(fd)
        }
    }

    private func connectTCP(_ port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { Darwin.close(fd); throw USBMuxError.posix("fake connect", errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Copies bytes both ways until either side closes, like the daemon's raw pipe.
    private func splice(_ a: Int32, _ b: Int32) {
        let done = Mutex(0)
        func pump(_ from: Int32, _ to: Int32) {
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.recv(from, $0.baseAddress!, $0.count, 0) }
                guard n > 0 else { break }
                var off = 0
                while off < n {
                    let w = buf.withUnsafeBytes { Darwin.send(to, $0.baseAddress! + off, n - off, 0) }
                    guard w > 0 else { break }
                    off += w
                }
            }
            Darwin.shutdown(from, SHUT_RDWR)
            Darwin.shutdown(to, SHUT_RDWR)
            if done.withLock({ $0 += 1; return $0 }) == 2 {
                Darwin.close(a)
                Darwin.close(b)
            }
        }
        Thread.detachNewThread { pump(b, a) }
        pump(a, b)
    }
}
#endif
