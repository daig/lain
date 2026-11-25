import Foundation
import LainProtocol

/// Out-of-band pairing token for clients that cannot pair over usbmuxd/USB (e.g. macOS, Apple TV).
///
/// Format: `lain1:<base64url(payload)>` (no `=` padding).
/// Binary payload:
/// - byte 0: version (`1`)
/// - bytes 1..<17: host UUID (16 bytes, RFC 4122)
/// - bytes 17..<49: pairing secret (32 bytes, non-zero)
/// - byte 49: host name UTF-8 byte length (`0...64`)
/// - bytes 50..<(50 + nameLen): host name UTF-8
///
/// Identical wire format in Swift (`LainTransport`) and Rust (`lain-link`), with no changes to the
/// network protocol: the host stores the secret in its secret store and reloads its Wi-Fi TLS-PSK
/// listener; the client stores it under `PairingAccounts.mac(hostId)` and dials over LAN/AWDL.
public struct PairingCode: Sendable, Equatable {
    public static let prefix = "lain1:"
    public static let version: UInt8 = 1
    public static let maxHostNameBytes = 64
    private static let fixedHeaderLength = 1 + 16 + Pair.secretSize + 1

    public var hostId: String
    public var secret: [UInt8]
    public var hostName: String

    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case invalidHostId
        case invalidSecret
        case invalidFormat
        case unsupportedVersion(UInt8)

        public var description: String {
            switch self {
            case .invalidHostId: "host id must be a canonical UUID"
            case .invalidSecret: "pairing secret must be 32 non-zero bytes"
            case .invalidFormat: "invalid pairing code"
            case .unsupportedVersion(let v): "unsupported pairing code version \(v)"
            }
        }
    }

    public init(hostId: String, secret: [UInt8], hostName: String = "") throws(Error) {
        guard PairingAccounts.isCanonicalHostId(hostId) else { throw .invalidHostId }
        guard secret.count == Pair.secretSize, secret.contains(where: { $0 != 0 }) else { throw .invalidSecret }
        self.hostId = hostId
        self.secret = secret
        self.hostName = Self.truncateUTF8(hostName, maxBytes: Self.maxHostNameBytes)
    }

    /// Encodes as `lain1:<base64url>` with no padding.
    public func encode() -> String {
        guard let uuid = UUID(uuidString: hostId) else { preconditionFailure("canonical UUID validated in init") }
        let nameBytes = Array(Self.truncateUTF8(hostName, maxBytes: Self.maxHostNameBytes).utf8)
        var payload = [UInt8]()
        payload.reserveCapacity(Self.fixedHeaderLength + nameBytes.count)
        payload.append(Self.version)
        withUnsafeBytes(of: uuid.uuid) { payload.append(contentsOf: $0) }
        payload.append(contentsOf: secret)
        payload.append(UInt8(nameBytes.count))
        payload.append(contentsOf: nameBytes)
        return Self.prefix + Self.base64URLEncode(payload)
    }

    /// Decodes a `lain1:...` pairing code (ignoring surrounding or embedded whitespace/newlines).
    public static func decode(_ raw: String) throws(Error) -> PairingCode {
        let stripped = raw.filter { !$0.isWhitespace }
        guard stripped.hasPrefix(prefix) else { throw .invalidFormat }
        let body = String(stripped.dropFirst(prefix.count))
        guard !body.isEmpty, let bytes = base64URLDecode(body), bytes.count >= fixedHeaderLength else {
            throw .invalidFormat
        }
        let ver = bytes[0]
        guard ver == version else { throw .unsupportedVersion(ver) }
        let uuidBytes = Array(bytes[1..<17])
        let uuid: uuid_t = (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        )
        let hostId = UUID(uuid: uuid).uuidString
        let secret = Array(bytes[17..<(17 + Pair.secretSize)])
        guard secret.contains(where: { $0 != 0 }) else { throw .invalidSecret }
        let nameLen = Int(bytes[17 + Pair.secretSize])
        guard nameLen <= maxHostNameBytes, bytes.count == fixedHeaderLength + nameLen else {
            throw .invalidFormat
        }
        let nameSlice = bytes[fixedHeaderLength..<(fixedHeaderLength + nameLen)]
        guard let hostName = String(bytes: nameSlice, encoding: .utf8) else { throw .invalidFormat }
        return try PairingCode(hostId: hostId, secret: secret, hostName: hostName)
    }

    /// Truncates `string` to at most `maxBytes` UTF-8 bytes without splitting a scalar.
    static func truncateUTF8(_ string: String, maxBytes: Int) -> String {
        guard string.utf8.count > maxBytes else { return string }
        var out = ""
        var count = 0
        for scalar in string.unicodeScalars {
            let n = scalar.utf8.count
            if count + n > maxBytes { break }
            out.unicodeScalars.append(scalar)
            count += n
        }
        return out
    }

    private static func base64URLEncode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ text: String) -> [UInt8]? {
        var b64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem == 1 { return nil }
        if rem > 0 { b64.append(String(repeating: "=", count: 4 - rem)) }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return Array(data)
    }
}
