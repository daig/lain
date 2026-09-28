import LainProtocol
import Testing
@testable import LainInput

private let frame: UInt64 = 8_333_333   // 120 Hz

@Suite struct Acceleration {
    @Test func slowMotionIsLinear() {
        let c = AccelerationCurve()
        #expect(c.gain(speed: 0) == 1)
        #expect(c.gain(speed: c.threshold) == 1)
    }

    @Test func gainRisesMonotonicallyAndCaps() {
        let c = AccelerationCurve()
        var last = 1.0
        for speed in stride(from: 400.0, through: 40_000, by: 400) {
            let g = c.gain(speed: speed)
            #expect(g >= last)
            last = g
        }
        #expect(last == c.maxGain)
    }

    @Test func zeroAccelerationIsLinearEverywhere() {
        let c = AccelerationCurve(sensitivity: 1, acceleration: 0)
        #expect(c.gain(speed: 1_000_000) == 1)
    }
}

@Suite struct Tracking {
    @Test func zeroDeltasAreIgnored() {
        var p = PointerTracker(width: 1376, height: 1032)
        let r1 = p.move(dx: 0, dy: 0, at: frame, buttons: 0)
        #expect(r1 == nil)
    }

    @Test func yIsFlippedAndSlowMovesUseSensitivity() throws {
        var p = PointerTracker(width: 1376, height: 1032, curve: AccelerationCurve(sensitivity: 1, acceleration: 1))
        let mResult = p.move(dx: 2, dy: 3, at: frame, buttons: 0b10)   // 3.6 counts/frame = 432/s… near linear
        let m = try #require(mResult)
        #expect(m.dx > 0 && m.dy < 0)                                          // GCMouse y up → Mac y down
        #expect(m.buttons == 0b10)
        let slowResult = p.move(dx: 1, dy: 0, at: frame * 2, buttons: 0)
        let slow = try #require(slowResult)
        #expect(slow.dx == 1)                                                   // 120 counts/s: gain 1
        #expect(slow.x == m.x + 1)
    }

    @Test func fastFlicksMoveFurtherPerCount() throws {
        var slow = PointerTracker(width: 10_000, height: 10_000)
        var fast = PointerTracker(width: 10_000, height: 10_000)
        let aResult = slow.move(dx: 2, dy: 0, at: frame, buttons: 0)
        let a = try #require(aResult)
        let bResult = fast.move(dx: 60, dy: 0, at: frame, buttons: 0)
        let b = try #require(bResult)
        #expect(Double(b.dx) / 60 > Double(a.dx) / 2)
    }

    @Test func idleGapsDoNotLookSlow() throws {
        // After a pause, the first delta is timed as one nominal frame, not as a 2 s interval.
        var p = PointerTracker(width: 10_000, height: 10_000)
        var q = PointerTracker(width: 10_000, height: 10_000)
        _ = p.move(dx: 1, dy: 0, at: frame, buttons: 0)
        let lateResult = p.move(dx: 40, dy: 0, at: frame + 2_000_000_000, buttons: 0)
        let late = try #require(lateResult)
        let freshResult = q.move(dx: 40, dy: 0, at: frame, buttons: 0)
        let fresh = try #require(freshResult)
        #expect(late.dx == fresh.dx)
    }

    @Test func clampsWithTheHotspotOnTheEdges() throws {
        var p = PointerTracker(width: 1376, height: 1032)
        for i in 1...200 { _ = p.move(dx: -97, dy: 97, at: UInt64(i) * frame, buttons: 0) }
        #expect(p.x == 0 && p.y == 0)
        for i in 201...400 { _ = p.move(dx: 97, dy: -97, at: UInt64(i) * frame, buttons: 0) }
        #expect(p.x == 1375 && p.y == 1031)
        p.warp(x: -50, y: 5000)
        #expect(p.x == 0 && p.y == 1031)
        p.resize(width: 800, height: 600)
        #expect(p.y == 599)
    }
}

@Suite struct Clicks {
    let ms: UInt64 = 1_000_000

    @Test func countsSequencesWithinIntervalAndDistance() {
        var c = ClickCounter(intervalMs: 500, maxDistance: 4)
        let r2 = c.down(.left, x: 10, y: 10, at: 0)
        #expect(r2 == 1)
        #expect(c.upCount(.left) == 1)
        let r3 = c.down(.left, x: 12, y: 11, at: 300 * ms)
        #expect(r3 == 2)
        let r4 = c.down(.left, x: 12, y: 11, at: 700 * ms)
        #expect(r4 == 3)
        #expect(c.upCount(.left) == 3)
    }

    @Test func tapToClickTimingCounts() {
        // Tap-to-click arrives as down/up 0.2 ms apart (§13); taps ~150 ms apart are a double-click.
        var c = ClickCounter()
        let r5 = c.down(.left, x: 0, y: 0, at: 0)
        #expect(r5 == 1)
        let r6 = c.down(.left, x: 0, y: 0, at: 150 * ms)
        #expect(r6 == 2)
    }

    @Test func sequenceBreaks() {
        var c = ClickCounter(intervalMs: 500, maxDistance: 4)
        _ = c.down(.left, x: 0, y: 0, at: 0)
        let r7 = c.down(.left, x: 0, y: 0, at: 501 * ms)
        #expect(r7 == 1)     // too slow
        let r8 = c.down(.left, x: 10, y: 0, at: 600 * ms)
        #expect(r8 == 1)    // moved too far
        let r9 = c.down(.right, x: 10, y: 0, at: 700 * ms)
        #expect(r9 == 1)   // other button
        #expect(c.upCount(.left) == 1)
    }
}

@Suite struct Buttons {
    @Test func tracksAndReleases() {
        var b = HeldButtons()
        let r10 = b.set(.left, down: true)
        #expect(r10)
        let r11 = b.set(.left, down: true)
        #expect(!r11)
        let r12 = b.set(.right, down: false)
        #expect(!r12)   // orphan up
        let r13 = b.set(.right, down: true)
        #expect(r13)
        #expect(b.mask == 0b11)
        let ups = b.releaseAll(x: 5, y: 6)
        #expect(ups.map(\.button) == [.left, .right])
        #expect(ups.allSatisfy { !$0.isDown && $0.x == 5 })
        #expect(b.mask == 0)
    }
}
