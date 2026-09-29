#if os(macOS)
import Foundation
import LainProtocol
import LainTelemetry
import LainTransport
import Network

/// `LainHost --bench wifi [any|awdl|lan] [seconds]` (M6a, S9; §7.7, §13): the Wi-Fi link measured from
/// the Mac while the iPad's normal LainClient is connected (cable out, lain in the foreground). The
/// bench advertises like the app (the same host id, plus TXT `bench=1`) and accepts with every stored
/// iPad secret; it never pairs. The client sends `Hello`, answers pings and acks every `VideoFrame`;
/// the bench sends no `HelloAck` and ignores `KeyframeRequest`s.
///
/// - Phase A: a ping every 8.33 ms whether or not pongs come back (a stall shows as the burst of input
///   that would have waited behind it), then 10 s at 10 Hz, the idle cadence.
/// - Phase B: the same pings while emulating the pipeline: every 8.33 ms a 50 KB `VideoFrame` if the
///   ack window has room (`FrameAckWindow(maxInFlight: 2)`, §7.3), else a drop; a 1.3 MB keyframe
///   every 2 s (and first on every link). Input under load (invariant 3), frame and keyframe
///   send → ack, fps, drops and stalls.
/// - Phase C: capacity, 3 × 1 MB in flight.
///
/// Phases count connected time: a dropped link is logged and its phase goes on over the iPad's next
/// link. Sending stops `drainNs` before the overall deadline, so the results (partial if need be) are
/// ready by then. Raw samples go to a CSV (`csvHeader`).
public enum WiFiBench {
    /// Which path to measure (§7.7). `awdl`: only links whose realtime connection is peer-to-peer
    /// (awdl*/llw*); the iPad must be off the home network with Wi-Fi on. `lan`: the listener stays off
    /// peer-to-peer interfaces. `any`: whichever path Network.framework picks (daily use).
    public enum Mode: String, Sendable, CaseIterable {
        case any, awdl, lan
    }

    public static let defaultSeconds = 180.0
    /// 120 Hz: the input and frame cadence.
    static let tickNs: UInt64 = 8_333_333
    /// The idle cadence (the 10 Hz ping of `--bench replug`).
    static let idleTickNs: UInt64 = 100_000_000
    /// A P-frame of the 48 Mbps stream at 120 fps.
    public static let frameBytes = 50_000
    /// The M6's real-time 4:4:4 keyframes are 1.2–1.3 MB (§13).
    public static let keyframeBytes = 1_300_000
    static let keyframeIntervalNs: UInt64 = 2_000_000_000
    public static let capacityChunkBytes = 1_000_000
    static let capacityInFlight = 3
    /// The pipeline's ack window (§7.3).
    static let pipelineInFlight = 2
    /// How long pongs and acks outstanding at a phase's end may take; sending stops this long before
    /// the deadline.
    static let drainNs: UInt64 = 2_000_000_000
    /// The client sends `Hello` first (§7.1); a link that doesn't is closed.
    static let helloTimeoutNs: UInt64 = 5_000_000_000
    static let progressIntervalNs: UInt64 = 5_000_000_000
    static let waitingReminderNs: UInt64 = 15_000_000_000
    /// Ping RTTs counted above two frames at 120 Hz, two at 60 Hz, and 100 ms.
    public static let pingThresholdsMs: [Double] = [16.7, 33.3, 100]
    /// `phase` A120, A10, B, C or `-` (link rows); `kind` ping, frame, keyframe, chunk, link or
    /// link-refused; times in ms since the bench started; `value_ms` is a ping's RTT without the iPad's
    /// handling time, or a frame's send → ack; empty `done_ms`: never answered.
    public static let csvHeader = "phase,kind,id,link,sent_ms,done_ms,value_ms,bytes"

    public struct Options: Sendable {
        public var mode: Mode
        /// The overall deadline, from the start.
        public var seconds: Double
        /// Connected time per phase (A at 120 Hz, then at 10 Hz; B; C); 0 skips a phase.
        public var pingSeconds = 30.0
        public var idlePingSeconds = 10.0
        public var loadSeconds = 60.0
        public var capacitySeconds = 20.0
        /// `listenerOptions(for:)` for the real bench; `.loopback` in tests.
        public var listener: NetworkStreamOptions
        /// Bonjour, as the app advertises (plus TXT `bench=1`). Never in tests.
        public var advertise: Bool
        /// Every stored iPad secret becomes a PSK and an acceptor candidate.
        public var secrets: any SecretStore
        public var identity: HostIdentity
        /// Where `lain-s9-<mode>-<time>.csv` goes.
        public var csvDirectory: URL
        /// The listener is ready on this port (tests dial it).
        public var onListening: @Sendable (UInt16) -> Void = { _ in }

        public init(mode: Mode, seconds: Double = WiFiBench.defaultSeconds, listener: NetworkStreamOptions, advertise: Bool,
                    secrets: any SecretStore, identity: HostIdentity, csvDirectory: URL) {
            self.mode = mode
            self.seconds = seconds
            self.listener = listener
            self.advertise = advertise
            self.secrets = secrets
            self.identity = identity
            self.csvDirectory = csvDirectory
        }

