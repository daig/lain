import CryptoKit
import Foundation
import Synchronization

/// ChannelHello authentication (§7.6): HMAC-SHA256 over version, kind and session token, keyed by
/// the 32-byte pairing secret.
public enum ChannelAuth {
    /// An all-zero HMAC asks for USB pairing.
    public static let pairingMAC = [UInt8](repeating: 0, count: ChannelHello.macSize)

    public static func mac(secret: [UInt8], for hello: ChannelHello) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: hello.authenticatedBytes, using: SymmetricKey(data: secret)))
    }

    public static func isValid(_ hello: ChannelHello, secret: [UInt8]) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(hello.hmac, authenticating: hello.authenticatedBytes,
                                              using: SymmetricKey(data: secret))
    }

    /// A ChannelHello carrying its HMAC.
    public static func hello(kind: ConnectionKind, token: [UInt8], secret: [UInt8]?) -> ChannelHello {
        var h = ChannelHello(connectionKind: kind, sessionToken: token, hmac: pairingMAC)
        if let secret { h.hmac = mac(secret: secret, for: h) }
        return h
    }

    public static func randomBytes(_ count: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) }
    }
}

/// Where pairing secrets live: the Keychain in the apps, memory in tests.
public protocol SecretStore: Sendable {
    func secret(for peer: String) throws -> [UInt8]?
    func setSecret(_ secret: [UInt8], for peer: String) throws
    func removeSecret(for peer: String) throws
}

public final class InMemorySecretStore: SecretStore {
    private let secrets = Mutex<[String: [UInt8]]>([:])
    public init(_ initial: [String: [UInt8]] = [:]) { secrets.withLock { $0 = initial } }
    public func secret(for peer: String) -> [UInt8]? { secrets.withLock { $0[peer] } }
    public func setSecret(_ secret: [UInt8], for peer: String) { secrets.withLock { $0[peer] = secret } }
    public func removeSecret(for peer: String) { secrets.withLock { $0[peer] = nil } }
}

/// Generic-password items in the data-protection Keychain, one per peer, never synced. Needs the
/// app's identity: on macOS a `keychain-access-groups` entitlement (and so a provisioning profile);
/// unhosted test bundles get -34018 (errSecMissingEntitlement).
public struct KeychainSecretStore: SecretStore {
    public struct Failure: Error, Equatable { public let status: OSStatus }

    public let service: String

    public init(service: String = "sub.dev.lain.pairing") { self.service = service }

    private func query(_ peer: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: peer,
         kSecUseDataProtectionKeychain: true]
    }

    public func secret(for peer: String) throws -> [UInt8]? {
        var q = query(peer)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Failure(status: status) }
        return Array(data)
    }

    public func setSecret(_ secret: [UInt8], for peer: String) throws {
        let update = [kSecValueData: Data(secret)] as CFDictionary
        var status = SecItemUpdate(query(peer) as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = query(peer)
            add[kSecValueData] = Data(secret)
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func removeSecret(for peer: String) throws {
        let status = SecItemDelete(query(peer) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
