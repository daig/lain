import Darwin
import Dispatch
import Foundation
import LainTelemetry

/// Wake-on-LAN (WoL) helpers: formatting and validating Ethernet/Wi-Fi MAC addresses, reading this Mac's
/// hardware MACs for the Bonjour TXT record, and broadcasting standard 102-byte UDP magic packets from the
/// client when a saved Mac isn't visible on Bonjour (asleep with lid closed on AC power).
public enum WakeOnLAN {
    private static let log = Telemetry.logger("wifi")
    private static let sendQueue = DispatchQueue(label: "lain.wifi.wol", qos: .utility)

    /// Standard UDP port for Wake-on-LAN magic packets (Discard).
    public static let port: UInt16 = 9

    /// Parses a MAC address (`"aa:bb:cc:dd:ee:ff"` or `"aabbccddeeff"`) into 6 raw bytes, rejecting all-zero,
    /// multicast (odd first byte), or masked dummy (`02:00:00:00:00:00`) addresses.
    public static func parseMAC(_ raw: String) -> [UInt8]? {
        let hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(6)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<next], radix: 16) else { return nil }
            bytes.append(b)
            i = next
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        guard bytes[0] & 0x01 == 0 else { return nil }   // multicast bit must be 0
        guard bytes != [0x02, 0x00, 0x00, 0x00, 0x00, 0x00] else { return nil }   // sandbox dummy MAC
        return bytes
    }

    /// Returns a canonical 12-character lowercase hex MAC string (`"aabbccddeeff"`), or nil if invalid.
    public static func normalizeMAC(_ raw: String) -> String? {
        guard let bytes = parseMAC(raw) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Standard 102-byte Wake-on-LAN magic packet: 6 bytes of `0xFF` followed by the 6-byte MAC repeated 16 times.
    public static func magicPacket(mac: [UInt8]) -> [UInt8] {
        guard mac.count == 6 else { return [] }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        packet.reserveCapacity(102)
        for _ in 0..<16 { packet.append(contentsOf: mac) }
        return packet
    }

    /// Returns up to 3 hardware Ethernet/Wi-Fi MAC addresses on this host (`en0` first, then other active
    /// `en*` interfaces carrying an IP address), as canonical 12-char lowercase hex strings.
    public static func localMACs() -> [String] {
        var rawList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&rawList) == 0, let head = rawList else { return [] }
        defer { freeifaddrs(head) }

        var interfacesWithIP: Set<String> = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            let ifa = current.pointee
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("en"), let addr = ifa.ifa_addr {
                let family = Int32(addr.pointee.sa_family)
                if (family == AF_INET || family == AF_INET6), (ifa.ifa_flags & UInt32(IFF_UP)) != 0 {
                    interfacesWithIP.insert(name)
                }
            }
            cursor = ifa.ifa_next
        }

        var candidates: [(name: String, hasIP: Bool, locallyAdministered: Bool, mac: String)] = []
        cursor = head
        while let current = cursor {
            let ifa = current.pointee
            let name = String(cString: ifa.ifa_name)
            if name.hasPrefix("en"), let addr = ifa.ifa_addr, Int32(addr.pointee.sa_family) == AF_LINK {
                let sdl = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                if sdl.sdl_type == UInt8(IFT_ETHER), sdl.sdl_alen == 6 {
                    let base = UnsafeRawPointer(addr).advanced(by: MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!)
                    let macPtr = base.advanced(by: Int(sdl.sdl_nlen)).assumingMemoryBound(to: UInt8.self)
                    let bytes = (0..<6).map { macPtr[$0] }
                    let raw = bytes.map { String(format: "%02x", $0) }.joined()
                    if let normalized = normalizeMAC(raw), (name == "en0" || interfacesWithIP.contains(name)) {
                        candidates.append((name: name,
                                           hasIP: interfacesWithIP.contains(name),
                                           locallyAdministered: (bytes[0] & 0x02) != 0,
                                           mac: normalized))
                    }
                }
            }
            cursor = ifa.ifa_next
        }

        // Prefer en0, then real globally-unique hardware MACs, then active interfaces with IPs.
        candidates.sort { a, b in
            let aKey = (a.name == "en0" ? 0 : 1, a.locallyAdministered ? 1 : 0, a.hasIP ? 0 : 1, a.name)
            let bKey = (b.name == "en0" ? 0 : 1, b.locallyAdministered ? 1 : 0, b.hasIP ? 0 : 1, b.name)
            return aKey < bKey
        }
        var seen: Set<String> = []
        var result: [String] = []
        for c in candidates where seen.insert(c.mac).inserted {
            result.append(c.mac)
            if result.count == 3 { break }
        }
        return result
    }

    /// Broadcasts Wake-on-LAN magic packets for `macs` asynchronously on a utility queue, targeting every active
    /// IPv4 interface's directed subnet broadcast address as well as `255.255.255.255`.
    public static func send(macs: [String]) {
        let parsed = macs.compactMap(parseMAC)
        guard !parsed.isEmpty else { return }
        sendQueue.async {
            let broadcasts = broadcastAddresses()
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var enable: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

            for bytes in parsed {
                let packet = magicPacket(mac: bytes)
                for target in broadcasts {
                    var addr = sockaddr_in()
                    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    addr.sin_family = sa_family_t(AF_INET)
                    addr.sin_port = port.bigEndian
                    addr.sin_addr = target
                    packet.withUnsafeBytes { buf in
                        withUnsafePointer(to: &addr) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                                _ = sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
            }
            log.notice("Wi-Fi: sent Wake-on-LAN for \(parsed.count) MAC(s) to \(broadcasts.count) broadcast address(es)")
        }
    }

    /// Directed IPv4 broadcast addresses of all active non-loopback interfaces, plus `255.255.255.255`.
    private static func broadcastAddresses() -> [in_addr] {
        var seen: Set<UInt32> = []
        var out: [in_addr] = []
        var rawList: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&rawList) == 0, let head = rawList {
            defer { freeifaddrs(head) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = head
            while let current = cursor {
                let ifa = current.pointee
                let flags = Int32(ifa.ifa_flags)
                if (flags & IFF_UP) != 0, (flags & IFF_BROADCAST) != 0, (flags & IFF_LOOPBACK) == 0,
                   let dst = ifa.ifa_dstaddr, Int32(dst.pointee.sa_family) == AF_INET {
                    let sin = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    if sin.sin_addr.s_addr != 0, seen.insert(sin.sin_addr.s_addr).inserted {
                        out.append(sin.sin_addr)
                    }
                }
                cursor = ifa.ifa_next
            }
        }
        let limited = in_addr(s_addr: INADDR_BROADCAST)
        if seen.insert(limited.s_addr).inserted { out.append(limited) }
        return out
    }
}