        /// The owner's run: the Keychain's iPad secrets, this Mac's host id, advertised, the CSV in the
        /// home folder.
        public static func live(mode: Mode, seconds: Double) throws -> Options {
            Options(mode: mode, seconds: seconds, listener: WiFiBench.listenerOptions(for: mode), advertise: true,
                    secrets: KeychainSecretStore(), identity: try HostIdentity.load(),
                    csvDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
    }

    /// `lan` keeps the listener, and so its advertisement, off AWDL; `awdl` and `any` keep peer-to-peer
    /// on, as the app does.
    public static func listenerOptions(for mode: Mode) -> NetworkStreamOptions {
        NetworkStreamOptions(includePeerToPeer: mode != .lan)
    }

    public enum Failure: Error, CustomStringConvertible {
        case noPairedIPad

        public var description: String {
            switch self {
            case .noPairedIPad: "no paired iPad in this Mac's Keychain: pair over USB first (a normal USB session)"
            }
        }
    }

    // MARK: Command line

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    public static let usage = "usage: LainHost --bench wifi [any|awdl|lan] [seconds, default 180]"

    /// `[any|awdl|lan] [seconds]`, in either order; defaults `any` and 180 s.
    public static func parse(_ words: [String]) throws(UsageError) -> (mode: Mode, seconds: Double) {
        var mode: Mode?
        var seconds: Double?
        for word in words {
            if let m = Mode(rawValue: word.lowercased()) {
                guard mode == nil else { throw UsageError(description: "two modes: \(words.joined(separator: " "))") }
                mode = m
            } else if let s = Double(word) {
                guard seconds == nil, s.isFinite, s > 0 else { throw UsageError(description: "bad seconds: \(word)") }
                seconds = s
            } else {
                throw UsageError(description: "unknown argument '\(word)'")
            }
        }
        return (mode ?? .any, seconds ?? defaultSeconds)
    }

    /// Printed on the way out: the bench needs the installed agent quit first.
    static let restartHint = "Afterwards, start lain again: launchctl kickstart gui/$(id -u)/\(LoginAgent.label)"

    static func anotherInstanceMessage(pids: [Int32]) -> String {
        """
        lain is running (pid \(pids.map(String.init).joined(separator: ", "))): it advertises the same host id, so the iPad \
        could dial it instead of the bench.
        Quit lain from the menu bar first (a clean quit stays quit), then run the bench again.
        \(restartHint)
        """
    }

    /// `LainHost --bench wifi …`, run as the app's binary from Terminal (Terminal-run tools may use the
    /// local network; the Keychain works through the app's entitlement). Refuses while another LainHost
    /// runs. Ctrl-C ends the run early with what was measured (the report and the CSV); a second Ctrl-C
    /// quits at once.
    public static func main(arguments words: [String]) async -> Int32 {
        let parsed: (mode: Mode, seconds: Double)
        do {
            parsed = try parse(words)
        } catch {
            print("\(error)\n\(usage)")
            return 2
        }
        let others = LoginAgent.otherInstances().map(\.processIdentifier)
        guard others.isEmpty else {
            print(anotherInstanceMessage(pids: others))
            return 3
        }
        let bench = Task { try await run(options: .live(mode: parsed.mode, seconds: parsed.seconds)) }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler {
            signal(SIGINT, SIG_DFL)
            bench.cancel()
        }
        interrupt.resume()
        defer {
            interrupt.cancel()
            signal(SIGINT, SIG_DFL)
        }
        do {
            let report = try await bench.value
            print(report)
            print(restartHint)
            return report.measuredLink == nil ? 1 : 0
        } catch {
            print("wifi bench failed: \(error)")
            print(restartHint)
            return 1
        }
    }

    // MARK: Paths

    /// What the bench makes of a new link's paths (realtime, video, audio): why it won't measure it (nil:
    /// it will), and what to tell the owner.
    public struct PathVerdict: Sendable, Equatable {
        public var refusal: String?
        public var notes: [String]

        public var measure: Bool { refusal == nil }
    }

    public static func check(_ paths: [NetworkPath], mode: Mode) -> PathVerdict {
        guard paths.count == ConnectionKind.allCases.count else {
            return PathVerdict(refusal: "\(paths.count) connections", notes: ["expected three connections, got \(paths.count)"])
        }
        let names = paths.map { $0.interfaceName.isEmpty ? "?" : $0.interfaceName }
        var notes: [String] = []
        if Set(names).count == 1 {
            notes.append("all three connections on \(names[0])")
        } else {
            notes.append("WARNING: the connections run on different interfaces (realtime \(names[0]), video \(names[1]), "
                         + "audio \(names[2])): the numbers won't describe one path")
        }
        if let wired = paths.firstIndex(where: { $0.kind == .wired }) {
            notes.append("WARNING: \(names[wired]) is a wired path (the iPad's USB-Ethernet link while the cable is in, or "
                         + "Ethernet): unplug the cable for a Wi-Fi run")
        }
        switch mode {
        case .awdl where paths[0].kind != .peerToPeer:
            notes.append("the iPad reached this Mac over \(names[0]) (\(label(paths[0].kind))), not AWDL: closing the link. "
                         + "For the awdl run, disconnect the iPad from the Wi-Fi network (Control Center; Wi-Fi stays on) "
                         + "and it redials over AWDL")
            return PathVerdict(refusal: "not peer-to-peer (\(names[0]), awdl mode)", notes: notes)
        case .lan where paths[0].kind == .peerToPeer:
            notes.append("WARNING: lan mode, but the link runs over \(names[0]) (peer-to-peer)")
        default:
            break
        }
        return PathVerdict(refusal: nil, notes: notes)
    }

    static func label(_ kind: NetworkPath.Kind?) -> String {
        switch kind {
        case .peerToPeer?: "peer-to-peer"
        case .wifi?: "Wi-Fi"
        case .wired?: "wired"
        case .loopback?: "loopback"
        case .other?, nil: "other"
        }
    }

    // MARK: Report

    /// One accepted link; per connection (realtime, video, audio) its interface, TLS and handshake.
    public struct LinkInfo: Sendable, Equatable {
        public var number: Int
        /// The stored account whose secret it used: the iPad's USB serial.
        public var peer: String
        public var interfaces: [String]
        public var kinds: [NetworkPath.Kind]
        public var tls: [NegotiatedTLS?]
        /// The TLS handshake of each accepted connection.
        public var handshakeMs: [Double]
        /// Seconds since the bench started.
        public var acceptedAt: Double
        /// From its `Hello`.
        public var deviceModel: String?
        /// It passed the path check and sent `Hello`.
        public var measured = false
        public var endedAt: Double?
        public var endReason: String?

        var line: String {
            let name = interfaces.first.map { $0.isEmpty ? "?" : $0 } ?? "?"
            let split = Set(interfaces).count > 1 ? " (video \(interfaces[1]), audio \(interfaces[2]))" : ""
            let suites = Set(tls.map { $0?.description ?? "no TLS" }).sorted().joined(separator: ", ")
            var line = "link \(number): \(deviceModel ?? "iPad") (\(short(peer))) over \(name) (\(label(kinds.first)))\(split), "
                + "\(suites), TLS handshakes \(handshakeMs.map { ms($0) }.joined(separator: " / ")) ms"
            if !measured { line += ", not measured" }
            if let endReason { line += "; ended: \(endReason)" }
            return line
        }
    }

    public struct Reconnect: Sendable, Equatable {
        /// From noticing the drop (or the iPad redialing) to the new link's `Hello`.
        public var afterDropSeconds: Double
        /// From the last message heard on the old link to the new link's `Hello`.
        public var outageSeconds: Double
    }

    /// Pings at one cadence (phase A, or under load in B).
    public struct PingResult: Sendable, Equatable {
        public var intervalMs: Double
        /// Connected time; `complete`: it reached `targetSeconds`.
        public var seconds: Double
        public var targetSeconds: Double
        public var complete: Bool
        public var sent: Int
        public var received: Int
        /// Round trips without the iPad's own handling time (`Pong` t2 − t1), ms.
        public var rtt: BenchStats.Distribution
        public var histogram: BenchStats.Histogram
        /// RTTs above each of `pingThresholdsMs`.
        public var over: [Int]

        public var lost: Int { sent - received }

        func lines(_ title: String) -> [String] {
            [
                "\(title), \(duration(seconds, targetSeconds, complete)): \(sent) pings, \(lost) lost; RTT ms p50 \(ms(rtt.p50))  "
                    + "p90 \(ms(rtt.p90))  p99 \(ms(rtt.p99))  p99.9 \(ms(rtt.p999))  max \(ms(rtt.max))",
                "  histogram ms: " + zip(BenchStats.Histogram.labels, histogram.counts).map { "\($0) \($1)" }
                    .joined(separator: " | "),
                "  above " + zip(pingThresholdsMs, over).map { "\(ms($0)) ms: \($1) (\(percent($1, of: received)))" }
                    .joined(separator: ", "),
            ]
        }
    }

    /// Phase B: pings and the emulated pipeline.
    public struct LoadResult: Sendable, Equatable {
        public var seconds: Double
        public var targetSeconds: Double
        public var complete: Bool
        public var pings: PingResult
        /// Every frame sent, keyframes included.
        public var framesSent: Int
        public var keyframesSent: Int
        public var framesAcked: Int
        /// 120 Hz ticks at which the ack window was full.
        public var drops: Int
        /// Frames sent per connected second.
        public var fps: Double
        /// Send → ack of the 50 KB frames and of the keyframes, ms.
        public var frameAck: BenchStats.Distribution
        public var keyframeAck: BenchStats.Distribution
        public var stalls: BenchStats.Stalls

        func lines() -> [String] {
            pings.lines("B under load") + [
                "  frames: \(framesSent) sent (keyframes \(keyframesSent)), \(drops) dropped at the ack window "
                    + "(N = \(pipelineInFlight)), " + String(format: "%.1f fps", fps),
                "  \(frameBytes / 1000) KB frame send→ack ms p50 \(ms(frameAck.p50))  p99 \(ms(frameAck.p99))  max \(ms(frameAck.max))",
                "  \(Double(keyframeBytes) / 1e6) MB keyframe send→ack ms p50 \(ms(keyframeAck.p50))  p99 \(ms(keyframeAck.p99))  "
                    + "max \(ms(keyframeAck.max))",
                "  stalls (a frame in flight, no ack) " + zip(BenchStats.Stalls.thresholdsMs, stalls.counts)
                    .map { ">\(Int($0)) ms: \($1)" }.joined(separator: ", ") + "; longest \(ms(stalls.longestMs)) ms",
            ]
        }
    }

    /// Phase C: MB/s acknowledged per full second with 3 × 1 MB in flight.
    public struct CapacityResult: Sendable, Equatable {
        public var seconds: Double
        public var targetSeconds: Double
        public var complete: Bool
        public var bytesAcked: Int
        public var perSecondMBps: [Double]
        public var averageMBps: Double

        public var min: Double? { perSecondMBps.min() }
        public var median: Double? { BenchStats.percentile(perSecondMBps.sorted(), 0.5) }
        public var max: Double? { perSecondMBps.max() }

        func lines() -> [String] {
            ["C capacity (3 × 1 MB in flight), \(duration(seconds, targetSeconds, complete)): MB/s per second min \(mbps(min))  "
                + "median \(mbps(median))  max \(mbps(max)) (\(perSecondMBps.count) s); average \(mbps(averageMBps))"]
        }
    }

    public struct Report: Sendable, CustomStringConvertible {
        public var mode: Mode
        public var hostName: String
        public var hostId: String
        public var deadlineSeconds: Double
        public var elapsedSeconds: Double
        public var port: UInt16?
        public var advertisedName: String?
        /// The listener's last problem (waiting or failed), if any.
        public var listenerTrouble: String?
        public var links: [LinkInfo]
        public var reconnects: [Reconnect]
        public var pings: PingResult?
        public var idlePings: PingResult?
        public var load: LoadResult?
        public var capacity: CapacityResult?
        /// Why it ended before every phase had run in full (the deadline, a stop, the listener).
        public var endedBy: String?
        public var csvPath: String?

        public var complete: Bool { endedBy == nil }
        /// The link the numbers describe first.
        public var measuredLink: LinkInfo? { links.first { $0.measured } }

        public var description: String {
            var lines = [
                "Wi-Fi bench (S9), mode \(mode.rawValue): " + (endedBy.map { "PARTIAL, \($0)" } ?? "all phases done")
                    + String(format: " after %.1f s", elapsedSeconds) + " (deadline \(secondsText(deadlineSeconds)) s)",
                "  host “\(hostName)” id \(hostId), port \(port.map(String.init) ?? "none")"
                    + (advertisedName.map { ", advertised as “\($0)”" } ?? ", not advertised")
                    + (listenerTrouble.map { "; listener: \($0)" } ?? ""),
            ]
            lines += links.isEmpty ? ["  no iPad connected"] : links.map { "  " + $0.line }
            lines.append("  reconnects: " + (reconnects.isEmpty ? "none" : reconnects.map {
                String(format: "%.2f s after the drop (outage %.2f s)", $0.afterDropSeconds, $0.outageSeconds)
            }.joined(separator: "; ")))
            lines += (pings?.lines("A @120 Hz") ?? ["A @120 Hz: not run"]).map { "  " + $0 }
            lines += (idlePings?.lines("A @10 Hz") ?? ["A @10 Hz: not run"]).map { "  " + $0 }
            lines += (load?.lines() ?? ["B under load: not run"]).map { "  " + $0 }
            lines += (capacity?.lines() ?? ["C capacity: not run"]).map { "  " + $0 }
            lines.append("  raw samples: \(csvPath ?? "not written")")
            lines.append("  §13: \(summary)")
            return lines.joined(separator: "\n")
        }

        /// One line for ARCHITECTURE §13.
        public var summary: String {
            var parts = ["S9 --bench wifi \(mode.rawValue) "
                + (measuredLink.map { "over \($0.interfaces.first ?? "?") (\(label($0.kinds.first)))" } ?? "(no link measured)")]
            if let p = pings {
                parts.append("ping @120 Hz p50/p90/p99/p99.9/max \(ms(p.rtt.p50))/\(ms(p.rtt.p90))/\(ms(p.rtt.p99))/"
                             + "\(ms(p.rtt.p999))/\(ms(p.rtt.max)) ms, >16.7 ms \(percent(p.over[0], of: p.received)), lost \(p.lost)")
            }
            if let p = idlePings { parts.append("@10 Hz p50/p99 \(ms(p.rtt.p50))/\(ms(p.rtt.p99)) ms") }
            if let l = load {
                parts.append("under load ping p50/p99/max \(ms(l.pings.rtt.p50))/\(ms(l.pings.rtt.p99))/\(ms(l.pings.rtt.max)) ms, "
                             + "50 KB frame p50/p99/max \(ms(l.frameAck.p50))/\(ms(l.frameAck.p99))/\(ms(l.frameAck.max)) ms, "
                             + "1.3 MB keyframe \(ms(l.keyframeAck.p50))/\(ms(l.keyframeAck.p99))/\(ms(l.keyframeAck.max)) ms, "
                             + String(format: "%.1f fps, ", l.fps) + "\(l.drops) drops, "
                             + "stalls >50/100/250 ms \(l.stalls.counts.map(String.init).joined(separator: "/")) "
                             + "(longest \(ms(l.stalls.longestMs)) ms)")
            }
            if let c = capacity {
                parts.append("capacity median \(mbps(c.median)) MB/s (min \(mbps(c.min)), max \(mbps(c.max)))")
            }
            parts.append("reconnects \(reconnects.count)")
            if let endedBy { parts.append("partial: \(endedBy)") }
            return parts.joined(separator: "; ")
        }
    }

    // MARK: Run

    /// Runs the bench: setup failures (no paired iPad, an unreadable Keychain, no listener) throw;
    /// after that it always returns a report, partial if the deadline, a stop or the listener ended it.
    /// `log` gets the live output.
    public static func run(options: Options, log: @escaping @Sendable (String) -> Void = { print($0) }) async throws -> Report {
        // No App Nap and no timer coalescing while the 120 Hz cadence runs.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "lain Wi-Fi bench")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let engine = try Engine(options: options, log: log)
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in engine.start { continuation.resume(returning: $0) } }
        } onCancel: {
            engine.stop()
        }
        var report = outcome.report
        do {
            report.csvPath = try writeCSV(outcome.rows.sorted { $0.ns < $1.ns }.map { $0.text }, mode: options.mode,
                                          to: options.csvDirectory).path
        } catch {
            log("could not write the raw samples: \(error)")
        }
        return report
    }

