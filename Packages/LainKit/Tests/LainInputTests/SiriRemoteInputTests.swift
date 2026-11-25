import Darwin
import LainInput
import LainProtocol
import Testing

@Suite struct SiriRemoteInputTests {
    private let ms: UInt64 = 1_000_000

    @Test func touchdownSetsAnchorWithoutJumpingAndMovesRelatively() {
        var r = SiriRemoteInput()
        #expect(r.surfaceTouched(true, at: 10 * ms).isEmpty)
        #expect(r.surfaceMoved(x: 0.4, y: -0.3, at: 15 * ms).isEmpty)
        let moved = r.surfaceMoved(x: 0.5, y: -0.1, at: 25 * ms)
        #expect(moved.count == 1)
        if case .moveBy(let dx, let dy) = moved[0] {
            #expect(abs(dx - 0.1 * r.padScale) < 1e-6)
            #expect(abs(dy - 0.2 * r.padScale) < 1e-6)
        } else {
            Issue.record("expected .moveBy, got \(moved)")
        }
    }

    @Test func liftToZeroIsSuppressedInBothEventOrderings() {
        // Order A: touched(false) before dpad(0, 0).
        var a = SiriRemoteInput()
        _ = a.surfaceTouched(true, at: 0)
        _ = a.surfaceMoved(x: 0.8, y: 0.6, at: 10 * ms)
        #expect(a.surfaceTouched(false, at: 20 * ms).isEmpty)
        #expect(a.surfaceMoved(x: 0, y: 0, at: 21 * ms).isEmpty)

        // Order B: dpad(0, 0) arrives slightly before touched(false) (GCMicroGamepad race).
        var b = SiriRemoteInput()
        _ = b.surfaceTouched(true, at: 0)
        _ = b.surfaceMoved(x: 0.8, y: 0.6, at: 10 * ms)
        #expect(b.surfaceMoved(x: 0, y: 0, at: 20 * ms).isEmpty)
        #expect(b.surfaceTouched(false, at: 22 * ms).isEmpty)
    }

    @Test func clickStabilizationRollsBackSmallPreClickThumbRoll() {
        var r = SiriRemoteInput()
        _ = r.surfaceTouched(true, at: 0)
        _ = r.surfaceMoved(x: 0.0, y: 0.0, at: 10 * ms)
        // Small pre-click thumb roll right before pressing Center (~4.2 counts).
        let drift = r.surfaceMoved(x: 0.03, y: 0.0, at: 40 * ms)
        #expect(drift.count == 1)
        let click = r.centerButton(isDown: true, at: 60 * ms)
        #expect(click.count == 2)
        if case .moveBy(let dx, let dy) = click[0] {
            #expect(abs(dx + 0.03 * r.padScale) < 1e-6)
            #expect(abs(dy) < 1e-6)
        } else {
            Issue.record("expected stabilizing rollback before click, got \(click)")
        }
        #expect(click[1] == .button(.left, isDown: true))
    }

    @Test func clickStabilizationDoesNotUndoFastDeliberateFlick() {
        var r = SiriRemoteInput()
        _ = r.surfaceTouched(true, at: 0)
        _ = r.surfaceMoved(x: 0.0, y: 0.0, at: 10 * ms)
        // Large deliberate swipe (0.4 * 140 = 56 counts > stabilizeMaxTravel 14).
        _ = r.surfaceMoved(x: 0.4, y: 0.0, at: 40 * ms)
        let click = r.centerButton(isDown: true, at: 55 * ms)
        #expect(click == [.button(.left, isDown: true)])
    }

    @Test func postClickFreezeAbsorbsMicroJitterThenAllowsDeliberateDrag() {
        var r = SiriRemoteInput()
        _ = r.surfaceTouched(true, at: 0)
        _ = r.surfaceMoved(x: 0.0, y: 0.0, at: 10 * ms)
        _ = r.centerButton(isDown: true, at: 100 * ms)
        // Tiny mechanical settle within freeze window (2.8 counts < clickSlop 8).
        #expect(r.surfaceMoved(x: 0.02, y: 0.0, at: 120 * ms).isEmpty)
        // Deliberate drag exceeding clickSlop (0.12 * 140 = 16.8 counts).
        let drag = r.surfaceMoved(x: 0.14, y: 0.0, at: 130 * ms)
        #expect(drag.count == 1)
        if case .moveBy(let dx, _) = drag[0] {
            #expect(dx > 10)
        } else {
            Issue.record("expected drag moveBy, got \(drag)")
        }
        #expect(r.centerButton(isDown: false, at: 200 * ms) == [.button(.left, isDown: false)])
    }

