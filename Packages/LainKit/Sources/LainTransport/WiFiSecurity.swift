import CryptoKit
import Foundation
import Network
import Security

/// The Wi-Fi TLS pre-shared key of one pairing (§7.6, §7.7, D29), derived from the 32-byte pairing
/// secret with HKDF-SHA256 (salt "lain"; distinct info strings, so the key and the identity are
/// independent). TLS 1.2 sends the identity in the clear, as TLS 1.3 would; being derived, it reveals
/// nothing about the secret, and it lets a host hold one PSK per paired iPad. `ChannelHello`'s HMAC
/// still runs on every connection (grouping, defence in depth).
public struct WiFiPSK: Sendable, CustomStringConvertible, CustomReflectable {
    /// "lain1-" + 16 lowercase hex digits (8 derived bytes).
    public let identity: String
    /// 32 bytes. Never logged: `description` and the mirror show the identity only.
    let key: [UInt8]

    public init(secret: [UInt8]) {
        let ikm = SymmetricKey(data: secret)
        self.init(identity: "lain1-" + Self.hex(Self.derive(ikm, info: "lain wifi psk identity v1", count: 8)),
                  key: Self.derive(ikm, info: "lain wifi tls-psk v1", count: 32))
    }

    /// Any identity with any key (tests: a known identity with the wrong key).
    init(identity: String, key: [UInt8]) {
        self.identity = identity
        self.key = key
    }

    public var description: String { identity }
    public var customMirror: Mirror { Mirror(self, children: ["identity": identity]) }

    private static func derive(_ ikm: SymmetricKey, info: String, count: Int) -> [UInt8] {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: Data("lain".utf8), info: Data(info.utf8), outputByteCount: count)
            .withUnsafeBytes { Array($0) }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] }, as: UTF8.self)
    }
}

/// TLS for Wi-Fi links (D29): TLS 1.2 only, `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC)
/// only, so every connection gets forward secrecy on top of the PSK. Network.framework can't do TLS 1.3
/// with an external PSK (-9858, measured 2026-09-29), and the new `NetworkConnection` API has no PSK
/// support, hence the classic `sec_protocol_options`. Tickets and resumption are off: every connection
/// proves a PSK the listener holds now.
public enum WiFiTLS {
    /// `tls_protocol_version_t.TLSv12`.
    public static let version: UInt16 = 0x0303
    /// `tls_ciphersuite_t` has no PSK cases, so the suite goes in by raw value.
    public static let cipherSuite: UInt16 = 0xCCAC

    /// The dialer (the iPad) offers its one pairing's PSK.
    public static func clientOptions(_ psk: WiFiPSK) -> NWProtocolTLS.Options { options([psk]) }

    /// The listener (the Mac) holds one PSK per paired iPad; the handshake picks the one whose identity
    /// the client offers (unknown → -9864). The server can't tell which one was used (the metadata
    /// lists them all), so the acceptor identifies the peer by trying `ChannelHello` candidates. With
    /// no PSKs, every handshake fails.
    public static func serverOptions(_ psks: [WiFiPSK]) -> NWProtocolTLS.Options { options(psks) }

    private static func options(_ psks: [WiFiPSK]) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        for psk in psks {
            sec_protocol_options_add_pre_shared_key(sec, dispatchData(psk.key), dispatchData(Array(psk.identity.utf8)))
        }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: cipherSuite)!)
        sec_protocol_options_set_tls_tickets_enabled(sec, false)
        sec_protocol_options_set_tls_resumption_enabled(sec, false)
        return tls
    }

    /// Copies the bytes while they are valid (building `DispatchData` from a pointer that outlives
    /// the array's storage would dangle).
    private static func dispatchData(_ bytes: [UInt8]) -> __DispatchData {
        bytes.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}
