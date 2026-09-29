#if os(macOS)
import Dispatch
import Foundation
import LainProtocol
import LainTransport
import Network
import Synchronization
import Testing
@testable import LainHostCore

// `--bench wifi` (S9): the statistics as pure functions of fixed samples, the command line and the path
// rules, and short runs of the real bench over loopback against an in-test iPad. Loopback only: never
// advertised, nothing browses.

@Suite struct BenchStatisticsTests {
    @Test func percentilesAreNearestRank() {
        let thousand = BenchStats.Distribution((1...1000).map(Double.init).shuffled())
        #expect(thousand.count == 1000 && thousand.p50 == 500 && thousand.p90 == 900 && thousand.p99 == 990)
        #expect(thousand.p999 == 999 && thousand.max == 1000)
        let ten = BenchStats.Distribution((1...10).map(Double.init))
        #expect(ten.p50 == 5 && ten.p90 == 9 && ten.p99 == 10 && ten.p999 == 10 && ten.max == 10)
        let one = BenchStats.Distribution([3.5])
        #expect(one.p50 == 3.5 && one.p999 == 3.5 && one.max == 3.5)
        let none = BenchStats.Distribution([])
        #expect(none.count == 0 && none.p50 == nil && none.max == nil)
        #expect(BenchStats.percentile([1, 2, 3, 4], 0.75) == 3)
        #expect(BenchStats.percentile([1, 2, 3, 4], 0.76) == 4)
        #expect(BenchStats.percentile([1, 2, 3, 4], 0) == 1)
    }

    @Test func theHistogramHasLog2Buckets() {
        typealias Histogram = BenchStats.Histogram
        #expect(Histogram.labels == ["≤1", "≤2", "≤4", "≤8", "≤16", "≤32", "≤64", "≤128", ">128"])
        #expect([0.2, 1, 1.01, 2, 2.5, 4, 7.9, 16, 16.7, 33.3, 64, 100, 128, 128.01, 5000].map(Histogram.bucket)
                == [0, 0, 1, 1, 2, 2, 3, 4, 5, 6, 6, 7, 7, 8, 8])
        #expect(Histogram([0.5, 0.9, 3, 3, 3, 150]).counts == [2, 0, 3, 0, 0, 0, 0, 0, 1])
    }

    @Test func aStallIsTimeWithAFrameInFlightAndNoAck() {
        let ms: UInt64 = 1_000_000
        /// P-frames only: the gaps' lengths, each ended by a P-frame.
        func stallGaps(_ frames: [(sentNs: UInt64, ackNs: UInt64?)], endNs: UInt64) -> [UInt64] {
            let gaps = BenchStats.stallGaps(frames.map { ($0.sentNs, $0.ackNs, false) }, endNs: endNs)
            #expect(gaps.allSatisfy { !$0.isKeyframe })
            return gaps.map(\.ns)
        }
        // Each frame acked within 5 ms, the window empty in between: no stall.
        #expect(stallGaps([(0, 5 * ms), (8 * ms, 13 * ms), (16 * ms, 21 * ms)], endNs: 30 * ms) == [5 * ms, 5 * ms, 5 * ms])
        // Two in flight, then 60 ms without an ack: one stall; the second ack follows at once.
        let piled = stallGaps([(0, 60 * ms), (8 * ms, 61 * ms)], endNs: 100 * ms)
        #expect(piled == [60 * ms, 1 * ms])
        // Unacknowledged at the end: the gap runs from the last ack to the end, once.
        let tail = stallGaps([(0, 10 * ms), (20 * ms, nil), (28 * ms, nil)], endNs: 300 * ms)
        #expect(tail == [10 * ms, 280 * ms])
        // An ack and a send at one instant: the ack frees the window first.
        #expect(stallGaps([(0, 10 * ms), (10 * ms, 12 * ms)], endNs: 20 * ms) == [10 * ms, 2 * ms])
        #expect(BenchStats.stallGaps([], endNs: 1).isEmpty)
        let stalls = BenchStats.Stalls(gapsMs: (piled + tail).map { Double($0) / 1e6 })
        #expect(stalls.counts == [2, 1, 1] && stalls.longestMs == 280)
        #expect(BenchStats.Stalls(gapsMs: []).counts == [0, 0, 0] && BenchStats.Stalls(gapsMs: []).longestMs == 0)

        // Each gap belongs to the frame whose ack ends it, the oldest in flight. A keyframe's 80 ms transfer
        // is a keyframe gap; the P-frame queued behind it waits only from the keyframe's ack.
        typealias Gap = BenchStats.StallGap
        #expect(BenchStats.stallGaps([(0, 80 * ms, true), (8 * ms, 81 * ms, false)], endNs: 100 * ms)
                == [Gap(ns: 80 * ms, isKeyframe: true), Gap(ns: 1 * ms, isKeyframe: false)])
        // A 200 ms stall on a P-frame stays a P-frame stall, although a keyframe went out behind it.
        #expect(BenchStats.stallGaps([(100 * ms, 300 * ms, false), (108 * ms, 390 * ms, true)], endNs: 400 * ms)
                == [Gap(ns: 200 * ms, isKeyframe: false), Gap(ns: 90 * ms, isKeyframe: true)])
        // The unacknowledged tail belongs to the oldest frame still unacknowledged.
        #expect(BenchStats.stallGaps([(0, 10 * ms, false), (20 * ms, nil, true), (28 * ms, nil, false)], endNs: 300 * ms)
                == [Gap(ns: 10 * ms, isKeyframe: false), Gap(ns: 280 * ms, isKeyframe: true)])
        #expect(BenchStats.stallGaps([(0, 10 * ms, true), (20 * ms, nil, false), (28 * ms, nil, true)], endNs: 300 * ms)
                == [Gap(ns: 10 * ms, isKeyframe: true), Gap(ns: 280 * ms, isKeyframe: false)])
    }

    @Test func throughputIsCountedPerFullSecond() {
        let s: UInt64 = 1_000_000_000
        let acks: [(atNs: UInt64, bytes: Int)] = [
            (s / 2, 7),                                   // before the start
            (s + s / 10, 1_000_000), (s + 9 * s / 10, 1_000_000), (2 * s, 3_000_000), (3 * s - 1, 1_000_000),
            (3 * s + s / 5, 5_000_000),                   // in the partial last second
        ]
        #expect(BenchStats.perSecondMBps(acks, startNs: s, endNs: s + 5 * s / 2) == [2, 4])
        #expect(BenchStats.perSecondMBps(acks, startNs: s, endNs: s + s / 2).isEmpty)
    }
}

