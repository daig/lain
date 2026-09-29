import LainProtocol
import Network
import Testing
@testable import LainTransport

// Pure mapping and the fixed discovery only: tests never create an NWBrowser (D29 test rules).

@Suite struct WiFiDiscovery {
    let hostId = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    let service = NWEndpoint.service(name: "Mac mini", type: "_lain._tcp", domain: "local.", interface: nil)

    @Test func txtCarriesTheVersionAndHostId() {
        #expect(LainTXT.dictionary(hostId: hostId) == ["v": String(LainProtocol.majorVersion), "id": hostId])
        #expect(LainTXT.dictionary(hostId: hostId, version: 2, bench: true) == ["v": "2", "id": hostId, "bench": "1"])
        // Through the DNS-SD wire format and back.
        let wire = LainTXT.record(hostId: hostId, version: 2).data
        #expect(NWTXTRecord(wire).dictionary == ["v": "2", "id": hostId])
    }

    @Test func aBrowseResultMapsToADiscoveredHost() throws {
        let host = try #require(DiscoveredHost(endpoint: service, txt: LainTXT.dictionary(hostId: hostId, version: 2),
                                               interfaceNames: ["en0", "awdl0"]))
        #expect(host == DiscoveredHost(hostId: hostId, name: "Mac mini", protocolVersion: 2, endpoint: service,
                                       interfaceNames: ["en0", "awdl0"]))
        #expect(!host.isBench)
        #expect(host.description == "Mac mini [\(hostId) v2 on en0,awdl0]")
        let bench = DiscoveredHost(endpoint: service, txt: LainTXT.dictionary(hostId: hostId, bench: true), interfaceNames: [])
        #expect(bench?.isBench == true)
    }

    @Test func theMappingToleratesOddRecords() {
        // No id: nothing to match against the client's secrets.
        #expect(DiscoveredHost(endpoint: service, txt: ["v": "2"], interfaceNames: []) == nil)
        #expect(DiscoveredHost(endpoint: service, txt: ["v": "2", "id": ""], interfaceNames: []) == nil)
        // A missing or malformed version is reported as unknown (the client won't dial it).
        #expect(DiscoveredHost(endpoint: service, txt: ["id": hostId], interfaceNames: [])?.protocolVersion == nil)
        #expect(DiscoveredHost(endpoint: service, txt: ["id": hostId, "v": "two"], interfaceNames: [])?.protocolVersion == nil)
        #expect(DiscoveredHost(endpoint: service, txt: ["id": hostId, "v": "300"], interfaceNames: [])?.protocolVersion == nil)
        #expect(DiscoveredHost(endpoint: service, txt: ["id": hostId, "v": "1"], interfaceNames: [])?.protocolVersion == 1)
        // The id is passed through as advertised: whether it is canonical is the client's check.
        #expect(DiscoveredHost(endpoint: service, txt: ["id": "not-a-uuid"], interfaceNames: [])?.hostId == "not-a-uuid")
        // Not a Bonjour service (a fixed endpoint in tests): named after the endpoint.
        let fixed = DiscoveredHost(endpoint: .hostPort(host: .ipv4(.loopback), port: 9), txt: ["id": hostId], interfaceNames: [])
        #expect(fixed?.name.isEmpty == false)
    }

    @Test func browserStatesMapToDiscoveryStates() {
        #expect(DiscoveryState(NWBrowser.State.ready) == .searching)
        #expect(DiscoveryState(NWBrowser.State.waiting(.dns(-65570))) == .denied)      // kDNSServiceErr_PolicyDenied
        #expect(DiscoveryState(NWBrowser.State.waiting(.dns(-65563))) == .searching)   // waiting for another reason
        #expect(DiscoveryState(NWBrowser.State.failed(.dns(-65569))) == .failed(NWError.dns(-65569).debugDescription))
        #expect(DiscoveryState(NWBrowser.State.setup) == nil)
        #expect(DiscoveryState(NWBrowser.State.cancelled) == nil)
    }

    @Test func fixedDiscoveryReportsItsStateAndListThenUpdates() async {
        let host = DiscoveredHost(hostId: hostId, name: "Mac mini", protocolVersion: LainProtocol.majorVersion, endpoint: service)
        let discovery = FixedHostDiscovery(hosts: [host])
        let lists = Mailbox<[DiscoveredHost]>(), states = Mailbox<DiscoveryState>()
        discovery.start(onChange: { lists.put($0) }, onState: { states.put($0) })
        #expect(await states.next() == .searching)
        #expect(await lists.next() == [host])
        discovery.update(state: .denied)
        #expect(await states.next() == .denied)
        discovery.update(hosts: [])
        #expect(await lists.next() == [])
        discovery.cancel()
        discovery.update(hosts: [host])
        discovery.update(state: .failed("gone"))
        #expect(await lists.next(within: 0.2) == nil)
        #expect(await states.next(within: 0.05) == nil)
        #expect(discovery.startCount == 1 && discovery.isCancelled)
    }

    @Test func aFixedDiscoveryCancelledBeforeStartReportsNothing() async {
        let discovery = FixedHostDiscovery(state: .failed("x"))
        discovery.cancel()
        let states = Mailbox<DiscoveryState>()
        discovery.start(onChange: { _ in }, onState: { states.put($0) })
        #expect(await states.next(within: 0.2) == nil)
    }
}
