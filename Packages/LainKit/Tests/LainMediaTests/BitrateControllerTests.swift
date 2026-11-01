import Testing
@testable import LainMedia

/// Traces of acks through simulated links: a capacity, a base round trip, frames of a given size.
@Suite struct BitrateControllerTests {
    static let ms: UInt64 = 1_000_000

    /// A frame offered every 1/fps through a link of `capacityBps` with a `baseMs` round trip, as the host's
    /// gate sends them: at most `maxInFlight` unacknowledged, the others held back. The encoder follows the
    /// target: each frame is target / fps bytes. Acks are fed in the order they arrive.
    @discardableResult
    func run(_ c: inout BitrateController, seconds: Double, capacityBps: Double, baseMs: Double = 8, fps: Double = 60,
             start: UInt64 = 0, stallEveryMs: Double? = nil, stallMs: Double = 270, maxInFlight: Int = 2,
             counts: ((sent: Int, held: Int)) -> Void = { _ in }) -> UInt64 {
        var sent = 0, held = 0
        defer { counts((sent, held)) }
        var t = start, linkFreeAt = start
        var inFlight: [(ackAt: UInt64, bytes: Int, sentAt: UInt64)] = []
        let interval = UInt64(1000 / fps * Double(Self.ms))
        let end = start + UInt64(seconds * 1000) * Self.ms
        while t < end {
            inFlight.sort { $0.ackAt < $1.ackAt }
            while let first = inFlight.first, first.ackAt <= t {
                c.acked(bytes: first.bytes, rttNs: first.ackAt - first.sentAt, at: first.ackAt)
                inFlight.removeFirst()
            }
            guard inFlight.count < maxInFlight else { held += 1; c.heldBack(at: t); t += interval; continue }   // held back
            sent += 1
            let bytes = c.target / 8 / Int(fps)
            var sendStart = max(t, linkFreeAt)
            if let every = stallEveryMs {
                let phase = Double(sendStart % UInt64(every * Double(Self.ms))) / Double(Self.ms)
                if phase < stallMs { sendStart += UInt64((stallMs - phase) * Double(Self.ms)) }
            }
            let transfer = UInt64(Double(bytes * 8) / capacityBps * 1e9)
            linkFreeAt = sendStart + transfer
            let ackAt = linkFreeAt + UInt64(baseMs * Double(Self.ms))
            inFlight.append((ackAt, bytes, t))
            t += interval
        }
        return t
    }

    @Test func aSlowLinkBringsTheTargetUnderItsCapacity() {
        var c = BitrateController(start: 60_000_000)
        run(&c, seconds: 4, capacityBps: 12_000_000)
        #expect(c.target <= 12_000_000, "\(c.target)")
        #expect(c.target >= 7_000_000, "not crushed to the floor: \(c.target)")
    }

    /// Fluidity first: once settled on a slow link (with or without a stall once a second, as over AWDL),
    /// frames get smaller, and most of them go out.
    @Test(arguments: [nil, 1000.0])
    func aSlowLinkKeepsTheFrameRate(stallEveryMs: Double?) {
        var c = BitrateController(start: 60_000_000)
        let t = run(&c, seconds: 6, capacityBps: 12_000_000, stallEveryMs: stallEveryMs)
        var last = (sent: 0, held: 0)
        run(&c, seconds: 2, capacityBps: 12_000_000, start: t, stallEveryMs: stallEveryMs) { last = $0 }
        let share = Double(last.sent) / Double(last.sent + last.held)
        // Without a stall nearly all of them; a 270 ms stall a second costs about a quarter by itself.
        #expect(share >= (stallEveryMs == nil ? 0.85 : 0.6), "sent \(last.sent), held \(last.held), target \(c.target)")
        #expect(c.target >= c.config.floor)
    }

    @Test func aFastLinkLetsItClimbBackToTheCeiling() {
        var c = BitrateController(start: 10_000_000)
        run(&c, seconds: 12, capacityBps: 200_000_000)
        #expect(c.target == 60_000_000)
    }

    @Test func aStallOnceASecondIsntCongestion() {
        var c = BitrateController(start: 40_000_000)
        run(&c, seconds: 6, capacityBps: 200_000_000, stallEveryMs: 1000)
        #expect(c.target >= 40_000_000, "\(c.target)")
    }

    @Test func anIdleLinkTeachesNothing() {
        var c = BitrateController(start: 10_000_000)
        // A few tiny refinement-sized acks, clear round trips: the link isn't busy, so no climb.
        for i in 0..<40 { c.acked(bytes: 5_000, rttNs: 8 * Self.ms, at: UInt64(i) * 150 * Self.ms) }
        #expect(c.target == 10_000_000)
    }

    /// Seen on the device: tiny frames at a few per second, one of them caught in a stall. The link delivers
    /// far below the target only because there's little to send: nothing is held back, so it isn't saturated.
    @Test func aQuietLinkWithAStallIsntSaturated() {
        var c = BitrateController(start: 20_000_000)
        for i in 0..<60 {
            let rtt: UInt64 = i % 7 == 0 ? 120 : (i % 3 == 0 ? 25 : 10)
            c.acked(bytes: 1_200, rttNs: rtt * Self.ms, at: UInt64(i) * 70 * Self.ms)
        }
        #expect(c.target == 20_000_000)
    }

    @Test func itNeverLeavesTheFloorAndCeiling() {
        var c = BitrateController(start: 1)
        #expect(c.target == c.config.floor)
        run(&c, seconds: 3, capacityBps: 1_000_000)
        #expect(c.target == c.config.floor)
        let high = BitrateController(start: .max)
        #expect(high.target == high.config.ceiling)
    }

    @Test func queueingAndDeliveryAreMeasured() {
        var c = BitrateController(start: 20_000_000)
        for i in 0..<10 { c.acked(bytes: 50_000, rttNs: (10 + UInt64(i % 2) * 40) * Self.ms, at: UInt64(i) * 50 * Self.ms) }
        let now = 9 * 50 * Self.ms
        #expect(c.minRttNs == 10 * Self.ms)
        #expect(c.queueingMs(at: now).map { Int($0.rounded()) } == 40)
        #expect(c.deliveryBps(at: now).map { $0 / 1_000_000 } == 8)   // 10 × 50 KB over 500 ms
    }
}