@Suite struct WiFiBenchCommandLineTests {
    @Test func theBenchTakesAModeAndSeconds() throws {
        let plain = try WiFiBench.parse([])
        #expect(plain.mode == .any && plain.seconds == 180)
        let awdl = try WiFiBench.parse(["awdl", "180"])
        #expect(awdl.mode == .awdl && awdl.seconds == 180)
        let reversed = try WiFiBench.parse(["90.5", "LAN"])
        #expect(reversed.mode == .lan && reversed.seconds == 90.5)
        for bad in [["wifi6"], ["awdl", "lan"], ["0"], ["-5"], ["60", "90"], ["inf"]] {
            #expect(throws: WiFiBench.UsageError.self, "\(bad)") { try WiFiBench.parse(bad) }
        }
        #expect(BenchCommand.names.contains("wifi"))
        #expect(BenchCommand.arguments(in: ["LainHost", "--bench", "wifi", "awdl", "180"]) == ["awdl", "180"])
        #expect(BenchCommand.arguments(in: ["LainHost", "--bench", "wifi", "lan", "-NSDocumentRevisionsDebugMode", "YES"])
                == ["lan"])
        #expect(BenchCommand.arguments(in: ["LainHost", "--bench", "wifi", "-5"]) == ["-5"])
        #expect(BenchCommand.arguments(in: ["LainHost", "--bench", "wifi"]).isEmpty)
        #expect(BenchCommand.arguments(in: ["LainHost", "--bench"]).isEmpty)
    }

    @Test func theHelloAckNamesTheAdvertisedHost() {
        // What the iPad needs to take a bench link for a session that ran (§7.7 D29): the advertised id (over
        // Wi-Fi, the one it dialed) and name; its own screen in points as the display.
        let identity = HostIdentity(id: "0C3F8A52-6E1B-4D57-9A0E-2B7C4F1D8E36", name: "Bench Mac")
        let ack = WiFiBench.helloAck(for: BenchIPad.hello, identity: identity)
        #expect(ack.hostId == identity.id && ack.hostName == "Bench Mac")
        #expect(ack.displayPointWidth == 1376 && ack.displayPointHeight == 1032 && ack.refreshRate == 120)
        #expect(ack.macInputSource == "lain.bench" && ack.keyRepeatIntervalMs > 0 && ack.doubleClickIntervalMs > 0)
    }

    @Test func aRunsFilesShareOneName() throws {
        // The raw samples and the text (the live log and the report) sit side by side, one name.
        let folder = URL(fileURLWithPath: "/tmp/lain-bench-files")
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: .current, year: 2026, month: 9, day: 30, hour: 9, minute: 15, second: 2)))
        let files = WiFiBench.outputFiles(mode: .awdl, in: folder, at: date)
        #expect(files.csv.lastPathComponent == "lain-s9-awdl-20260930-091502.csv")
        #expect(files.report.lastPathComponent == "lain-s9-awdl-20260930-091502.txt")
        #expect(files.csv.deletingLastPathComponent().path == folder.path)
        #expect(files.report.deletingLastPathComponent().path == folder.path)
    }

    @Test func anotherRunningLainIsNamedWithTheWayBack() {
        let message = WiFiBench.anotherInstanceMessage(pids: [812])
        #expect(message.contains("pid 812") && message.contains("Quit lain from the menu bar first"))
        #expect(message.contains("launchctl kickstart gui/$(id -u)/sub.dev.lain.host.agent"))
    }

    @Test func lanModeKeepsTheListenerOffPeerToPeer() {
        #expect(!WiFiBench.listenerOptions(for: .lan).includePeerToPeer)
        #expect(WiFiBench.listenerOptions(for: .awdl).includePeerToPeer)
        #expect(WiFiBench.listenerOptions(for: .any).includePeerToPeer)
        #expect(WiFiBench.Mode.allCases.allSatisfy { !WiFiBench.listenerOptions(for: $0).loopbackOnly })
    }

    @Test func awdlModeMeasuresOnlyPeerToPeerLinks() {
        func paths(_ names: [(String, NetworkPath.Kind)]) -> [NetworkPath] {
            names.map { name, kind in
                var path = NetworkPath(interface: nil)
                path.interfaceName = name
                path.kind = kind
                return path
            }
        }
        let awdl = paths([("awdl0", .peerToPeer), ("awdl0", .peerToPeer), ("awdl0", .peerToPeer)])
        let lan = paths([("en1", .wifi), ("en1", .wifi), ("en1", .wifi)])
        let clean = WiFiBench.check(awdl, mode: .awdl)
        #expect(clean.measure && clean.notes == ["all three connections on awdl0"])
        let refused = WiFiBench.check(lan, mode: .awdl)
        #expect(!refused.measure && refused.refusal?.contains("not peer-to-peer") == true)
        #expect(refused.notes.contains { $0.contains("over en1 (Wi-Fi), not AWDL") })
        #expect(WiFiBench.check(lan, mode: .lan).measure && WiFiBench.check(lan, mode: .any).measure)
        // The cable's USB-Ethernet link is wired: measured outside awdl mode, with a warning.
        let cable = WiFiBench.check(paths([("en8", .wired), ("en8", .wired), ("en8", .wired)]), mode: .any)
        #expect(cable.measure && cable.notes.contains { $0.contains("en8 is a wired path") && $0.contains("unplug") })
        #expect(!WiFiBench.check(paths([("en8", .wired), ("en8", .wired), ("en8", .wired)]), mode: .awdl).measure)
        // Three connections that didn't share one path are flagged.
        let split = WiFiBench.check(paths([("awdl0", .peerToPeer), ("en1", .wifi), ("awdl0", .peerToPeer)]), mode: .any)
        #expect(split.measure && split.notes.contains { $0.contains("different interfaces") && $0.contains("video en1") })
        #expect(!WiFiBench.check(Array(awdl.prefix(2)), mode: .any).measure)
    }
}