    @Test func dragLockLatchesOnHoldStillAndDropsOnSecondClickOrBack() {
        var r = SiriRemoteInput()
        #expect(r.centerButton(isDown: true, at: 0) == [.button(.left, isDown: true)])
        #expect(r.tick(at: 300 * ms).isEmpty)
        #expect(r.tick(at: 450 * ms) == [.dragLockChanged(true)])
        #expect(r.isDragLocked)
        // Releasing Center keeps left button down.
        #expect(r.centerButton(isDown: false, at: 500 * ms).isEmpty)
        #expect(r.isLeftDown)
        // Clutching the thumb across the pad still moves while locked.
        _ = r.surfaceTouched(true, at: 600 * ms)
        _ = r.surfaceMoved(x: -0.5, y: 0.0, at: 610 * ms)
        #expect(r.surfaceMoved(x: 0.5, y: 0.0, at: 650 * ms).count == 1)
        _ = r.surfaceTouched(false, at: 660 * ms)
        // Second Center click cleanly drops Drag Lock without sending a fresh click.
        #expect(r.centerButton(isDown: true, at: 700 * ms) == [.button(.left, isDown: false), .dragLockChanged(false)])
        #expect(r.centerButton(isDown: false, at: 760 * ms).isEmpty)
        #expect(!r.isDragLocked && !r.isLeftDown)

        // Back press also cancels Drag Lock without emitting Escape.
        _ = r.centerButton(isDown: true, at: 1000 * ms)
        _ = r.tick(at: 1450 * ms)
        _ = r.centerButton(isDown: false, at: 1500 * ms)
        #expect(r.menu(isDown: true, at: 1600 * ms) == [.button(.left, isDown: false), .dragLockChanged(false)])
        #expect(r.menu(isDown: false, at: 1650 * ms).isEmpty)
    }

    @Test func outerRingTapAndContinuousHoldScrollWithCorrectSigns() {
        var r = SiriRemoteInput()
        let down = r.ringDirection(.down, isDown: true, at: 0)
        #expect(down == [.scrollBegan, .scroll(dx: 0, dy: -r.ringTapScroll)])
        // Before repeat delay: no extra scroll yet.
        #expect(r.tick(at: 100 * ms).isEmpty)
        // After repeat delay: smooth ramped continuous scroll ticks.
        _ = r.tick(at: 180 * ms)
        let early = r.tick(at: 200 * ms)
        let later = r.tick(at: 900 * ms)
        let fast = r.tick(at: 920 * ms)
        guard case .scroll(_, let dyEarly) = early.first,
              case .scroll(_, let dyFast) = fast.first else {
            Issue.record("expected continuous scroll actions, got \(early) / \(later) / \(fast)")
            return
        }
        #expect(dyEarly < 0 && dyFast < dyEarly)   // negative = scroll down, and faster after ramp
        #expect(r.ringDirection(.down, isDown: false, at: 950 * ms) == [.scrollEnded])

        // Up/Left/Right directions carry the expected signs.
        #expect(r.ringDirection(.up, isDown: true, at: 1000 * ms) == [.scrollBegan, .scroll(dx: 0, dy: r.ringTapScroll)])
        #expect(r.ringDirection(.up, isDown: false, at: 1020 * ms) == [.scrollEnded])
        #expect(r.ringDirection(.left, isDown: true, at: 1100 * ms) == [.scrollBegan, .scroll(dx: r.ringTapScroll, dy: 0)])
        #expect(r.ringDirection(.left, isDown: false, at: 1120 * ms) == [.scrollEnded])
        #expect(r.ringDirection(.right, isDown: true, at: 1200 * ms) == [.scrollBegan, .scroll(dx: -r.ringTapScroll, dy: 0)])
        #expect(r.ringDirection(.right, isDown: false, at: 1220 * ms) == [.scrollEnded])
    }

