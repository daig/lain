import Foundation
import LainClientCore
import LainTransport
import Testing

/// Hosted in LainMacClient so the data-protection Keychain sees the app's identity and
/// `keychain-access-groups` entitlement (`sub.dev.lain.client.mac`).
@Suite(.serialized) struct MacClientKeychainSecretStoreTests {
    @Test func keychainSecretStoreRoundTrip() throws {
        let store = KeychainSecretStore(service: "sub.dev.lain.macclient.pairing.test")
        let account = PairingAccounts.mac("01234567-89AB-CDEF-0123-456789ABCDEF")
        try store.removeSecret(for: account)
        #expect(try store.secret(for: account) == nil)
        let secret = Array(UInt8(1)...UInt8(32))
        try store.setSecret(secret, for: account)
        #expect(try store.secret(for: account) == secret)
        try store.removeSecret(for: account)
        #expect(try store.secret(for: account) == nil)
    }
}