    static func writeCSV(_ rows: [String], mode: Mode, to directory: URL) throws -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("lain-s9-\(mode.rawValue)-\(stamp.string(from: Date())).csv")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (([csvHeader] + rows).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private struct Outcome: Sendable {
        var report: Report
        var rows: [(ns: UInt64, text: String)]
    }

    private struct Phase {
        enum Kind { case pings, idlePings, load, capacity }
        let kind: Kind
        let targetNs: UInt64

        init(_ kind: Kind, seconds: Double) {
            self.kind = kind
            targetNs = nanoseconds(seconds)
        }

        var pingIntervalNs: UInt64? {
            switch kind {
            case .pings, .load: WiFiBench.tickNs
            case .idlePings: WiFiBench.idleTickNs
            case .capacity: nil
            }
        }

        var label: String {
            switch kind {
            case .pings: "A @120 Hz"
            case .idlePings: "A @10 Hz"
            case .load: "B under load"
            case .capacity: "C capacity"
            }
        }

        var csvName: String {
            switch kind {
            case .pings: "A120"
            case .idlePings: "A10"
            case .load: "B"
            case .capacity: "C"
            }
        }

        var intro: String {
            let s = secondsText(Double(targetNs) / 1e9)
            return switch kind {
            case .pings: "phase A: a ping every 8.33 ms for \(s) s, whether or not pongs come back"
            case .idlePings: "phase A, idle cadence: a ping every 100 ms for \(s) s"
            case .load: "phase B: pings every 8.33 ms plus the pipeline for \(s) s: a 50 KB frame every 8.33 ms while fewer "
                + "than 2 are unacknowledged (else a drop), a 1.3 MB keyframe every 2 s"
            case .capacity: "phase C: capacity, 3 × 1 MB in flight, for \(s) s"
            }
        }
    }

    private struct PingSample {
        var id: UInt32
        var link: Int
        var sentNs: UInt64
        var pongNs: UInt64?
        /// The round trip minus the iPad's handling (`Pong` t2 − t1).
        var rttNs: UInt64?
    }

    private struct FrameSample {
        var id: UInt32
        var link: Int
        /// Index into `PhaseRun.segments`.
        var segment: Int
        var sentNs: UInt64
        var bytes: Int
        var isKeyframe: Bool
        var ackNs: UInt64?
    }

    /// A stretch of one phase on one link.
    private struct SegmentRecord {
        var link: Int
        var startNs: UInt64
        var endNs: UInt64
        var dropped: Bool
        /// Until when its unacknowledged frames count as stalled: the drop, or the end of the drain.
        var openUntilNs: UInt64
    }

    /// One phase's time budget and samples. Touched only on the engine's queue.
    private final class PhaseRun {
        let phase: Phase
        var remainingNs: UInt64
        var connectedNs: UInt64 = 0
        let firstPingId: UInt32
        var pings: [PingSample] = []
        let firstFrameId: UInt32
        var frames: [FrameSample] = []
        var drops = 0
        var segments: [SegmentRecord] = []
        /// Reset on every link: a new link starts with an empty window and a keyframe.
        var window = FrameAckWindow(maxInFlight: WiFiBench.pipelineInFlight)
        var nextKeyframeNs: UInt64 = 0
        var keyframeDue = false
        /// The current segment's first ping: only its pongs can still come.
        var segmentFirstPing = 0

        init(phase: Phase, firstPingId: UInt32, firstFrameId: UInt32) {
            self.phase = phase
            remainingNs = phase.targetNs
            self.firstPingId = firstPingId
            self.firstFrameId = firstFrameId
        }

        func pingIndex(_ id: UInt32) -> Int? {
            let i = Int(id &- firstPingId)
            return i < pings.count && pings[i].id == id ? i : nil
        }

        func frameIndex(_ id: UInt32) -> Int? {
            let i = Int(id &- firstFrameId)
            return i < frames.count && frames[i].id == id ? i : nil
        }

        var outstandingPings: Int { pings[segmentFirstPing...].filter { $0.pongNs == nil }.count }
    }

    /// The bench's machinery. Every entry point hops onto `queue`, the only place its mutable state is
    /// touched (hence `@unchecked Sendable`); its timers fire there too. Arrival times are taken where
    /// messages arrive, before the hop.
    private final class Engine: @unchecked Sendable {
        let options: Options
        let log: @Sendable (String) -> Void
        let queue = DispatchQueue(label: "lain.bench.wifi", qos: .userInteractive)
        let startNs: UInt64
        let deadlineNs: UInt64
        /// Nothing is sent after this, so the last drain ends by the deadline.
        let stopByNs: UInt64
        let phases: [Phase]
        let accounts: [String]
        let psks: [WiFiPSK]
        private let frame = [UInt8](repeating: 0x5A, count: WiFiBench.frameBytes)
        private let keyframe = [UInt8](repeating: 0xA5, count: WiFiBench.keyframeBytes)
        private let chunk = [UInt8](repeating: 0x3C, count: WiFiBench.capacityChunkBytes)

        private struct Current {
            let number: Int
            let link: Link
            var ready = false
            var lastHeardNs: UInt64
        }

        private struct Segment {
            let link: Int
            let startNs: UInt64
            var timers: [DispatchSourceTimer] = []
        }

        private var listener: NetworkStreamListener?
        private var acceptor: LinkAcceptor?
        private var listenerDead = false
        private var completion: (@Sendable (Outcome) -> Void)?
        private var outcome: Outcome?
        private var finished = false
        private var port: UInt16?
        private var advertisedName: String?
        private var listenerTrouble: String?
        private var links: [LinkInfo] = []
        /// The link being measured, or waiting for its `Hello`.
        private var current: Current?
        /// The first iPad measured; another one is turned away.
        private var peer: String?
        private var drop: (atNs: UInt64, lastHeardNs: UInt64)?
        /// The deadline and the waiting reminder, cancelled at the end.
        private var timers: [DispatchSourceTimer] = []
        private var drainTimer: DispatchSourceTimer?
        private var reconnects: [Reconnect] = []
        private var phaseIndex = 0
        private var run: PhaseRun?
        private var segment: Segment?
        private var draining = false
        /// Bumped whenever a segment or a drain ends, so their pending timers do nothing.
        private var generation = 0
        private var nextPingId: UInt32 = 1
        private var nextFrameId: UInt32 = 1
        private var pingResult: PingResult?
        private var idlePingResult: PingResult?
        private var loadResult: LoadResult?
        private var capacityResult: CapacityResult?
        private var rows: [(ns: UInt64, text: String)] = []

        init(options: Options, log: @escaping @Sendable (String) -> Void) throws {
            self.options = options
            self.log = log
            startNs = MonotonicClock.now()
            deadlineNs = startNs + nanoseconds(options.seconds)
            stopByNs = deadlineNs - min(WiFiBench.drainNs, deadlineNs - startNs)
            phases = [Phase(.pings, seconds: options.pingSeconds), Phase(.idlePings, seconds: options.idlePingSeconds),
                      Phase(.load, seconds: options.loadSeconds), Phase(.capacity, seconds: options.capacitySeconds)]
                .filter { $0.targetNs > 0 }
            let stored = try options.secrets.allSecrets().sorted { $0.key < $1.key }
            guard !stored.isEmpty else { throw Failure.noPairedIPad }
            accounts = stored.map(\.key)
            psks = stored.map { WiFiPSK(secret: $0.value) }

            let acceptor = LinkAcceptor(secrets: options.secrets, label: "lain.bench", onReject: { [weak self] error in
                guard let self else { return }
                queue.async { self.refused(error) }
            }, onLink: { [weak self] accepted in
                guard let self else { return accepted.link.close() }
                queue.async { self.accepted(accepted) }
            })
            let advertisement = options.advertise
                ? NetworkStreamListener.Advertisement(type: LainProtocol.bonjourServiceType,
                                                      txt: LainTXT.dictionary(hostId: options.identity.id, bench: true))
                : nil
            do {
                listener = try NetworkStreamListener(psks: psks, options: options.listener, advertisement: advertisement,
                                                     onEvent: { [weak self] event in
                                                         guard let self else { return }
                                                         queue.async { self.listenerEvent(event) }
                                                     }, onAccept: { acceptor.accept($0) })
            } catch {
                acceptor.cancel()
                throw error
            }
            self.acceptor = acceptor
        }

        func start(_ completion: @escaping @Sendable (Outcome) -> Void) {
            queue.async { [self] in
                if let outcome { return completion(outcome) }   // stopped before it started
                self.completion = completion
                introduce()
                let deadline = "reached the \(secondsText(options.seconds)) s deadline"
                timers.append(once(after: since(MonotonicClock.now(), deadlineNs)) { [weak self] in self?.finish(deadline) })
                timers.append(repeating(every: WiFiBench.waitingReminderNs, after: WiFiBench.waitingReminderNs) {
                    [weak self] in self?.remindWhileWaiting()
                })
                beginPhase()
            }
        }

        func stop() {
            queue.async { [self] in finish("stopped") }
        }

        // MARK: Listener and links (on `queue`)

        /// Nothing to measure for a while: says what the iPad needs.
        private func remindWhileWaiting() {
            guard !finished, current?.ready != true else { return }
            let path = switch options.mode {
            case .awdl: "; for awdl, the iPad off the home network with Wi-Fi on"
            case .lan: "; for lan, the iPad on this Mac's network"
            case .any: ""
            }
            say("still waiting for the iPad: lain open in the foreground, the cable out\(path)")
        }

        private func introduce() {
            let plan = phases.map { "\($0.csvName) \(secondsText(Double($0.targetNs) / 1e9)) s" }.joined(separator: ", ")
            say("Wi-Fi bench (S9), mode \(options.mode.rawValue), deadline \(secondsText(options.seconds)) s; phases \(plan)")
            say("host “\(options.identity.name)” id \(options.identity.id); PSKs of \(psks.count) paired iPad(s): "
                + zip(psks, accounts).map { "\($0.identity) (\(short($1)))" }.joined(separator: ", "))
            switch options.mode {
            case .awdl:
                say("awdl: the iPad must be off the home network (Control Center; Wi-Fi stays on); only peer-to-peer links count")
            case .lan:
                say("lan: the listener stays off peer-to-peer interfaces; the iPad and this Mac on the same network")
            case .any:
                say("any: whichever path Network.framework picks")
            }
            say("waiting for the iPad: cable out, lain open in the foreground (Ctrl-C ends early, with the results so far)")
        }

        private func listenerEvent(_ event: NetworkStreamListener.Event) {
            guard !finished else { return }
            switch event {
            case .state(.ready(let port)):
                self.port = port
                listenerTrouble = nil
                say("listening on port \(port)")
                options.onListening(port)
            case .state(.waiting(let error)):
                listenerTrouble = "waiting: \(error)"
                say("the listener is waiting: \(error)" + (error == .localNetworkDenied
                    ? " (allow LainHost in System Settings › Privacy & Security › Local Network)" : ""))
            case .state(.failed(let error)):
                listenerTrouble = "failed: \(error)"
                listenerDead = true
                say("the listener failed: \(error)")
                if current == nil { finish("the listener failed (\(error))") }
            case .state(.setup), .state(.cancelled):
                break
            case .registered(let name):
                advertisedName = name
                say("advertised as “\(name)” (\(LainProtocol.bonjourServiceType), TXT v=\(LainProtocol.majorVersion) "
                    + "id=\(options.identity.id) bench=1)")
            case .unregistered(let name):
                say("no longer advertised as “\(name)”")
            case .rejected(let error):
                let hint = switch error {
                case .unknownIdentity: ": the iPad's pairing isn't in this Mac's Keychain (pair over USB)"
                case .wrongKey: ": the iPad holds another secret for this Mac (pair again over USB)"
                default: ""
                }
                say("a connection failed its TLS handshake: \(error)\(hint)")
            }
        }

        private func refused(_ error: any Error) {
            guard !finished else { return }
            if let e = error as? TransportError, case .versionMismatch(let remote) = e {
                say("refused a connection: lain on the iPad speaks protocol v\(remote), this Mac v\(LainProtocol.majorVersion)")
            } else {
                say("refused a connection: \(error)")
            }
        }

        private func accepted(_ accepted: AcceptedLink) {
            let link = accepted.link
            guard !finished else { return link.close() }
            let now = MonotonicClock.now()
            let number = links.count + 1
            let streams = link.channels.map { $0.stream as? NetworkStream }
            let paths = streams.map { $0?.path ?? NetworkPath(interface: nil) }
            links.append(LinkInfo(number: number, peer: accepted.peer, interfaces: paths.map(\.interfaceName),
                                  kinds: paths.map(\.kind), tls: streams.map { $0?.tls },
                                  handshakeMs: streams.map { Double($0?.handshakeNs ?? 0) / 1e6 }, acceptedAt: seconds(at: now)))
            say("link \(number) from iPad \(short(accepted.peer)), PSK \(streams[0]?.pskIdentity ?? "not reported"):")
            for (kind, stream) in zip(ConnectionKind.allCases, streams) {
                say("  \(kind): " + (stream.map(describe) ?? "not a Network.framework stream"))
            }
            let verdict = WiFiBench.check(paths, mode: options.mode)
            verdict.notes.forEach { say("  " + $0) }
            if let refusal = verdict.refusal { return turnAway(number, link, refusal, at: now) }
            if let peer, peer != accepted.peer {
                say("  another iPad than the one measured (\(short(peer))): closing it")
                return turnAway(number, link, "another iPad", at: now)
            }
            peer = accepted.peer
            if let old = current {
                say("  it replaces link \(old.number): the iPad redialed")
                linkGone(old.number, "replaced by link \(number)", at: now)
            }
            current = Current(number: number, link: link, lastHeardNs: now)
            serve(link, number: number)
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(WiFiBench.helloTimeoutNs))) { [weak self] in
                self?.helloOverdue(number)
            }
        }