    @Test func outerRingIsSuppressedWhileDragging() {
        var r = SiriRemoteInput()
        _ = r.centerButton(isDown: true, at: 0)
        #expect(r.ringDirection(.down, isDown: true, at: 50 * ms).isEmpty)
        #expect(r.ringDirection(.down, isDown: false, at: 100 * ms).isEmpty)
        _ = r.centerButton(isDown: false, at: 150 * ms)
    }

    @Test func outerRingCircularJogEngagesAndScrollsVertically() {
        var r = SiriRemoteInput()
        _ = r.surfaceTouched(true, at: 0)
        // Start on outer ring at angle π/2 (top: x=0, y=0.85) and sweep clockwise (decreasing angle).
        let radius = 0.85
        var angle = Double.pi / 2
        _ = r.surfaceMoved(x: radius * cos(angle), y: radius * sin(angle), at: 10 * ms)
        var engaged = false
        var totalScrollY = 0.0
        for step in 1...10 {
            angle -= 0.15   // clockwise: 1.5 rad total (> jogEngageRadians 0.66)
            let actions = r.surfaceMoved(x: radius * cos(angle), y: radius * sin(angle),
                                         at: UInt64(10 + step * 16) * ms)
            for a in actions {
                if a == .scrollBegan { engaged = true }
                if case .scroll(_, let dy) = a { totalScrollY += dy }
            }
        }
        #expect(engaged)
        #expect(totalScrollY < -50)   // clockwise scrolls down (negative dy)
        #expect(r.surfaceTouched(false, at: 200 * ms) == [.scrollEnded])
    }

    @Test func circularJogDisarmsWhenMovingIntoInterior() {
        var r = SiriRemoteInput()
        _ = r.surfaceTouched(true, at: 0)
        _ = r.surfaceMoved(x: 0.0, y: 0.85, at: 10 * ms)
        // Cut straight through center (r = 0.1 < jogKeepRadius): disarms jog permanently for this touch.
        let across = r.surfaceMoved(x: 0.1, y: 0.0, at: 25 * ms)
        #expect(across.allSatisfy { if case .moveBy = $0 { true } else { false } })
        // Even circling the outer ring later in the same touch stays pointer movement.
        let backOut = r.surfaceMoved(x: 0.85, y: 0.0, at: 40 * ms)
        #expect(backOut.allSatisfy { if case .moveBy = $0 { true } else { false } })
    }

    @Test func playPauseTapRightClicksAndHoldTogglesZoom() {
        var r = SiriRemoteInput()
        #expect(r.playPause(isDown: true, at: 0).isEmpty)
        #expect(r.playPause(isDown: false, at: 120 * ms) == [
            .button(.right, isDown: true),
            .button(.right, isDown: false),
        ])

        // Hold past longPressNs: toggles zoom, and release emits no right-click.
        #expect(r.playPause(isDown: true, at: 500 * ms).isEmpty)
        #expect(r.tick(at: 850 * ms).isEmpty)
        #expect(r.tick(at: 900 * ms) == [.toggleZoom])
        #expect(r.playPause(isDown: false, at: 950 * ms).isEmpty)
    }

    @Test func menuTapSendsEscapeAndHoldOpensPanelAndCancelsActiveState() {
        var r = SiriRemoteInput()
        #expect(r.menu(isDown: true, at: 0).isEmpty)
        #expect(r.menu(isDown: false, at: 100 * ms) == [.keyTap(.escape)])

        // Holding ring scroll + long-pressing Menu cancels the scroll and opens panel.
        _ = r.ringDirection(.down, isDown: true, at: 500 * ms)
        _ = r.menu(isDown: true, at: 600 * ms)
        #expect(r.tick(at: 1000 * ms) == [.scrollCancelled, .openPanel])
        #expect(r.menu(isDown: false, at: 1100 * ms).isEmpty)
    }

    @Test func cancelledReleasesHeldDragLockAndScroll() {
        var r = SiriRemoteInput()
        _ = r.centerButton(isDown: true, at: 0)
        _ = r.tick(at: 450 * ms)
        _ = r.centerButton(isDown: false, at: 500 * ms)
        let cancel = r.cancelled()
        #expect(cancel == [.button(.left, isDown: false), .dragLockChanged(false)])
        #expect(!r.isActive)
    }
}
