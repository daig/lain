import Foundation
import LainClientCore
import LainHostCore
import LainInput
import LainProtocol
import LainTelemetry
import LainTestSupport
import LainTransport
import LainUSBMux
import Synchronization
import Testing

/// Updating one side first (PROTOCOL-VERSIONING §2.3): the real client and host sessions over the fake
/// usbmuxd, each offering its own versions. The newer side translates; the older never notices.
@Suite(.serialized) struct VersionSkewLoopbackTests {
    typealias T = InputLoopbackTests

    /// This build's v3 alone (an iPad or a Mac from before v4), and both.
    static let v3 = VersionList.supported.capped(at: 3)
    static let both = VersionList.supported
    static let v4Only = VersionList(VersionList.supported.entries.filter { $0.version == 4 })

    final class SetupProbe: Sendable {
        let value = Mutex(HostSetup(items: [HostSetup.Item(.screenRecording, .missing), HostSetup.Item(.accessibility, .granted)],
                                    videoProblem: "", hasOtherDisplay: false))
    }

    final class Rig {
        let mac = T.VirtualMac(display: T.display, layout: T.layout, cursor: T.startCursor)
        let clientStatus = T.Recorder<ClientSession.Status>()
        let hostStatus = T.Recorder<HostStatus>()
        let client: ClientSession
        let mux: FakeUSBMuxd
        let host: HostSession
        /// What the Mac's probe reports; tests change it.
        let setup = SetupProbe()

        init(client clientVersions: VersionList, host hostVersions: VersionList) throws {
            let clientStatus = clientStatus, hostStatus = hostStatus, setup = setup
            client = try ClientSession(port: 0, secrets: T.CountingSecrets(), hello: T.hello, versions: clientVersions) {
                clientStatus.put($0)
            }
            mux = try FakeUSBMuxd(devices: [.init(deviceID: 7, serialNumber: "IPAD-7")], targetPort: client.port)
            let deps = HostSession.Dependencies(
                usbmux: USBMuxClient(socketPath: mux.socketPath), secrets: T.CountingSecrets(), sink: mac, display: mac,
                power: T.FakePower(), settings: { T.settings }, setup: { setup.value.withLock { $0 } }, versions: hostVersions)
            host = HostSession(dependencies: deps) { hostStatus.put($0) }
        }

        func tearDown() {
            host.stop()
            mux.stop()
            client.stop()
        }

        var info: ClientSession.ConnectionInfo? {
            if case .connected(let info) = clientStatus.last { info } else { nil }
        }
    }

    @Test func bothNewestTheIPadHearsTheMacsSetupAndItsChanges() async throws {
        let rig = try Rig(client: Self.both, host: Self.both)
        defer { rig.tearDown() }
        rig.host.start()
        #expect(await eventually { rig.info?.setup != nil })
        let info = try #require(rig.info)
        #expect(info.protocolVersion == 4 && info.olderMacMisses.isEmpty && ClientStatus.olderMacNote(info) == nil)
        #expect(info.setup?.missing == [.screenRecording])
        #expect(ClientStatus(.connected(info)).detail.contains("Finish setup on the Mac: allow Screen Recording"))
        #expect(rig.host.peerVersionNote == nil)
        // The owner grants Screen Recording: the next poll tells the iPad.
        rig.setup.value.withLock { $0.items[0].state = .granted }
        rig.host.setupChanged()
        #expect(await eventually { rig.info?.setup?.missing == [] })
        #expect(ClientStatus.setupHint(try #require(rig.info?.setup)) == nil)
    }

    @Test func anOlderIPadWorksWithANewerMacWhichSaysWhatUpdatingAdds() async throws {
        let rig = try Rig(client: Self.v3, host: Self.both)
        defer { rig.tearDown() }
        rig.host.start()
        #expect(await eventually { rig.info?.isConfigured == true })
        #expect(await eventually { rig.hostStatus.last == .connected(deviceModel: "iPad16,6") })
        #expect(rig.info?.protocolVersion == 3)
        // Input flows as in v3.
        rig.client.input.sync { $0.keyChanged(T.keyA, isDown: true, at: MonotonicClock.now()) }
        #expect(await eventually { !rig.mac.inputCalls.isEmpty })
        // No HostSetup reaches a v3 iPad (it couldn't parse it); the Mac's menu says what updating adds.
        rig.host.setupChanged()
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.info?.setup == nil && rig.info?.olderMacMisses == [])
        #expect(rig.host.peerVersionNote == "lain on the iPad is older (protocol v3): update it for setup status on the iPad")
    }

    @Test func aNewerIPadWorksWithAnOlderMacAndSaysWhatUpdatingAdds() async throws {
        let rig = try Rig(client: Self.both, host: Self.v3)
        defer { rig.tearDown() }
        rig.host.start()
        #expect(await eventually { rig.info?.isConfigured == true })
        let info = try #require(rig.info)
        #expect(info.protocolVersion == 3 && info.setup == nil)
        #expect(info.olderMacMisses == [.hostSetup])
        #expect(ClientStatus.olderMacNote(info) == "The Mac's lain is older (protocol v3): update it for setup status on the iPad")
        #expect(rig.host.peerVersionNote == nil)   // from the Mac's side nothing is missing
    }

    @Test func noCommonVersionNamesTheSideToUpdateOnBoth() async throws {
        let rig = try Rig(client: Self.v4Only, host: Self.v3)
        defer { rig.tearDown() }
        rig.host.start()
        let olderMac = ClientSession.Status.versionMismatch(hostName: nil, gap: .peerOlder(peer: "protocol v3"))
        #expect(await eventually { rig.clientStatus.last == olderMac })
        #expect(ClientStatus(olderMac).detail.contains("update lain on the Mac"))
        #expect(await eventually { rig.hostStatus.last == HostStatus.versionGap(.peerNewer(peer: "protocol v4")) })
        #expect(rig.host.status.title.contains("update lain on this Mac"))
        #expect(rig.mac.inputCalls.isEmpty)
    }
}

private func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