        private func describe(_ stream: NetworkStream) -> String {
            let path = stream.path
            let name = path.interfaceName.isEmpty ? "?" : path.interfaceName
            return "\(name) (\(label(path.kind))), \(stream.tls?.description ?? "no TLS"), TLS handshake "
                + "\(ms(Double(stream.handshakeNs) / 1e6)) ms" + (path.remoteEndpoint.map { ", from \($0.debugDescription)" } ?? "")
        }

        private func turnAway(_ number: Int, _ link: Link, _ reason: String, at now: UInt64) {
            links[number - 1].endedAt = seconds(at: now)
            links[number - 1].endReason = reason
            link.close()
        }

        private func serve(_ link: Link, number: Int) {
            link.realtime.setHandler { [weak self] env in
                let at = MonotonicClock.now()
                guard let self else { return }
                switch env.message {
                case .pong(let pong): queue.async { self.pong(pong, at: at, link: number) }
                case .hello(let hello): queue.async { self.hello(hello, link: number) }
                default: break   // KeyframeRequests (the iPad has no VideoConfig), input: not measured
                }
            }
            link.video.setHandler { [weak self] env in
                let at = MonotonicClock.now()
                guard let self, case .frameAck(let ack) = env.message else { return }
                queue.async { self.ack(ack, at: at, link: number) }
            }
            link.audio.setHandler { _ in }
            for channel in link.channels {
                channel.setCloseHandler { [weak self] error in
                    guard let self else { return }
                    queue.async { self.closed(link: number, error) }
                }
            }
        }

