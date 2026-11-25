import Foundation
import LainClientCore
import Testing

/// Hosted in LainTVClient so the Keychain sees the tvOS app's identity.
/// Uses a dedicated test service so real pairings are never touched.
@Suite(.serialized) struct KeychainSecretStoreTests {
    @Test func keychainSecretStoreRoundTrip() throws {
        let store = KeychainSecretStore(service: "sub.dev.lain.pairing.tv.test")
        try store.removeSecret(for: "host")
        #expect(try store.secret(for: "host") == nil)
        try store.setSecret(Array(repeating: 7, count: 32), for: "host")
        #expect(try store.secret(for: "host") == Array(repeating: 7, count: 32))
        try store.setSecret(Array(repeating: 9, count: 32), for: "host")
        #expect(try store.secret(for: "host") == Array(repeating: 9, count: 32))
        try store.removeSecret(for: "host")
        #expect(try store.secret(for: "host") == nil)
    }

    @Test func allSecretsListsTheServicesItems() throws {
        let store = KeychainSecretStore(service: "sub.dev.lain.pairing.tv.test")
        for account in try store.allSecrets().keys { try store.removeSecret(for: account) }
        #expect(try store.allSecrets().isEmpty)
        let hostId = UUID().uuidString
        let wifi = [UInt8](repeating: 2, count: 32)
        try store.setSecret(wifi, for: PairingAccounts.mac(hostId))
        let listed = try store.allSecrets()
        #expect(listed == [PairingAccounts.mac(hostId): wifi])
        #expect(listed.keys.compactMap(PairingAccounts.hostId(fromAccount:)) == [hostId])
        try store.removeSecret(for: PairingAccounts.mac(hostId))
        #expect(try store.allSecrets().isEmpty)
    }
}