/// The iPad's side of the bench, as LainClient behaves (§7.7): it dials with its pairing's PSK and
/// secret, sends `Hello`, answers pings and acks every frame on arrival (or `ackDelay` seconds later: a
/// slow link). With `keyframeDelay`, each keyframe takes that long to arrive, and the frames behind it
/// wait, in order, as on one TCP stream.
enum BenchIPad {
    static let hello = Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                             decodeCapabilities: [.hevcMain], keyboardType: .ansi)

    static func connect(port: UInt16, secret: [UInt8], ackDelay: Double = 0, keyframeDelay: Double = 0,
                        onHelloAck: @escaping @Sendable (HelloAck) -> Void = { _ in },
                        onFrame: @escaping @Sendable (VideoFrame) -> Void = { _ in }) async throws -> Link {
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: try #require(NWEndpoint.Port(rawValue: port)))
        let dialer = WiFiLinkDialer(endpoint: endpoint, psk: WiFiPSK(secret: secret), options: .loopback)
        let link = try await LinkDialer(dialer: dialer, label: "test.ipad").open(secret: secret)
        link.realtime.setHandler { env in
            switch env.message {
            case .ping(let ping):
                let received = DispatchTime.now().uptimeNanoseconds
                link.realtime.send(.pong(Pong(id: ping.id, pingSentAtNs: ping.sentAtNs, receivedAtNs: received,
                                              sentAtNs: DispatchTime.now().uptimeNanoseconds)))
            case .helloAck(let ack):
                onHelloAck(ack)
            default:
                break
            }
        }
        link.video.setHandler { env in
            guard case .videoFrame(let frame) = env.message else { return }
            // Holds the video channel's queue: what the Mac sent after the keyframe arrives after it.
            if frame.isKeyframe, keyframeDelay > 0 { Thread.sleep(forTimeInterval: keyframeDelay) }
            let ack = FrameAck(frameId: frame.frameId, receivedAtNs: DispatchTime.now().uptimeNanoseconds,
                               bytes: UInt32(frame.data.count))
            if ackDelay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + ackDelay) { link.video.send(.frameAck(ack)) }
            } else {
                link.video.send(.frameAck(ack))
            }
            onFrame(frame)
        }
        link.audio.setHandler { _ in }
        link.realtime.send(.hello(hello))
        return link
    }
}