        private func hello(_ hello: Hello, link number: Int) {
            guard !finished, let c = current, c.number == number, !c.ready else { return }
            let now = MonotonicClock.now()
            current?.ready = true
            current?.lastHeardNs = now
            links[number - 1].deviceModel = hello.deviceModel
            links[number - 1].measured = true
            say("  \(hello.deviceModel) \(hello.pixelWidth)×\(hello.pixelHeight) sent Hello: link \(number) is measured")
            if let drop {
                let reconnect = Reconnect(afterDropSeconds: Double(since(drop.atNs, now)) / 1e9,
                                          outageSeconds: Double(since(drop.lastHeardNs, now)) / 1e9)
                reconnects.append(reconnect)
                self.drop = nil
                say(String(format: "  reconnected %.2f s after the drop (the iPad was unheard for %.2f s)",
                           reconnect.afterDropSeconds, reconnect.outageSeconds))
            }
            maybeStartSegment()
        }

        private func helloOverdue(_ number: Int) {
            guard !finished, let c = current, c.number == number, !c.ready else { return }
            say("link \(number) sent no Hello within \(WiFiBench.helloTimeoutNs / 1_000_000_000) s: closing it")
            linkGone(number, "no Hello", at: MonotonicClock.now())
        }

        private func closed(link number: Int, _ error: (any Error)?) {
            guard !finished, let c = current, c.number == number else { return }
            let now = MonotonicClock.now()
            let why = error.map { "\($0)" } ?? "closed by the iPad"
            say("link \(number) dropped" + (run.map { " during \($0.phase.label)" } ?? "") + ": \(why); the iPad was last "
                + "heard \(ms(Double(since(c.lastHeardNs, now)) / 1e6)) ms before")
            linkGone(number, why, at: now)
            if finished { return }   // that was the end of the last phase
            if listenerDead { return finish("the listener failed and the link dropped") }
            say("waiting for the iPad to redial")
        }

