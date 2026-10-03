#if os(macOS)
import Foundation
import LainProtocol
import LainTransport
import Network
import Synchronization
import Testing
@testable import LainClientCore
@testable import LainHostCore

/// `--bench wifi` (S9) against the real LainClient session (§7.7 D29), over loopback: the real
/// `WiFiBench.run` (a loopback-only listener, never advertised; an in-memory store) ↔ the real
/// `ClientSession` (a `FixedHostDiscovery` reporting the bench at its port, a short grace, the app's
/// retry backoff). Nothing browses or advertises.
///
/// The bench answers `Hello` with a `HelloAck` naming the advertised host, so the iPad takes each link for
/// a session that ran: after a drop it waits only its grace before redialing, never the backoff of a link
/// that ended before `HelloAck` (0.5 s doubling to 8 s, reset only by a session that ran). The reconnect
/// times S9 records are then the grace plus the link's own setup, the same after every drop.
@Suite(.serialized) struct WiFiBenchClientTests {
    /// Counts the iPad's Wi-Fi attempts (`ClientWiFiConfig.interpose`) and keeps the newest one's realtime
    /// connection, so the test can drop the link from the iPad's side, as a dead radio would.
    final class Drops: Sendable {
        private let state = Mutex<(dials: Int, realtime: (any ByteStream)?)>((0, nil))
        var dials: Int { state.withLock { $0.dials } }

        func interpose(_ inner: any StreamDialer) -> any StreamDialer {
            state.withLock { $0.dials += 1 }
            return Dialer(inner: inner, drops: self)
        }

        /// Closes the newest link's realtime connection: the iPad sees its link end, and so does the bench.
        func dropLink() { state.withLock { $0.realtime }?.close() }

        fileprivate func dialed(realtime: any ByteStream) { state.withLock { $0.realtime = realtime } }

        struct Dialer: StreamDialer {
            let inner: any StreamDialer
            let drops: Drops

            func dial() async throws -> any ByteStream { try await inner.dial() }

            func dial(kind: ConnectionKind) async throws -> any ByteStream {
                let stream = try await inner.dial(kind: kind)
                if kind == .realtime { drops.dialed(realtime: stream) }
                return stream
            }
        }
    }

    @Test func repeatedDropsReconnectAfterTheGraceNotABackoff() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let identity = HostIdentity(id: UUID().uuidString, name: "Bench Mac")
        let grace = 0.2
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lain-wifi-bench-client-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        // The bench: one long phase A that outlasts every drop; the test stops it (the Ctrl-C path).
        let port = InputLoopbackTests.Recorder<UInt16>()
        var options = WiFiBench.Options(mode: .any, seconds: 120, listener: .loopback, advertise: false,
                                        secrets: InMemorySecretStore(["IPAD-1": secret]), identity: identity,
                                        csvDirectory: folder)
        (options.pingSeconds, options.idlePingSeconds, options.loadSeconds, options.capacitySeconds) = (100, 0, 0, 0)
        options.clientGraceSeconds = grace
        options.onListening = { port.put($0) }
        let bench = Task { try await WiFiBench.run(options: options, log: { _ in }) }
        let bound = try #require(await poll { port.last })

        // The iPad holds the Mac's Wi-Fi secret and sees the bench as that Mac; the app's backoffs, a short grace.
        let drops = Drops()
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: try #require(NWEndpoint.Port(rawValue: bound)))
        let host = DiscoveredHost(hostId: identity.id, name: identity.name, versions: LainProtocol.supportedVersions,
                                  endpoint: endpoint, interfaceNames: ["lo0"], isBench: true)
        var wifi = ClientWiFiConfig(discovery: { FixedHostDiscovery(hosts: [host]) }, options: .loopback)
        wifi.grace = grace
        wifi.interpose = { drops.interpose($0) }
        let statuses = InputLoopbackTests.Recorder<ClientSession.Status>()
        let client = try ClientSession(port: 0, secrets: InMemorySecretStore([PairingAccounts.mac(identity.id): secret]),
                                       hello: M3EndToEndTests.hello(hardware444: false), wifi: wifi) { statuses.put($0) }
        defer { client.stop() }

        /// The iPad's `n`-th Wi-Fi link, once adopted.
        func linkUp(_ n: Int) async -> ClientSession.ConnectionInfo? {
            await poll(within: 15) {
                guard drops.dials == n, case .connected(let info) = statuses.last else { return nil }
                return info
            }
        }
        /// …and configured by the bench's `HelloAck`.
        func configured() async -> ClientSession.ConnectionInfo? {
            await poll(within: 2) {
                if case .connected(let info) = statuses.last, info.isConfigured { info } else { nil }
            }
        }

        // Five links, four drops: each time the iPad redials after its grace, as after any session that ran.
        for n in 1...5 {
            _ = try #require(await linkUp(n), "link \(n) never came up")
            let info = await configured()
            #expect(info?.hostName == "Bench Mac" && info?.transport == .network(interface: "lo0", peerToPeer: false),
                    "the bench's HelloAck didn't configure link \(n)")
            #expect(info?.displayPointWidth == 1376 && info?.displayPointHeight == 1032)
            if n < 5 { drops.dropLink() }
        }
        bench.cancel()
        let report = try await bench.value

        #expect(report.links.count == 5 && report.links.allSatisfy(\.measured), "\(report)")
        #expect(report.reconnects.count == 4, "\(report)")
        // Each about the grace, never growing: without HelloAck they'd take 0.5, 1, 2 and 4 s.
        for r in report.reconnects {
            #expect(r.afterDropSeconds > grace / 2 && r.afterDropSeconds < grace + 0.8, "\(report.reconnects)")
        }
        #expect(report.clientGraceSeconds == grace && report.description.contains("the iPad waits its 0.2 s grace"))
    }
}
#endif