/// The bench's live lines, in order.
final class BenchLog: Sendable {
    private let lines = Mutex<[String]>([])
    func put(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}

/// The real `WiFiBench.run` over loopback: an in-memory store with one iPad's secret, a fixed host
/// identity, phases of a second or two, the files in a temporary folder.
@Suite(.serialized) struct WiFiBenchLoopbackTests {
    let secret = ChannelAuth.randomBytes(32)
    let identity = HostIdentity(id: UUID().uuidString, name: "Bench Test Mac")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lain-wifi-bench-\(UUID().uuidString)")

    func benchOptions(_ mode: WiFiBench.Mode = .any, seconds: Double, phases: [Double], port: Inbox<UInt16>) -> WiFiBench.Options {
        var options = WiFiBench.Options(mode: mode, seconds: seconds, listener: .loopback, advertise: false,
                                        secrets: InMemorySecretStore(["IPAD-1": secret]), identity: identity,
                                        csvDirectory: folder)
        options.pingSeconds = phases[0]
        options.idlePingSeconds = phases[1]
        options.loadSeconds = phases[2]
        options.capacitySeconds = phases[3]
        options.onListening = { port.put($0) }
        return options
    }

    @Test func aShortRunReportsEveryPhase() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let port = Inbox<UInt16>()
        let acks = Inbox<HelloAck>()
        let logged = BenchLog()
        let options = benchOptions(seconds: 30, phases: [1, 0.5, 1.5, 1.2], port: port)
        async let running = WiFiBench.run(options: options, log: { logged.put($0) })
        let link = try await BenchIPad.connect(port: try #require(await port.next()), secret: secret,
                                               onHelloAck: { acks.put($0) })
        let report = try await running
        link.close()
        print(report)