        /// The measured link is gone (dropped, replaced, or silent): what was in flight on it never
        /// comes back.
        private func linkGone(_ number: Int, _ reason: String, at now: UInt64) {
            guard let c = current, c.number == number else { return }
            current = nil
            links[number - 1].endedAt = seconds(at: now)
            links[number - 1].endReason = reason
            c.link.close()
            if c.ready { drop = (now, c.lastHeardNs) }
            if segment != nil {
                closeSegment(at: now, dropped: true)
                guard let run else { return }
                if run.remainingNs > 0 {
                    say(String(format: "  %.1f s of ", Double(run.remainingNs) / 1e9) + "\(run.phase.label) to go once the iPad is back")
                } else {
                    draining = true   // the phase had just run its course; nothing more comes on this link
                    endDrain(at: now)
                }
            } else if draining {
                endDrain(at: now)
            }
        }

        // MARK: Phases (on `queue`)

        private func beginPhase() {
            guard !finished else { return }
            guard phaseIndex < phases.count else { return finish(nil) }
            run = PhaseRun(phase: phases[phaseIndex], firstPingId: nextPingId, firstFrameId: nextFrameId)
            maybeStartSegment()
        }

        /// Runs the current phase on the current link, once it has sent `Hello`, for what's left of
        /// the phase (up to `stopByNs`).
        private func maybeStartSegment() {
            guard !finished, !draining, segment == nil, let run, run.remainingNs > 0, let c = current, c.ready else { return }
            let now = MonotonicClock.now()
            guard now < stopByNs else { return finish(outOfTime) }
            let endNs = min(now + run.remainingNs, stopByNs)
            if run.segments.isEmpty {
                say(run.phase.intro)
            } else {
                say("  \(run.phase.label) resumes on link \(c.number): " + String(format: "%.1f s to go", Double(run.remainingNs) / 1e9))
            }
            run.window = FrameAckWindow(maxInFlight: run.phase.kind == .capacity ? WiFiBench.capacityInFlight
                                                                                    : WiFiBench.pipelineInFlight)
            run.nextKeyframeNs = now
            run.keyframeDue = false
            run.segmentFirstPing = run.pings.count
            var segment = Segment(link: c.number, startNs: now)
            if let interval = run.phase.pingIntervalNs {
                segment.timers.append(repeating(every: interval, after: 0) { [weak self] in self?.sendPing() })
            }
            if run.phase.kind == .load {
                // Half a tick after the pings: input isn't timed to the frames.
                segment.timers.append(repeating(every: WiFiBench.tickNs, after: WiFiBench.tickNs / 2) { [weak self] in
                    self?.sendFrame()
                })
            }
            segment.timers.append(repeating(every: WiFiBench.progressIntervalNs, after: WiFiBench.progressIntervalNs) {
                [weak self] in self?.progress()
            })
            let generation = generation
            segment.timers.append(once(after: endNs - now) { [weak self] in
                guard let self, self.generation == generation else { return }
                closeSegment(at: MonotonicClock.now(), dropped: false)
                startDrain()
            })
            self.segment = segment
            if run.phase.kind == .capacity { fillCapacity() }
        }

