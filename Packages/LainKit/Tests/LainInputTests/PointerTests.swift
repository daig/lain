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

@Suite struct FractionalDeltas {
    @Test func iPadOS27FractionalDeltasAreApplied() throws {
        // iPadOS 27 sends fractional GCMouse deltas (e.g. 1.71, -0.24; InputLab 2026-09-28).
        var p = PointerTracker(width: 1376, height: 1032, curve: AccelerationCurve(sensitivity: 1, acceleration: 0))
        let r = p.move(dx: 1.71, dy: -0.24, at: 8_333_333, buttons: 0)
        let m = try #require(r)
        #expect(abs(Double(m.dx) - 1.71) < 1e-6 && abs(Double(m.dy) - 0.24) < 1e-6)
        let z = p.move(dx: 0.0, dy: -0.0, at: 16_666_666, buttons: 0)
        #expect(z == nil)
    }
}

/// The full-desktop cursor: global points over every Mac display, macOS-like edge rules.
@Suite struct DesktopTracking {
    /// Unaccelerated: one count = one point, so targets are exact.
    static let linear = AccelerationCurve(sensitivity: 1, acceleration: 0)
    /// Main 1680×1050 at (0, 0); the streamed iPad display 1376×1032 below it, left-aligned (partial
    /// edge overlap); a 1920×1080 monitor to the left of main (it also touches the iPad's top 30 pt).
    static let main = DesktopDisplay(x: 0, y: 0, width: 1680, height: 1050)
    static let pad = DesktopDisplay(x: 0, y: 1050, width: 1376, height: 1032)
    static let left = DesktopDisplay(x: -1920, y: 0, width: 1920, height: 1080)
    static let desktop = [main, pad, left]

    /// A tracker on `displays` with the cursor at (x, y).
    func tracker(_ displays: [DesktopDisplay], at x: Double, _ y: Double) -> PointerTracker {
        var p = PointerTracker(displays: displays, curve: Self.linear)
        p.warp(x: x, y: y)
        return p
    }

    /// Moves by (dx, dy) in Mac points (y down).
    @discardableResult
    func move(_ p: inout PointerTracker, _ dx: Double, _ dy: Double, step: UInt64 = 1) -> PointerMove? {
        p.move(dx: dx, dy: -dy, at: step * frame, buttons: 0)
    }

    @Test func singleDisplayInitIsOneDisplayAtTheOrigin() {
        let p = PointerTracker(width: 1376, height: 1032)
        #expect(p.displays == [DesktopDisplay(x: 0, y: 0, width: 1376, height: 1032)])
        #expect(p.x == 688 && p.y == 516 && p.displayIndex == 0)
    }

    @Test func startsInTheCentreOfTheChosenDisplay() {
        let p = PointerTracker(displays: Self.desktop, startIndex: 1)
        #expect(p.x == 688 && p.y == 1050 + 516 && p.displayIndex == 1)
    }

    @Test func crossesRightAndLeftBetweenSideBySideDisplays() throws {
        let a = DesktopDisplay(x: 0, y: 0, width: 1000, height: 800)
        let b = DesktopDisplay(x: 1000, y: 0, width: 1000, height: 800)
        var p = tracker([a, b], at: 500, 400)
        let r = move(&p, 600, 0)
        let m = try #require(r)
        #expect(p.x == 1100 && p.y == 400 && p.displayIndex == 1)
        #expect(m.x == 1100 && m.dx == 600)   // PointerMove carries the global position
        move(&p, -700, 0, step: 2)
        #expect(p.x == 400 && p.displayIndex == 0)
        // Diagonal across the shared edge keeps both components.
        p.warp(x: 990, y: 400)
        move(&p, 20, 10, step: 3)
        #expect(p.x == 1010 && p.y == 410 && p.displayIndex == 1)
    }

    @Test func crossesDownAndUpWhereTheEdgesOverlap() {
        var p = tracker(Self.desktop, at: 500, 525)
        move(&p, 0, 600)
        #expect(p.x == 500 && p.y == 1125 && p.displayIndex == 1)   // onto the iPad display
        move(&p, 0, -1000, step: 2)
        #expect(p.x == 500 && p.y == 125 && p.displayIndex == 0)    // back up to main
    }

    @Test func partialOverlapBlocksOutsideTheSharedSegment() {
        // Main is wider than the iPad display below it: past x = 1375 its bottom edge is an outer edge.
        var p = tracker(Self.desktop, at: 1500, 900)
        move(&p, 0, 400)
        #expect(p.x == 1500 && p.y == 1049 && p.displayIndex == 0)
        // Sliding along the bottom edge, then down where the iPad display begins.
        move(&p, -200, 0, step: 2)
        #expect(p.x == 1300 && p.y == 1049)
        move(&p, 0, 100, step: 3)
        #expect(p.x == 1300 && p.y == 1149 && p.displayIndex == 1)
    }

