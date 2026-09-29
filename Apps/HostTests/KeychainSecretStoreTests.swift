import Foundation
import LainHostCore
import Testing

/// Hosted in LainHost so the Keychain sees the app's identity (unhosted package tests get -34018).
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

    /// The host lists every stored iPad secret (its Wi-Fi PSKs, §7.7 D29).
    @Test func allSecretsListsTheServicesItems() throws {
        let store = KeychainSecretStore(service: "sub.dev.lain.pairing.test")
        for account in try store.allSecrets().keys { try store.removeSecret(for: account) }
        #expect(try store.allSecrets().isEmpty)   // errSecItemNotFound: nothing stored
        let a = [UInt8](repeating: 1, count: 32), b = [UInt8](repeating: 2, count: 32)
        try store.setSecret(a, for: "IPAD-SERIAL-1")
        try store.setSecret(b, for: "IPAD-SERIAL-2")
        #expect(try store.allSecrets() == ["IPAD-SERIAL-1": a, "IPAD-SERIAL-2": b])
        try store.setSecret(b, for: "IPAD-SERIAL-1")
        #expect(try store.allSecrets() == ["IPAD-SERIAL-1": b, "IPAD-SERIAL-2": b])
        try store.removeSecret(for: "IPAD-SERIAL-1")
        try store.removeSecret(for: "IPAD-SERIAL-2")
        #expect(try store.allSecrets().isEmpty)
    }
}
