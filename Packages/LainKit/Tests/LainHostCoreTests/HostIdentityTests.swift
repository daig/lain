#if os(macOS)
import LainTransport
import Testing
@testable import LainHostCore

@Suite struct HostIdentityTests {
    @Test func theIdIsCreatedOnceThenKept() throws {
        let store = InMemorySecretStore()
        let first = try HostIdentity.load(from: store, name: "Test Mac")
        #expect(PairingAccounts.isCanonicalHostId(first.id))
        #expect(first.name == "Test Mac")
        #expect(store.secret(for: HostIdentity.account) == Array(first.id.utf8))
        #expect(try HostIdentity.load(from: store, name: "Renamed").id == first.id)
    }

    @Test func aMalformedStoredIdIsReplaced() throws {
        let store = InMemorySecretStore([HostIdentity.account: Array("not-a-uuid".utf8)])
        let identity = try HostIdentity.load(from: store, name: "Test Mac")
        #expect(PairingAccounts.isCanonicalHostId(identity.id))
        #expect(store.secret(for: HostIdentity.account) == Array(identity.id.utf8))
    }

    @Test func theComputerNameIsNeverEmpty() {
        #expect(!HostIdentity.computerName.isEmpty)
    }
}
#endif
