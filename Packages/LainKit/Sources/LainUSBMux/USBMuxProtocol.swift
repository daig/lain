#if os(macOS)
import Foundation

/// usbmuxd wire format (§7.2): a 16-byte little-endian header (total length, version 1, message type
/// 8 = plist, tag) followed by an XML property list. Verified against the real daemon on macOS 27.
public enum USBMuxProtocol {
    public static let headerSize = 16
    public static let version: UInt32 = 1
    public static let plistMessageType: UInt32 = 8
    /// Largest plist body we accept.
    public static let maxBodySize = 1 << 20

    public struct Packet: Equatable, @unchecked Sendable {
        public var tag: UInt32
        public var plist: [String: Any]

        public init(tag: UInt32, plist: [String: Any]) {
            self.tag = tag
            self.plist = plist
        }

        public var messageType: String? { plist["MessageType"] as? String }

        public static func == (a: Packet, b: Packet) -> Bool {
            a.tag == b.tag && NSDictionary(dictionary: a.plist).isEqual(to: b.plist)
        }
    }

    public static func encode(_ packet: Packet) throws -> [UInt8] {
        let body = try PropertyListSerialization.data(fromPropertyList: packet.plist, format: .xml, options: 0)
        var out: [UInt8] = []
        out.reserveCapacity(headerSize + body.count)
        for v in [UInt32(headerSize + body.count), version, plistMessageType, packet.tag] {
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
        }
        out.append(contentsOf: body)
        return out
    }

    /// Parses a header; returns (body length, tag).
    public static func decodeHeader(_ bytes: [UInt8]) throws(USBMuxError) -> (bodyLength: Int, tag: UInt32) {
        guard bytes.count == headerSize else { throw .protocolError("short header") }
        func u32(_ i: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[i + $1]) << (8 * $1) } }
        let length = Int(u32(0))
        guard u32(4) == version, u32(8) == plistMessageType else {
            throw .protocolError("version \(u32(4)) type \(u32(8))")
        }
        guard length >= headerSize, length - headerSize <= maxBodySize else { throw .protocolError("length \(length)") }
        return (length - headerSize, u32(12))
    }

    public static func decodeBody(_ body: [UInt8], tag: UInt32) throws(USBMuxError) -> Packet {
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(body), format: nil) as? [String: Any] else {
            throw .protocolError("bad plist")
        }
        return Packet(tag: tag, plist: plist)
    }

    static func base(_ type: String) -> [String: Any] {
        ["MessageType": type, "ClientVersionString": "lain", "ProgName": "lain"]
    }

    public static func listen(tag: UInt32) -> Packet { Packet(tag: tag, plist: base("Listen")) }

    /// `PortNumber` is the port in network byte order, read as a host integer (PeerTalk's htons).
    public static func connect(tag: UInt32, deviceID: Int, port: UInt16) -> Packet {
        var p = base("Connect")
        p["DeviceID"] = deviceID
        p["PortNumber"] = Int(port.bigEndian)
        return Packet(tag: tag, plist: p)
    }

    public static func result(tag: UInt32, number: Int) -> Packet {
        Packet(tag: tag, plist: ["MessageType": "Result", "Number": number])
    }
}

public enum USBMuxError: Error, Equatable, Sendable {
    case posix(String, Int32)
    case protocolError(String)
    /// usbmuxd's `Result` code: 1 bad command, 2 bad device, 3 connection refused, 6 bad version.
    case result(Int)
    case closed
}

/// A device usbmuxd reports as attached over USB.
public struct USBMuxDevice: Sendable, Equatable, Hashable {
    public var deviceID: Int
    public var serialNumber: String
    public var productID: Int?
    /// Bits per second (480 000 000 = USB 2).
    public var connectionSpeed: Int?

    public init(deviceID: Int, serialNumber: String, productID: Int? = nil, connectionSpeed: Int? = nil) {
        self.deviceID = deviceID
        self.serialNumber = serialNumber
        self.productID = productID
        self.connectionSpeed = connectionSpeed
    }
}

public enum USBMuxEvent: Sendable, Equatable {
    case attached(USBMuxDevice)
    case detached(deviceID: Int)
}

extension USBMuxEvent {
    /// Interprets an event packet. Non-USB (network) attachments return nil.
    static func from(_ p: USBMuxProtocol.Packet) -> (event: USBMuxEvent, isUSB: Bool)? {
        switch p.messageType {
        case "Attached":
            guard let props = p.plist["Properties"] as? [String: Any], let id = p.plist["DeviceID"] as? Int else { return nil }
            let device = USBMuxDevice(deviceID: id, serialNumber: props["SerialNumber"] as? String ?? "",
                                      productID: props["ProductID"] as? Int, connectionSpeed: props["ConnectionSpeed"] as? Int)
            return (.attached(device), props["ConnectionType"] as? String == "USB")
        case "Detached":
            guard let id = p.plist["DeviceID"] as? Int else { return nil }
            return (.detached(deviceID: id), true)
        default:
            return nil
        }
    }
}
#endif
