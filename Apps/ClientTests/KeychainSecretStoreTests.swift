import Foundation
import LainClientCore
import Testing

/// Hosted in LainClient so the Keychain sees the app's identity (unhosted package tests get -34018).
/// Only the test service, never the default one (it holds the owner's real pairing). Serialized: both
/// tests use that one service.
@Suite(.serialized) struct KeychainSecretStoreTests {
    @Test func keychainSecretStoreRoundTrip() throws {
        let store = KeychainSecretStore(service: "sub.dev.lain.pairing.test")
        try store.removeSecret(for: "host")
        #expect(try store.secret(for: "host") == nil)
        try store.setSecret(Array(repeating: 7, count: 32), for: "host")
        #expect(try store.secret(for: "host") == Array(repeating: 7, count: 32))
        try store.setSecret(Array(repeating: 9, count: 32), for: "host")
        #expect(try store.secret(for: "host") == Array(repeating: 9, count: 32))
        try store.removeSecret(for: "host")
        #expect(try store.secret(for: "host") == nil)
    }

    /// The client's accounts, "host" and `mac:<hostId>`, are all listed: the acceptor's candidates and
    /// the discovery filter (§7.7 D29).
    @Test func allSecretsListsTheServicesItems() throws {
        let store = KeychainSecretStore(service: "sub.dev.lain.pairing.test")
        for account in try store.allSecrets().keys { try store.removeSecret(for: account) }
        #expect(try store.allSecrets().isEmpty)   // errSecItemNotFound: nothing stored
        let usb = [UInt8](repeating: 1, count: 32), wifi = [UInt8](repeating: 2, count: 32)
        let hostId = UUID().uuidString
        try store.setSecret(usb, for: PairingAccounts.usbHost)
        try store.setSecret(wifi, for: PairingAccounts.mac(hostId))
        let listed = try store.allSecrets()
        #expect(listed == [PairingAccounts.usbHost: usb, PairingAccounts.mac(hostId): wifi])
        #expect(listed.keys.compactMap(PairingAccounts.hostId(fromAccount:)) == [hostId])
        try store.removeSecret(for: PairingAccounts.usbHost)
        try store.removeSecret(for: PairingAccounts.mac(hostId))
        #expect(try store.allSecrets().isEmpty)
    }
}
