import Foundation
import LainProtocol

/// The session's once-a-second diagnostics (logged as category `diag`): how the iPad's input arrives, from
/// the frame headers' send times (the iPad's clock when it queued each message). The two clocks are
/// unrelated, so each message's one-way delay is taken against the smallest seen in the session: what's
/// left is the queueing it picked up on the way (the iPad's socket, the radio, the Mac's socket).
struct InputArrivals: Sendable {
    /// Scroll events closer together than this arrived in a burst (sent ~8 ms apart at 120 Hz).
    static let burstNs: UInt64 = 2_000_000

    struct Summary: Sendable, Equatable {
        var scrolls = 0
        var moves = 0
        var others = 0
        /// Scroll events that came within `burstNs` of the previous one.
        var scrollBursts = 0
        /// The longest wait between two scroll events of one gesture (ms).
        var maxScrollGapMs = 0.0
        /// Delay beyond the session's smallest (ms), over every input message of the second.
        var queueingP50Ms = 0.0
        var queueingMaxMs = 0.0

        var line: String {
            String(format: "input: scroll %d (bursts %d, longest gap %.0f ms), moves %d, other %d · queueing p50 %.1f max %.1f ms",
                   scrolls, scrollBursts, maxScrollGapMs, moves, others, queueingP50Ms, queueingMaxMs)
        }
    }

    /// The smallest receive − send seen (ns, wrapping: the clocks are unrelated).
    private var baseline: Int64?
    private var window = Summary()
    private var delaysMs: [Double] = []
    private var lastScrollNs: UInt64?

    init() { delaysMs.reserveCapacity(512) }

    /// One input message: its header's send time (the iPad's clock) and when it arrived (the Mac's).
    mutating func record(_ message: Message, sentNs: UInt64, receivedNs: UInt64) {
        let offset = Int64(bitPattern: receivedNs &- sentNs)
        if baseline.map({ offset < $0 }) ?? true { baseline = offset }
        if let baseline, delaysMs.count < 512 { delaysMs.append(Double(offset &- baseline) / 1e6) }
        switch message {
        case .scroll(let s):
            window.scrolls += 1
            if let last = lastScrollNs, s.phase != .began, s.momentumPhase != .began {
                let gap = receivedNs &- last
                if gap < Self.burstNs { window.scrollBursts += 1 }
                window.maxScrollGapMs = max(window.maxScrollGapMs, Double(gap) / 1e6)
            }
            let ended = s.phase == .ended || s.phase == .cancelled || s.momentumPhase == .ended
            lastScrollNs = ended ? nil : receivedNs
        case .pointerMove:
            window.moves += 1
        default:
            window.others += 1
        }
    }

    /// The second's summary (nil: no input), and a fresh window.
    mutating func take() -> Summary? {
        defer { window = Summary(); delaysMs.removeAll(keepingCapacity: true) }
        guard window.scrolls + window.moves + window.others > 0 else { return nil }
        var s = window
        let sorted = delaysMs.sorted()
        if !sorted.isEmpty {
            s.queueingP50Ms = sorted[sorted.count / 2]
            s.queueingMaxMs = sorted[sorted.count - 1]
        }
        return s
    }
}

/// The video path over one second (`HostVideoPipeline.takeDiagnostics`): what was sent, how big, and how
/// long each frame took to be acknowledged (send → `FrameAck`: its transfer plus the iPad's receipt).
public struct VideoWindow: Sendable, Equatable {
    public var sent = 0
    public var bytes = 0
    public var maxFrameBytes = 0
    public var keyframes = 0
    public var refinements = 0
    public var ackRttsMs: [Double] = []
    public var maxInFlight = 0
    /// Adaptive bitrate at the end of the second: the target, what the link delivered, the queueing.
    public var targetBps: Int?
    public var deliveryBps: Int?
    public var queueingMs: Double?
    public var encodeP50Ms: Double?
    public init() {}

    /// With the cumulative stats' change over the same second (captured, held back before encode).
    /// `forLink`/`forEncoder`: the held-back frames by what they waited for (nil: not split).
    public func line(captured: Int, droppedBeforeEncode: Int, forLink: Int? = nil, forEncoder: Int? = nil) -> String {
        let sorted = ackRttsMs.sorted()
        let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2], max = sorted.last ?? 0
        let mean = sent > 0 ? bytes / sent : 0
        var line = String(format: "video: captured %d, sent %d (kf %d, refine %d), held back %d · %.1f Mb/s, frame mean %d KB max %d KB"
                              + " · ack p50 %.0f max %.0f ms · in flight max %d",
                          captured, sent, keyframes, refinements, droppedBeforeEncode, Double(bytes) * 8 / 1e6, mean / 1024,
                          maxFrameBytes / 1024, p50, max, maxInFlight)
        if let forLink, let forEncoder {
            line = line.replacingOccurrences(of: "held back \(droppedBeforeEncode) ",
                                             with: "held back \(droppedBeforeEncode) (link \(forLink), encoder \(forEncoder)) ")
        }
        if let targetBps {
            line += String(format: " · target %.1f Mb/s", Double(targetBps) / 1e6)
            line += deliveryBps.map { String(format: ", delivered %.1f", Double($0) / 1e6) } ?? ""
            line += queueingMs.map { String(format: ", queueing %.0f ms", $0) } ?? ""
        }
        if let encodeP50Ms { line += String(format: " · encode p50 %.1f ms", encodeP50Ms) }
        return line
    }
}
