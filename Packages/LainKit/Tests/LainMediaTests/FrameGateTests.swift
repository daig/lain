import Synchronization
import Testing
@testable import LainMedia

/// Records what the gate submits to the "encoder".
final class Submissions: Sendable {
    let ids = Mutex<[Int]>([])
    func add(_ id: Int) { ids.withLock { $0.append(id) } }
    var all: [Int] { ids.withLock { $0 } }
}

@Suite struct Gate {
    @Test func encodesImmediatelyWhenIdle() {
        let subs = Submissions()
        let gate = FrameGate<Int>(maxInFlight: 2) { subs.add($0) }
        gate.offer(1)
        #expect(subs.all == [1])
        #expect(!gate.slotOccupied)
    }

    @Test func oneFrameInTheEncoderAndLatestWins() {
        let subs = Submissions()
        let gate = FrameGate<Int>(maxInFlight: 2) { subs.add($0) }
        gate.offer(1)            // encoding
        gate.offer(2)            // slot
        gate.offer(3)            // replaces 2
        #expect(subs.all == [1])
        #expect(gate.stats.droppedBeforeEncode == 1)
        gate.sent(frameId: 1)    // encoder free → 3 goes in
        #expect(subs.all == [1, 3])
        #expect(!gate.slotOccupied)
    }

    @Test func staleReofferNeverReplacesOrFollowsANewerFrame() {
        let subs = Submissions()
        let newest = Atomic<Int>(1)
        let gate = FrameGate<Int>(maxInFlight: 2, isStale: { $0 < newest.load(ordering: .relaxed) }) { subs.add($0) }
        gate.offer(1)                        // encoding
        newest.store(2, ordering: .relaxed)
        gate.offer(2)                        // slot
        gate.offer(1)                        // an idle refinement of 1 built just before 2 arrived
        #expect(gate.stats.staleRejected == 1 && gate.stats.droppedBeforeEncode == 0)
        gate.sent(frameId: 1)
        #expect(subs.all == [1, 2])
        gate.sent(frameId: 2)
        gate.acked(frameId: 2)
        gate.offer(1)                        // encoder idle: still not encoded after 2
        #expect(subs.all == [1, 2])
        gate.offer(2)                        // a refinement of the newest frame is fine
        #expect(subs.all == [1, 2, 2])
    }

    @Test func unackedFramesHoldTheSlot() {
        let subs = Submissions()
        let gate = FrameGate<Int>(maxInFlight: 2) { subs.add($0) }
        gate.offer(1); gate.sent(frameId: 1)
        gate.offer(2); gate.sent(frameId: 2)
        gate.offer(3)                        // 2 in flight: waits
        gate.offer(4)                        // latest wins
        #expect(subs.all == [1, 2])
        #expect(gate.inFlight == 2)
        gate.acked(frameId: 1)
        #expect(subs.all == [1, 2, 4])
        #expect(gate.stats == .init(offered: 4, encoded: 3, droppedBeforeEncode: 1, peakInFlight: 2))
    }

    @Test func cumulativeAcksAndFailures() {
        let subs = Submissions()
        let gate = FrameGate<Int>(maxInFlight: 2) { subs.add($0) }
        gate.offer(1); gate.sent(frameId: 1)
        gate.offer(2); gate.sent(frameId: 2)
        gate.acked(frameId: 2)               // retires 1 and 2
        #expect(gate.inFlight == 0)
        gate.offer(3)
        gate.offer(4)
        gate.encodeFailed()                  // 3 produced nothing; 4 goes in
        #expect(subs.all == [1, 2, 3, 4])
    }

    @Test func concurrentOffersNeverExceedLimits() async {
        let subs = Submissions()
        let gate = FrameGate<Int>(maxInFlight: 2) { subs.add($0) }
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<4 {
                group.addTask { for i in 0..<500 { gate.offer(t * 1000 + i) } }
            }
            group.addTask {
                for _ in 0..<2000 {
                    let submitted = subs.all
                    if let last = submitted.last { gate.sent(frameId: UInt32(last & 0xFFFF)); gate.acked(frameId: UInt32(last & 0xFFFF)) }
                    await Task.yield()
                }
            }
        }
        let s = gate.stats
        #expect(s.offered == 2000)
        #expect(s.peakInFlight <= 2)
        #expect(s.encoded + s.droppedBeforeEncode + (gate.slotOccupied ? 1 : 0) == s.offered)
    }
}

@Suite struct Refiner {
    let ms: UInt64 = 1_000_000

    @Test func refinesTwiceAfterIdle() {
        var r = IdleRefiner(idleMs: 150, maxRefinements: 2)
        let r1 = r.shouldRefine(at: 0)
        #expect(!r1)              // nothing captured yet
        r.newFrame(at: 0)
        let r2 = r.shouldRefine(at: 149 * ms)
        #expect(!r2)
        let r3 = r.shouldRefine(at: 150 * ms)
        #expect(r3)
        let r4 = r.shouldRefine(at: 200 * ms)
        #expect(!r4)
        let r5 = r.shouldRefine(at: 300 * ms)
        #expect(r5)
        let r6 = r.shouldRefine(at: 900 * ms)
        #expect(!r6)       // at most two
        r.newFrame(at: 1000 * ms)                     // motion resets
        let r7 = r.shouldRefine(at: 1100 * ms)
        #expect(!r7)
        let r8 = r.shouldRefine(at: 1150 * ms)
        #expect(r8)
    }
}