        #expect(report.complete, "\(report)")
        #expect(report.links.count == 1 && report.reconnects.isEmpty)
        // Hello answered with the advertised host (the iPad takes the link for a session that ran) and the
        // iPad's own screen in points.
        let ack = try #require(await acks.next(within: 1))
        #expect(ack.hostId == identity.id && ack.hostName == identity.name)
        #expect(ack.displayPointWidth == 1376 && ack.displayPointHeight == 1032)
        // Setup: the three connections share the loopback interface, under TLS 1.2 ECDHE-PSK 0xCCAC.
        let measured = try #require(report.measuredLink)
        #expect(measured.peer == "IPAD-1" && measured.deviceModel == "iPad16,6")
        #expect(measured.interfaces.count == 3 && Set(measured.interfaces).count == 1 && !measured.interfaces[0].isEmpty)
        #expect(measured.kinds == [.loopback, .loopback, .loopback])
        #expect(measured.tls.count == 3
                && measured.tls.allSatisfy { $0 == NegotiatedTLS(version: WiFiTLS.version, cipherSuite: WiFiTLS.cipherSuite) })
        #expect(measured.handshakeMs.allSatisfy { $0 > 0 && $0 < 5000 })
        // A: every ping answered, at 120 Hz and at 10 Hz.
        let a = try #require(report.pings), idle = try #require(report.idlePings)
        #expect(a.complete && a.intervalMs > 8.3 && a.intervalMs < 8.4 && a.sent > 30 && a.lost == 0)
        #expect(a.rtt.count == a.sent && (a.rtt.p50 ?? 0) > 0 && (a.rtt.max ?? .infinity) < 1000)
        #expect(a.histogram.counts.reduce(0, +) == a.received && a.over.count == 3)
        #expect(idle.complete && idle.intervalMs == 100 && idle.sent >= 3 && idle.lost == 0)
        // B: frames through the N = 2 window, a keyframe first, pings under load.
        let b = try #require(report.load)
        #expect(b.complete && b.framesSent > 30 && b.keyframesSent >= 1 && b.framesAcked == b.framesSent)
        #expect(b.keyframeAck.count == b.keyframesSent && (b.frameAck.p50 ?? 0) > 0 && b.fps > 20)
        #expect(b.pings.sent > 30 && b.pings.lost == 0)
        #expect(b.frameStalls.counts.count == 3 && b.keyframeStalls.counts.count == 3)
        // C: at least one full second of capacity.
        let c = try #require(report.capacity)
        #expect(c.complete && !c.perSecondMBps.isEmpty && (c.median ?? 0) > 5 && c.averageMBps > 5)
        #expect(report.summary.hasPrefix("S9 --bench wifi any over ") && report.description.contains("suite 0xCCAC"))