    @Test func crossesLeftOntoTheSideMonitorFromEitherDisplay() {
        var p = tracker(Self.desktop, at: 100, 500)
        move(&p, -600, 0)
        #expect(p.x == -500 && p.y == 500 && p.displayIndex == 2)
        // The iPad display's left edge touches the side monitor only for y 1050..<1080.
        p.warp(x: 100, y: 1060)
        move(&p, -300, 0, step: 2)
        #expect(p.x == -200 && p.y == 1060 && p.displayIndex == 2)
        p.warp(x: 100, y: 1500)
        move(&p, -300, 0, step: 3)
        #expect(p.x == 0 && p.y == 1500 && p.displayIndex == 1)   // blocked below the side monitor
    }

    @Test func clampsAtOuterEdgesWithTheHotspotOnTheLastPoint() {
        var p = tracker(Self.desktop, at: 700, 1500)
        move(&p, 0, 5000)
        #expect(p.y == 1050 + 1031 && p.displayIndex == 1)
        move(&p, 5000, 0, step: 2)
        #expect(p.x == 1375)
        p.warp(x: -1000, y: 500)
        move(&p, -5000, -5000, step: 3)
        #expect(p.x == -1920 && p.y == 0 && p.displayIndex == 2)
        move(&p, 0, 5000, step: 4)
        #expect(p.y == 1079 && p.displayIndex == 2)   // the side monitor's bottom is an outer edge
    }

    @Test func gapsAndCornerOnlyContactAreNotCrossed() {
        let a = DesktopDisplay(x: 0, y: 0, width: 1000, height: 800)
        let gapped = DesktopDisplay(x: 1010, y: 0, width: 1000, height: 800)
        var p = tracker([a, gapped], at: 950, 400)
        move(&p, 100, 0)
        #expect(p.x == 999 && p.displayIndex == 0)
        let corner = DesktopDisplay(x: 1000, y: 800, width: 1000, height: 800)
        var q = tracker([a, corner], at: 990, 790)
        move(&q, 20, 20)
        #expect(q.x == 999 && q.y == 799 && q.displayIndex == 0)
    }

    @Test func blockedEdgesSlide() {
        let a = DesktopDisplay(x: 0, y: 0, width: 1000, height: 800)
        var p = tracker([a], at: 990, 400)
        move(&p, 20, 10)
        #expect(p.x == 999 && p.y == 410)
    }

    @Test func warpsLandAnywhereAndSnapOffDesktopPositions() {
        var p = tracker(Self.desktop, at: 0, 0)
        p.warp(x: -1000, y: 500)
        #expect(p.x == -1000 && p.y == 500 && p.displayIndex == 2)
        p.warp(x: 800, y: 1500)
        #expect(p.displayIndex == 1)
        // Right of the iPad display, below main: the nearest point is on the iPad display's right edge.
        p.warp(x: 1500, y: 1500)
        #expect(p.x == 1375 && p.y == 1500 && p.displayIndex == 1)
        // In a gap: the nearer display wins.
        var q = tracker([DesktopDisplay(x: 0, y: 0, width: 1000, height: 800),
                         DesktopDisplay(x: 1010, y: 0, width: 1000, height: 800)], at: 0, 0)
        q.warp(x: 1006, y: 400)
        #expect(q.x == 1010 && q.displayIndex == 1)
    }

    @Test func layoutChangesKeepOrSnapThePosition() {
        var p = tracker(Self.desktop, at: -500, 300)
        // The arrangement changes but the cursor's spot still exists: it stays.
        p.setDesktop([Self.left, Self.main])
        #expect(p.x == -500 && p.y == 300 && p.displayIndex == 0)
        // The side monitor is unplugged: snap onto main's left edge.
        p.setDesktop([Self.main, Self.pad])
        #expect(p.x == 0 && p.y == 300 && p.displayIndex == 0)
        // The iPad display shrinks under the cursor.
        p.warp(x: 1300, y: 2000)
        p.setDesktop([Self.main, DesktopDisplay(x: 0, y: 1050, width: 1024, height: 768)])
        #expect(p.x == 1023 && p.y == 1050 + 767 && p.displayIndex == 1)
        // Movement uses the new layout right away.
        move(&p, 0, -900)
        #expect(p.y == 1050 + 767 - 900 && p.displayIndex == 0)
    }
}
