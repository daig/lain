#if os(macOS)
import Darwin
import Foundation
import LainTestSupport
import Testing
@testable import LainUSBMux

@Suite struct Packets {
    @Test func roundTrip() throws {
        let p = USBMuxProtocol.connect(tag: 7, deviceID: 5, port: 47800)
        let bytes = try USBMuxProtocol.encode(p)
        let (length, tag) = try USBMuxProtocol.decodeHeader(Array(bytes.prefix(16)))
        #expect(length == bytes.count - 16 && tag == 7)
        #expect(Array(bytes[4..<12]) == [1, 0, 0, 0, 8, 0, 0, 0])      // version 1, plist type 8, little-endian
        #expect(try USBMuxProtocol.decodeBody(Array(bytes.dropFirst(16)), tag: tag) == p)
    }

    @Test func portIsInNetworkByteOrder() {
        // PeerTalk's htons(47800): 0xBAB8 → 0xB8BA read as a host integer.
        #expect(USBMuxProtocol.connect(tag: 1, deviceID: 1, port: 47800).plist["PortNumber"] as? Int == 0xB8BA)
    }

    @Test func rejectsBadHeaders() {
        #expect(throws: USBMuxError.self) { try USBMuxProtocol.decodeHeader([UInt8](repeating: 0, count: 16)) }
        #expect(throws: USBMuxError.self) { try USBMuxProtocol.decodeHeader([0x10, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0]) }
        #expect(throws: USBMuxError.self) { try USBMuxProtocol.decodeBody(Array("junk".utf8), tag: 0) }
    }

    @Test func parsesEventsLikeTheRealDaemon() throws {
        // Shape captured from /var/run/usbmuxd on macOS 27 (serials elided).
        let attached = USBMuxProtocol.Packet(tag: 0, plist: [
            "DeviceID": 5, "MessageType": "Attached",
            "Properties": ["ConnectionSpeed": 480_000_000, "ConnectionType": "USB", "DeviceID": 5, "LocationID": 2_097_152,
                           "ProductID": 4779, "SerialNumber": "0000", "USBSerialNumber": "0000"] as [String: Any],
        ])
        let parsed = try #require(USBMuxEvent.from(attached))
        #expect(parsed.isUSB)
        #expect(parsed.event == .attached(USBMuxDevice(deviceID: 5, serialNumber: "0000", productID: 4779,
                                                       connectionSpeed: 480_000_000)))
        let network = USBMuxProtocol.Packet(tag: 0, plist: ["DeviceID": 9, "MessageType": "Attached",
                                                            "Properties": ["ConnectionType": "Network"]])
        #expect(USBMuxEvent.from(network)?.isUSB == false)
    }
}

/// A TCP echo server on an ephemeral loopback port.
final class EchoServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        self.fd = fd
        Thread.detachNewThread {
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                Thread.detachNewThread {
                    var buf = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = buf.withUnsafeMutableBytes { recv(c, $0.baseAddress!, $0.count, 0) }
                        guard n > 0 else { break }
                        _ = buf.withUnsafeBytes { send(c, $0.baseAddress!, n, 0) }
                    }
                    close(c)
                }
            }
        }
    }

    func stop() { shutdown(fd, SHUT_RDWR); close(fd) }
}

@Suite struct AgainstFakeDaemon {
    @Test func listenReportsUSBDevicesAndDetaches() async throws {
        let mux = try FakeUSBMuxd(devices: [.init(deviceID: 5, serialNumber: "IPAD"),
                                            .init(deviceID: 9, serialNumber: "WIFI", connectionType: "Network")],
                                  targetPort: 1)
        defer { mux.stop() }
        var events = USBMuxClient(socketPath: mux.socketPath).events().makeAsyncIterator()
        let first = try await events.next()
        guard case .attached(let d) = first else { Issue.record("expected attached, got \(String(describing: first))"); return }
        #expect(d.deviceID == 5 && d.serialNumber == "IPAD" && d.connectionSpeed == 480_000_000)
        mux.detach(deviceID: 9)   // network device: filtered
        mux.detach(deviceID: 5)
        #expect(try await events.next() == .detached(deviceID: 5))
        mux.attach(.init(deviceID: 6, serialNumber: "IPAD2"))
        #expect(try await events.next() == .attached(USBMuxDevice(deviceID: 6, serialNumber: "IPAD2", productID: 4779,
                                                                   connectionSpeed: 480_000_000)))
    }

    @Test func connectBecomesARawPipe() async throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        let mux = try FakeUSBMuxd(devices: [.init(deviceID: 5, serialNumber: "IPAD")], targetPort: echo.port)
        defer { mux.stop() }
        let fd = try await USBMuxClient(socketPath: mux.socketPath).connect(deviceID: 5, port: 47800)
        defer { close(fd) }
        try PosixIO.writeAll(fd, Array("hello lain".utf8))
        #expect(try PosixIO.readExactly(fd, 10) == Array("hello lain".utf8))
        #expect(mux.connectCount == 1)
    }

    @Test func connectErrors() async throws {
        let mux = try FakeUSBMuxd(devices: [.init(deviceID: 5, serialNumber: "IPAD")], targetPort: 1)
        defer { mux.stop() }
        let client = USBMuxClient(socketPath: mux.socketPath)
        await #expect(throws: USBMuxError.result(2)) { _ = try await client.connect(deviceID: 99, port: 47800) }
        await #expect(throws: USBMuxError.result(3)) { _ = try await client.connect(deviceID: 5, port: 1234) }
        await #expect(throws: USBMuxError.result(3)) { _ = try await client.connect(deviceID: 5, port: 47800) }  // nothing listening
        await #expect(throws: USBMuxError.self) {
            _ = try await USBMuxClient(socketPath: "/tmp/lain-no-such-mux.sock").connect(deviceID: 5, port: 47800)
        }
    }
}
#endif