        /// Strict timers on `queue`: `asyncAfter` may be coalesced by about a tenth of its delay, seconds
        /// late for a 30 s phase or the deadline.
        private func repeating(every intervalNs: UInt64, after delayNs: UInt64,
                               _ handler: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now() + .nanoseconds(Int(delayNs)), repeating: .nanoseconds(Int(intervalNs)),
                           leeway: .nanoseconds(0))
            timer.setEventHandler(handler: handler)
            timer.resume()
            return timer
        }

        private func once(after delayNs: UInt64, _ handler: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now() + .nanoseconds(Int(delayNs)), repeating: .never, leeway: .milliseconds(1))
            timer.setEventHandler(handler: handler)
            timer.resume()
            return timer
        }

        private func closeSegment(at now: UInt64, dropped: Bool) {
            guard let segment, let run else { return }
            segment.timers.forEach { $0.cancel() }
            self.segment = nil
            generation += 1
            let ran = since(segment.startNs, now)
            run.connectedNs += ran
            run.remainingNs = run.remainingNs > ran + 1_000_000 ? run.remainingNs - ran : 0   // within 1 ms: done
            run.segments.append(SegmentRecord(link: segment.link, startNs: segment.startNs, endNs: now, dropped: dropped,
                                              openUntilNs: now))
        }

        /// Sending has stopped: waits (up to `drainNs`) for the pongs and acks still due on this link.
        private func startDrain() {
            draining = true
            let generation = generation
            drainTimer = once(after: WiFiBench.drainNs) { [weak self] in
                guard let self, self.generation == generation else { return }
                endDrain(at: MonotonicClock.now())
            }
            checkDrained()
        }

        private func checkDrained() {
            guard draining, let run, run.outstandingPings == 0, run.window.inFlightCount == 0 else { return }
            endDrain(at: MonotonicClock.now())
        }

        private func endDrain(at now: UInt64) {
            guard draining, let run else { return }
            draining = false
            drainTimer?.cancel()
            drainTimer = nil
            generation += 1
            if let last = run.segments.indices.last, !run.segments[last].dropped { run.segments[last].openUntilNs = now }
            let cut = run.remainingNs > 0   // stopped at `stopByNs`
            completePhase()
            if cut { return finish(outOfTime) }
            phaseIndex += 1
            beginPhase()
        }

        private var outOfTime: String { "out of time before the \(secondsText(options.seconds)) s deadline" }

        private func completePhase() {
            guard let run else { return }
            self.run = nil
            let complete = run.remainingNs == 0
            let lines: [String]
            switch run.phase.kind {
            case .pings:
                let result = pings(run, complete: complete)
                pingResult = result
                lines = result.lines(run.phase.label)
            case .idlePings:
                let result = pings(run, complete: complete)
                idlePingResult = result
                lines = result.lines(run.phase.label)
            case .load:
                let result = load(run, complete: complete)
                loadResult = result
                lines = result.lines()
            case .capacity:
                let result = capacity(run, complete: complete)
                capacityResult = result
                lines = result.lines()
            }
            lines.forEach { say($0) }
            rows += csvRows(run)
        }

        private func finish(_ why: String?) {
            guard !finished else { return }
            finished = true
            let now = MonotonicClock.now()
            if segment != nil { closeSegment(at: now, dropped: false) }
            draining = false
            drainTimer?.cancel()
            drainTimer = nil
            generation += 1
            timers.forEach { $0.cancel() }
            timers.removeAll()
            if let run {
                if let last = run.segments.indices.last, !run.segments[last].dropped { run.segments[last].openUntilNs = now }
                if run.segments.isEmpty { self.run = nil } else { completePhase() }
            }
            if let c = current {
                current = nil
                links[c.number - 1].endedAt = seconds(at: now)
                links[c.number - 1].endReason = "the bench ended"
                c.link.close()
            }
            listener?.cancel()
            acceptor?.cancel()
            listener = nil
            acceptor = nil
            say(why.map { "bench ended: \($0)" } ?? "bench done")
            let report = Report(mode: options.mode, hostName: options.identity.name, hostId: options.identity.id,
                                deadlineSeconds: options.seconds, elapsedSeconds: seconds(at: now), port: port,
                                advertisedName: advertisedName, listenerTrouble: listenerTrouble, links: links,
                                reconnects: reconnects, pings: pingResult, idlePings: idlePingResult, load: loadResult,
                                capacity: capacityResult, endedBy: why, csvPath: nil)
            let outcome = Outcome(report: report, rows: rows + linkRows())
            if let completion {
                self.completion = nil
                completion(outcome)
            } else {
                self.outcome = outcome
            }
        }

        // MARK: Traffic (on `queue`)

        private func sendPing() {
            guard let run, let segment, let c = current, c.number == segment.link else { return }
            let id = nextPingId
            nextPingId &+= 1
            let now = MonotonicClock.now()
            run.pings.append(PingSample(id: id, link: c.number, sentNs: now))
            c.link.realtime.send(.ping(Ping(id: id, sentAtNs: now)))
        }

        private func pong(_ pong: Pong, at: UInt64, link number: Int) {
            guard !finished, current?.number == number else { return }
            current?.lastHeardNs = at
            guard let run, let i = run.pingIndex(pong.id), run.pings[i].link == number, run.pings[i].pongNs == nil else { return }
            let roundTrip = since(run.pings[i].sentNs, at)
            let held = since(pong.receivedAtNs, pong.sentAtNs)
            run.pings[i].pongNs = at
            run.pings[i].rttNs = roundTrip > held ? roundTrip - held : roundTrip
            if draining { checkDrained() }
        }

        /// A 120 Hz tick of the emulated pipeline (§7.3): a frame if the window has room, else a drop.
        private func sendFrame() {
            guard let run, let segment, let c = current, c.number == segment.link else { return }
            let now = MonotonicClock.now()
            while now >= run.nextKeyframeNs {
                run.keyframeDue = true
                run.nextKeyframeNs += WiFiBench.keyframeIntervalNs
            }
            guard run.window.canSend else {
                run.drops += 1
                return
            }
            let isKeyframe = run.keyframeDue
            run.keyframeDue = false
            send(isKeyframe ? keyframe : frame, isKeyframe: isKeyframe, on: c, in: run)
        }

        private func fillCapacity() {
            guard let run, let segment, let c = current, c.number == segment.link else { return }
            while run.window.canSend { send(chunk, isKeyframe: false, on: c, in: run) }
        }

        /// Sent is when the frame is handed to the stream, after it is framed; its ack can't be handled
        /// before this returns (acks hop onto this queue).
        private func send(_ payload: [UInt8], isKeyframe: Bool, on c: Current, in run: PhaseRun) {
            let id = nextFrameId
            nextFrameId &+= 1
            let captured = MonotonicClock.now()
            c.link.video.send(.videoFrame(VideoFrame(frameId: id, configId: 0, captureTimeNs: captured, encodeDoneNs: captured,
                                                     isKeyframe: isKeyframe, data: payload)))
            let now = MonotonicClock.now()
            run.window.sent(frameId: id, bytes: payload.count, at: now)
            run.frames.append(FrameSample(id: id, link: c.number, segment: run.segments.count, sentNs: now,
                                          bytes: payload.count, isKeyframe: isKeyframe))
        }

        private func ack(_ ack: FrameAck, at: UInt64, link number: Int) {
            guard !finished, current?.number == number else { return }
            current?.lastHeardNs = at
            guard let run, let i = run.frameIndex(ack.frameId), run.frames[i].link == number, run.frames[i].ackNs == nil else {
                return
            }
            run.frames[i].ackNs = at
            _ = run.window.acked(frameId: ack.frameId, at: at)
            if run.phase.kind == .capacity, segment != nil { fillCapacity() }
            if draining { checkDrained() }
        }

        private func progress() {
            guard let run, let segment else { return }
            let now = MonotonicClock.now()
            var line = "  \(run.phase.label) " + String(format: "%.0f s:", Double(run.connectedNs + since(segment.startNs, now)) / 1e9)
            switch run.phase.kind {
            case .pings, .idlePings, .load:
                let rtt = BenchStats.Distribution(run.pings.compactMap(\.rttNs).map { Double($0) / 1e6 })
                line += " \(run.pings.count) pings, RTT p50 \(ms(rtt.p50))  p99 \(ms(rtt.p99))  max \(ms(rtt.max)) ms"
                if run.phase.kind == .load { line += "; \(run.frames.count) frames sent, \(run.drops) dropped" }
            case .capacity:
                let recent = run.frames.filter { ($0.ackNs ?? 0) + 1_000_000_000 > now }.reduce(0) { $0 + $1.bytes }
                line += " \(mbps(Double(recent) / 1e6)) MB/s over the last second"
            }
            say(line)
        }

        // MARK: Results (on `queue`)

        private func pings(_ run: PhaseRun, complete: Bool) -> PingResult {
            let rtts = run.pings.compactMap(\.rttNs).map { Double($0) / 1e6 }
            return PingResult(intervalMs: Double(run.phase.pingIntervalNs ?? 0) / 1e6, seconds: Double(run.connectedNs) / 1e9,
                              targetSeconds: Double(run.phase.targetNs) / 1e9, complete: complete, sent: run.pings.count,
                              received: rtts.count, rtt: BenchStats.Distribution(rtts), histogram: BenchStats.Histogram(rtts),
                              over: pingThresholdsMs.map { threshold in rtts.filter { $0 > threshold }.count })
        }

        private func load(_ run: PhaseRun, complete: Bool) -> LoadResult {
            func sendToAck(keyframes: Bool) -> [Double] {
                run.frames.filter { $0.isKeyframe == keyframes }.compactMap { f in
                    f.ackNs.map { Double(since(f.sentNs, $0)) / 1e6 }
                }
            }
            var gaps: [Double] = []
            for (index, segment) in run.segments.enumerated() {
                let frames = run.frames.filter { $0.segment == index }.map { (sentNs: $0.sentNs, ackNs: $0.ackNs) }
                gaps += BenchStats.stallGaps(frames, endNs: segment.openUntilNs).map { Double($0) / 1e6 }
            }
            let seconds = Double(run.connectedNs) / 1e9
            return LoadResult(seconds: seconds, targetSeconds: Double(run.phase.targetNs) / 1e9, complete: complete,
                              pings: pings(run, complete: complete), framesSent: run.frames.count,
                              keyframesSent: run.frames.filter(\.isKeyframe).count,
                              framesAcked: run.frames.filter { $0.ackNs != nil }.count, drops: run.drops,
                              fps: seconds > 0 ? Double(run.frames.count) / seconds : 0,
                              frameAck: BenchStats.Distribution(sendToAck(keyframes: false)),
                              keyframeAck: BenchStats.Distribution(sendToAck(keyframes: true)),
                              stalls: BenchStats.Stalls(gapsMs: gaps))
        }

        private func capacity(_ run: PhaseRun, complete: Bool) -> CapacityResult {
            var perSecond: [Double] = []
            var bytes = 0
            for (index, segment) in run.segments.enumerated() {
                let acks = run.frames.filter { $0.segment == index }.compactMap { f in f.ackNs.map { (atNs: $0, bytes: f.bytes) } }
                perSecond += BenchStats.perSecondMBps(acks, startNs: segment.startNs, endNs: segment.endNs)
                bytes += acks.filter { $0.atNs >= segment.startNs && $0.atNs < segment.endNs }.reduce(0) { $0 + $1.bytes }
            }
            let seconds = Double(run.connectedNs) / 1e9
            return CapacityResult(seconds: seconds, targetSeconds: Double(run.phase.targetNs) / 1e9, complete: complete,
                                  bytesAcked: bytes, perSecondMBps: perSecond,
                                  averageMBps: seconds > 0 ? Double(bytes) / seconds / 1e6 : 0)
        }

        private func csvRows(_ run: PhaseRun) -> [(ns: UInt64, text: String)] {
            let phase = run.phase.csvName
            var rows: [(ns: UInt64, text: String)] = []
            for p in run.pings {
                rows.append((p.sentNs, "\(phase),ping,\(p.id),\(p.link),\(csvMs(p.sentNs)),\(p.pongNs.map(csvMs) ?? ""),"
                             + "\(p.rttNs.map { csvValue(Double($0) / 1e6) } ?? ""),0"))
            }
            for f in run.frames {
                let kind = run.phase.kind == .capacity ? "chunk" : f.isKeyframe ? "keyframe" : "frame"
                let value = f.ackNs.map { csvValue(Double(since(f.sentNs, $0)) / 1e6) } ?? ""
                rows.append((f.sentNs, "\(phase),\(kind),\(f.id),\(f.link),\(csvMs(f.sentNs)),\(f.ackNs.map(csvMs) ?? ""),"
                             + "\(value),\(f.bytes)"))
            }
            return rows
        }

        private func linkRows() -> [(ns: UInt64, text: String)] {
            links.map { link in
                let at = startNs + nanoseconds(link.acceptedAt)
                return (at, "-,\(link.measured ? "link" : "link-refused"),\(link.number),\(link.number),"
                        + "\(csvValue(link.acceptedAt * 1000)),\(link.endedAt.map { csvValue($0 * 1000) } ?? ""),,0")
            }
        }

        // MARK: Helpers

        private func say(_ line: String) {
            log(String(format: "[+%6.1f s] ", seconds(at: MonotonicClock.now())) + line)
        }

        private func seconds(at ns: UInt64) -> Double { Double(since(startNs, ns)) / 1e9 }

        private func csvMs(_ ns: UInt64) -> String { csvValue(Double(since(startNs, ns)) / 1e6) }
    }
}

