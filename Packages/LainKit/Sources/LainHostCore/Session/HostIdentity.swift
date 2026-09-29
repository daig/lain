#if os(macOS)
import Foundation
import LainTransport
import SystemConfiguration

/// Who this Mac is to its iPads over Wi-Fi (§7.7 D29): a stable random id, advertised in the Bonjour TXT
/// record and sent in `Pair` and `HelloAck` (the iPad dials only ids it holds a secret for), and the
/// computer name. The id lives in the data-protection Keychain, this device only, so Migration Assistant
/// can't copy it to another Mac.
public struct HostIdentity: Sendable, Equatable {
    /// A canonical UUID string (`PairingAccounts.isCanonicalHostId`).
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Where the id is kept: its own Keychain service, apart from the pairing secrets.
    public static let keychainService = "sub.dev.lain.host-identity"
    static let account = "host-id"

    /// The stored id (created and stored on first use) with the current computer name. Throws if the
    /// store can't be read or written: Wi-Fi then stays off rather than advertising an id that changes.
    public static func load(from store: some SecretStore = KeychainSecretStore(service: keychainService),
                            name: String = computerName) throws -> HostIdentity {
        if let bytes = try store.secret(for: account), let id = String(bytes: bytes, encoding: .utf8),
           PairingAccounts.isCanonicalHostId(id) {
            return HostIdentity(id: id, name: name)
        }
        let id = UUID().uuidString
        try store.setSecret(Array(id.utf8), for: account)
        return HostIdentity(id: id, name: name)
    }

    /// The Mac's computer name (System Settings › General › Sharing), as Bonjour advertises it.
    public static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }
}
#endif
