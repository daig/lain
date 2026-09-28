import LainClientCore
import Testing

/// Hosted in LainClient so the Keychain sees the app's identity (unhosted package tests get -34018).
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