// MARK: - Formatting

/// Seconds to UInt64 ns, clamped to a day.
private func nanoseconds(_ seconds: Double) -> UInt64 {
    UInt64(min(max(seconds, 0), 86_400) * 1e9)
}

/// `to − from` in ns, never below 0: times taken on different queues can arrive out of order.
private func since(_ from: UInt64, _ to: UInt64) -> UInt64 { to > from ? to - from : 0 }

/// Milliseconds with two decimals below 10, one below 100, none above; a dash when there are none.
private func ms(_ value: Double?) -> String {
    guard let value else { return "–" }
    return String(format: value < 10 ? "%.2f" : value < 100 ? "%.1f" : "%.0f", value)
}

private func mbps(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "–"
}

private func percent(_ count: Int, of total: Int) -> String {
    total > 0 ? String(format: "%.2f%%", Double(count) * 100 / Double(total)) : "–"
}

private func csvValue(_ value: Double) -> String { String(format: "%.3f", value) }

/// "30", "1.5".
private func secondsText(_ value: Double) -> String { String(format: "%g", value) }

private func duration(_ seconds: Double, _ target: Double, _ complete: Bool) -> String {
    complete ? String(format: "%.1f s", seconds) : String(format: "%.1f of %g s (partial)", seconds, target)
}

/// An account (the iPad's USB serial) as the logs show it: its last four characters.
private func short(_ account: String) -> String { account.count > 4 ? "…" + account.suffix(4) : account }
#endif
