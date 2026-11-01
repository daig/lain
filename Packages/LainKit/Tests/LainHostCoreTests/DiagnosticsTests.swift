import LainProtocol
import Testing
@testable import LainHostCore

@Suite struct DiagnosticsTests {
    let ms: UInt64 = 1_000_000

    func scroll(_ phase: GesturePhase = .changed) -> Message {
        .scroll(Scroll(dx: 0, dy: 1, phase: phase, momentumPhase: .none))
    }

    /// Steady 8 ms sends that arrive late and bunched: the queueing and the burst show, whatever the clocks.
    @Test func burstsAndQueueingAreMeasuredAgainstTheBestDelay() throws {
        var a = InputArrivals()
        let iPadClock: UInt64 = 5_000_000_000, macClock: UInt64 = 900_000_000_000   // unrelated clocks
        a.record(scroll(.began), sentNs: iPadClock, receivedNs: macClock + 3 * ms)
        a.record(scroll(), sentNs: iPadClock + 8 * ms, receivedNs: macClock + 11 * ms)    // on time
        // A stall: the next three arrive together, 100 ms late.
        for i in 2...4 {
            a.record(scroll(), sentNs: iPadClock + UInt64(i) * 8 * ms, receivedNs: macClock + 135 * ms + UInt64(i) * 100_000)
        }
        a.record(.pointerMove(PointerMove(x: 0, y: 0, dx: 1, dy: 0, buttons: 0)), sentNs: iPadClock + 40 * ms,
                 receivedNs: macClock + 43 * ms + 135 * ms)
        let taken = a.take(), again = a.take()
        let s = try #require(taken)
        #expect(s.scrolls == 5 && s.moves == 1)
        #expect(s.scrollBursts == 2)
        #expect(Int(s.maxScrollGapMs.rounded()) == 124)
        #expect(Int(s.queueingMaxMs.rounded()) == 135)   // the move: sent at 40, in at 178, best delay 3
        #expect(again == nil, "a fresh window")
    }

    @Test func aNewGestureIsntAGap() throws {
        var a = InputArrivals()
        a.record(scroll(.began), sentNs: 0, receivedNs: 0)
        a.record(scroll(.ended), sentNs: 8 * ms, receivedNs: 8 * ms)
        a.record(scroll(.began), sentNs: 2000 * ms, receivedNs: 2000 * ms)
        let taken = a.take()
        let s = try #require(taken)
        #expect(s.maxScrollGapMs == 8)
    }

    @Test func theVideoLine() {
        var w = VideoWindow()
        w.sent = 2; w.bytes = 300 * 1024; w.maxFrameBytes = 200 * 1024; w.ackRttsMs = [40, 180]; w.maxInFlight = 2
        #expect(w.line(captured: 120, droppedBeforeEncode: 118)
                == "video: captured 120, sent 2 (kf 0, refine 0), held back 118 · 2.5 Mb/s, frame mean 150 KB max 200 KB · ack p50 180 max 180 ms · in flight max 2")
    }
}