        // The raw samples of every phase.
        let rows = try String(contentsOfFile: try #require(report.csvPath), encoding: .utf8).split(separator: "\n")
        #expect(rows.first.map(String.init) == WiFiBench.csvHeader)
        for kind in ["A120,ping,", "A10,ping,", "B,ping,", "B,frame,", "B,keyframe,", "C,chunk,", "-,link,1,1,"] {
            #expect(rows.contains { $0.hasPrefix(kind) }, "no \(kind) rows")
        }
        #expect(rows.count(where: { $0.hasPrefix("A120,ping,") }) == a.sent)
        #expect(flights(in: rows).count == b.framesSent)

        // The whole live log, then the report, in a text file next to the CSV: the results never depend on
        // stdout. Both paths come first in the log, and again in the report.
        let csv = try #require(report.csvPath), text = try #require(report.reportPath)
        #expect(text.hasSuffix(".txt") && text.dropLast(4) == csv.dropLast(4))
        let lines = logged.all
        #expect(lines.first?.contains(text) == true && lines.first?.contains(csv) == true)
        #expect(lines.contains { $0.contains("phase C: capacity") } && lines.last?.contains("bench done") == true)
        #expect(report.description.contains("raw samples: \(csv)") && report.description.contains("log and report: \(text)"))
        #expect(try String(contentsOfFile: text, encoding: .utf8)
                == lines.map { $0 + "\n" }.joined() + "\n" + report.description + "\n")
    }

    @Test func theAckWindowHoldsFramesBackWhenAcksLag() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // An iPad whose acks come 20 ms late: at 120 Hz the N = 2 window fills and ticks become drops.
        let port = Inbox<UInt16>()
        let options = benchOptions(seconds: 30, phases: [0, 0, 1, 0], port: port)
        async let running = WiFiBench.run(options: options, log: { _ in })
        let link = try await BenchIPad.connect(port: try #require(await port.next()), secret: secret, ackDelay: 0.02)
        let report = try await running
        link.close()

        let b = try #require(report.load)
        #expect(b.complete && b.framesSent > 10 && b.drops > 10 && b.fps < 110 && (b.frameAck.p50 ?? 0) >= 20)
        let rows = try String(contentsOfFile: try #require(report.csvPath), encoding: .utf8).split(separator: "\n")
        let frames = flights(in: rows)
        #expect(frames.count == b.framesSent)
        #expect(frames.allSatisfy { frame in frames.filter { $0.sent <= frame.sent && $0.acked > frame.sent }.count <= 2 })
    }

    /// Phase B's frames from the CSV: when each was sent and acked (ms).
    func flights(in rows: [Substring]) -> [(sent: Double, acked: Double)] {
        rows.filter { $0.hasPrefix("B,frame,") || $0.hasPrefix("B,keyframe,") }.compactMap { row in
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            guard let sent = Double(fields[4]), let acked = Double(fields[5]) else { return nil }
            return (sent, acked)
        }
    }

    @Test func aDroppedLinkIsCountedAndItsPhaseGoesOnOverTheNextOne() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let port = Inbox<UInt16>()
        let frames = Inbox<UInt32>()
        let acks = Inbox<HelloAck>()
        let options = benchOptions(seconds: 30, phases: [0.3, 0, 2, 0], port: port)
        async let running = WiFiBench.run(options: options, log: { _ in })
        let bound = try #require(await port.next())
        let first = try await BenchIPad.connect(port: bound, secret: secret, onHelloAck: { acks.put($0) }) {
            frames.put($0.frameId)
        }
        for _ in 0..<10 { #expect(await frames.next() != nil) }
        first.close()   // mid phase B; the iPad redials at once
        let second = try await BenchIPad.connect(port: bound, secret: secret, onHelloAck: { acks.put($0) })
        let report = try await running
        second.close()

        #expect(report.complete, "\(report)")
        #expect(report.links.count == 2 && report.links.allSatisfy(\.measured) && report.links[0].endReason != nil)
        #expect(report.reconnects.count == 1)
        // Each link's Hello answered; the reconnect time printed with and without the iPad's grace.
        for _ in 0..<2 { #expect(await acks.next(within: 1)?.hostId == identity.id) }
        #expect(report.clientGraceSeconds == 1.5)
        #expect(report.description.contains("the iPad waits its 1.5 s grace before it redials"))
        let b = try #require(report.load)
        // Connected time adds up to the phase; each link starts with a keyframe, as the pipeline would.
        #expect(b.complete && b.seconds >= 1.99 && b.keyframesSent >= 2 && b.framesSent > 10)
        #expect(report.idlePings == nil && report.capacity == nil)
    }

    @Test func awdlModeTurnsAwayALinkThatIsNotPeerToPeer() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let port = Inbox<UInt16>()
        let closed = Inbox<Bool>()
        let options = benchOptions(.awdl, seconds: 1.5, phases: [1, 1, 1, 1], port: port)
        async let running = WiFiBench.run(options: options, log: { _ in })
        let link = try await BenchIPad.connect(port: try #require(await port.next()), secret: secret)
        link.realtime.setCloseHandler { _ in closed.put(true) }
        #expect(await closed.next(within: 2) == true)   // loopback isn't AWDL
        let report = try await running
        link.close()

        #expect(!report.complete && report.measuredLink == nil && report.links.count == 1)
        #expect(report.links[0].endReason?.contains("not peer-to-peer") == true)
        #expect(report.pings == nil && report.load == nil && report.capacity == nil)
        #expect(report.summary.contains("no link measured"))
    }

    @Test func stoppingEndsTheRunWithWhatWasMeasured() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // Ctrl-C cancels the bench's task: the report and the CSV still come, partial.
        let port = Inbox<UInt16>()
        let options = benchOptions(seconds: 30, phases: [5, 5, 5, 5], port: port)
        let running = Task { try await WiFiBench.run(options: options, log: { _ in }) }
        let link = try await BenchIPad.connect(port: try #require(await port.next()), secret: secret)
        try await Task.sleep(for: .milliseconds(500))
        running.cancel()
        let report = try await running.value
        link.close()

        #expect(report.endedBy == "stopped" && !report.complete && report.elapsedSeconds < 5)
        #expect((report.pings?.sent ?? 0) > 10 && report.pings?.complete == false)
        #expect(report.idlePings == nil && report.load == nil && report.capacity == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(report.csvPath)))
        // The partial phase, the end and the report with its §13 line are in the text file, stdout or not.
        let text = try String(contentsOfFile: try #require(report.reportPath), encoding: .utf8)
        #expect(text.contains("A @120 Hz, ") && text.contains("(partial)") && text.contains("bench ended: stopped"))
        #expect(text.hasSuffix("\n" + report.description + "\n") && report.description.contains("§13: S9 --bench wifi"))
    }

    @Test func aSetupThatFailsLeavesNoFiles() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // No paired iPad: nothing to measure, so neither the text file nor the CSV stays behind.
        let options = WiFiBench.Options(mode: .any, seconds: 5, listener: .loopback, advertise: false,
                                        secrets: InMemorySecretStore(), identity: identity, csvDirectory: folder)
        await #expect(throws: WiFiBench.Failure.noPairedIPad) { try await WiFiBench.run(options: options, log: { _ in }) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func aKeyframesOwnTransferIsNotATransportStall() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // Each keyframe takes 150 ms to arrive, as on a slow link, and the P-frames behind it wait for it:
        // those waits count as keyframe stalls. The P-frames themselves, acked at once, show no stall.
        let port = Inbox<UInt16>()
        let options = benchOptions(seconds: 30, phases: [0, 0, 2.2, 0], port: port)
        async let running = WiFiBench.run(options: options, log: { _ in })
        let link = try await BenchIPad.connect(port: try #require(await port.next()), secret: secret, keyframeDelay: 0.15)
        let report = try await running
        link.close()

        let b = try #require(report.load)
        #expect(b.complete && b.keyframesSent >= 2 && b.framesAcked == b.framesSent, "\(report)")
        #expect(b.keyframeStalls.counts[1] == b.keyframesSent && b.keyframeStalls.longestMs >= 150)
        // (> 100 ms: a margin for a busy machine.)
        #expect(b.frameStalls.counts[1] == 0 && b.frameStalls.longestMs < b.keyframeStalls.longestMs)
        let transport = "transport (50 KB P-frames) \(b.frameStalls.counts.map(String.init).joined(separator: "/"))"
        #expect(report.summary.contains(transport), "\(report.summary)")
    }

    @Test func resultsArePartialByTheDeadline() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // 4 s of phases under a 3.5 s deadline: sending stops 2 s before it (the last drain), so A @10 Hz
        // (or A itself) is cut short and B and C never start. The report and the CSV are ready in time.
        let port = Inbox<UInt16>()
        let options = benchOptions(seconds: 3.5, phases: [1, 1, 1, 1], port: port)
        async let running = WiFiBench.run(options: options, log: { _ in })
        let link = try await BenchIPad.connect(port: try #require(await port.next()), secret: secret)
        let report = try await running
        link.close()

        #expect(!report.complete && report.endedBy?.contains("deadline") == true, "\(report)")
        #expect(report.elapsedSeconds < 3.5)
        #expect((report.pings?.sent ?? 0) > 0 && report.pings?.lost == 0)
        #expect(report.pings?.complete == false || report.idlePings?.complete == false)
        #expect(report.load == nil && report.capacity == nil)
        #expect(FileManager.default.fileExists(atPath: try #require(report.csvPath)))
        #expect(report.description.contains("PARTIAL") && report.description.contains("B under load: not run"))
    }
}
#endif
