import LainInput
import LainProtocol
import Testing

private let ms: UInt64 = 1_000_000
private typealias A = TouchGestures.Action
private let click: [A] = [.button(.left, isDown: true), .button(.left, isDown: false)]
private let rightClick: [A] = [.button(.right, isDown: true), .button(.right, isDown: false)]

@Suite struct TouchGesturesTests {
    // MARK: Direct

    @Test func directTapMovesThereAndClicks() {
        var g = TouchGestures(mode: .direct)
        #expect(g.began(id: 1, x: 100, y: 200, at: 0) == [.moveTo(x: 100, y: 200)])
        #expect(g.tick(at: 20 * ms) == [], "still waiting for a second finger")
        #expect(g.ended(id: 1, at: 40 * ms) == click)
        #expect(!g.isActive)
    }

    @Test func directHoldPressesAndKeepsTheButtonDownUntilTheFingerLifts() {
        var g = TouchGestures(mode: .direct)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        #expect(g.tick(at: 80 * ms) == [.button(.left, isDown: true)])
        #expect(g.tick(at: 900 * ms) == [], "no long press: the button just stays down")
        #expect(g.moved(id: 1, x: 104, y: 203, at: 950 * ms) == [], "jitter inside the slop doesn't drag")
        #expect(g.moved(id: 1, x: 150, y: 200, at: 1000 * ms) == [.moveTo(x: 150, y: 200)])
        #expect(g.moved(id: 1, x: 152, y: 201, at: 1010 * ms) == [.moveTo(x: 152, y: 201)], "then every move follows")
        #expect(g.ended(id: 1, at: 1100 * ms) == [.button(.left, isDown: false)])
    }

    @Test func directMovingBeforeTheDelayPressesWhereItLanded() {
        var g = TouchGestures(mode: .direct)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        #expect(g.moved(id: 1, x: 130, y: 200, at: 10 * ms) == [.button(.left, isDown: true), .moveTo(x: 130, y: 200)])
        #expect(g.tick(at: 100 * ms) == [], "already pressed")
        #expect(g.ended(id: 1, at: 200 * ms) == [.button(.left, isDown: false)])
    }

    @Test func directSecondTapNearbyLandsOnTheFirst() {
        var g = TouchGestures(mode: .direct)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        _ = g.ended(id: 1, at: 50 * ms)
        #expect(g.began(id: 2, x: 112, y: 190, at: 200 * ms) == [.moveTo(x: 100, y: 200)], "so the host counts a double-click")
        _ = g.ended(id: 2, at: 250 * ms)
        #expect(g.began(id: 3, x: 300, y: 300, at: 400 * ms) == [.moveTo(x: 300, y: 300)], "far away: its own point")
        _ = g.ended(id: 3, at: 450 * ms)
        #expect(g.began(id: 4, x: 302, y: 300, at: 2000 * ms) == [.moveTo(x: 302, y: 300)], "too late: its own point")
    }

    @Test func directHeldTapAlsoAnchorsADoubleTap() {
        var g = TouchGestures(mode: .direct)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        _ = g.tick(at: 90 * ms)
        #expect(g.ended(id: 1, at: 150 * ms) == [.button(.left, isDown: false)])
        #expect(g.began(id: 2, x: 108, y: 204, at: 300 * ms) == [.moveTo(x: 100, y: 200)])
    }

    // MARK: Two fingers (both modes)

    @Test(arguments: [TouchMode.direct, .trackpad]) func twoFingersScrollWithoutClicking(mode: TouchMode) {
        var g = TouchGestures(mode: mode)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        #expect(g.began(id: 2, x: 140, y: 200, at: 30 * ms) == [])
        #expect(g.tick(at: 200 * ms) == [], "no press with two fingers down")
        #expect(g.moved(id: 1, x: 100, y: 204, at: 210 * ms) == [], "inside the slop")
        #expect(g.moved(id: 1, x: 100, y: 230, at: 220 * ms) == [.scrollBegan, .scroll(dx: 0, dy: 15)])
        #expect(g.moved(id: 2, x: 140, y: 230, at: 230 * ms) == [.scroll(dx: 0, dy: 15)])
        #expect(g.ended(id: 1, at: 300 * ms) == [.scrollEnded])
        #expect(g.moved(id: 2, x: 140, y: 300, at: 310 * ms) == [], "the other finger is spent")
        #expect(g.ended(id: 2, at: 320 * ms) == [])
        #expect(!g.isActive)
    }

    @Test(arguments: [TouchMode.direct, .trackpad]) func twoFingerTapRightClicks(mode: TouchMode) {
        var g = TouchGestures(mode: mode)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        _ = g.began(id: 2, x: 140, y: 200, at: 20 * ms)
        #expect(g.ended(id: 2, at: 120 * ms) == rightClick)
        #expect(g.ended(id: 1, at: 130 * ms) == [])
    }

    @Test func twoFingersHeldTooLongIsNoTap() {
        var g = TouchGestures(mode: .trackpad)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        _ = g.began(id: 2, x: 140, y: 200, at: 20 * ms)
        #expect(g.ended(id: 2, at: 800 * ms) == [])
    }

    @Test func aThirdFingerEndsTheScroll() {
        var g = TouchGestures(mode: .direct)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        _ = g.began(id: 2, x: 140, y: 200, at: 10 * ms)
        _ = g.moved(id: 1, x: 100, y: 260, at: 50 * ms)
        #expect(g.began(id: 3, x: 300, y: 200, at: 60 * ms) == [.scrollEnded])
        #expect(g.moved(id: 1, x: 100, y: 300, at: 70 * ms) == [])
    }

    @Test func aSecondFingerDoesNotDisturbADrag() {
        var g = TouchGestures(mode: .direct)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        _ = g.tick(at: 100 * ms)
        #expect(g.began(id: 2, x: 300, y: 300, at: 200 * ms) == [])
        #expect(g.moved(id: 1, x: 160, y: 200, at: 210 * ms) == [.moveTo(x: 160, y: 200)])
        #expect(g.ended(id: 2, at: 220 * ms) == [])
        #expect(g.ended(id: 1, at: 230 * ms) == [.button(.left, isDown: false)])
    }

    // MARK: Trackpad

    @Test func trackpadFingerMovesThePointerWithoutClicking() {
        var g = TouchGestures(mode: .trackpad)
        #expect(g.began(id: 1, x: 100, y: 200, at: 0) == [])
        #expect(g.tick(at: 100 * ms) == [])
        #expect(g.moved(id: 1, x: 120, y: 200, at: 110 * ms) == [.moveBy(dx: 20, dy: 0)])
        #expect(g.tick(at: 900 * ms) == [], "a finger that has moved never presses")
        #expect(g.moved(id: 1, x: 125, y: 210, at: 920 * ms) == [.moveBy(dx: 5, dy: 10)])
        #expect(g.ended(id: 1, at: 1000 * ms) == [])
    }

    @Test func trackpadTapClicksAndARestingFingerDoesNot() {
        var g = TouchGestures(mode: .trackpad)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        #expect(g.ended(id: 1, at: 100 * ms) == click)
        _ = g.began(id: 2, x: 100, y: 200, at: 1000 * ms)
        #expect(g.ended(id: 2, at: 1350 * ms) == [], "too long to be a tap, too short to press")
    }

    @Test func trackpadTapThenDragHoldsTheButton() {
        var g = TouchGestures(mode: .trackpad)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        _ = g.ended(id: 1, at: 80 * ms)
        _ = g.began(id: 2, x: 100, y: 200, at: 200 * ms)
        #expect(g.moved(id: 2, x: 130, y: 200, at: 260 * ms) == [.button(.left, isDown: true), .moveBy(dx: 30, dy: 0)])
        #expect(g.moved(id: 2, x: 140, y: 205, at: 270 * ms) == [.moveBy(dx: 10, dy: 5)])
        #expect(g.ended(id: 2, at: 400 * ms) == [.button(.left, isDown: false)])
    }

    @Test func trackpadHoldingStillPressesToDrag() {
        var g = TouchGestures(mode: .trackpad)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        #expect(g.tick(at: 390 * ms) == [])
        #expect(g.tick(at: 400 * ms) == [.button(.left, isDown: true)])
        #expect(g.moved(id: 1, x: 103, y: 202, at: 450 * ms) == [], "jitter inside the slop")
        #expect(g.moved(id: 1, x: 130, y: 200, at: 500 * ms) == [.moveBy(dx: 30, dy: 0)])
        #expect(g.moved(id: 1, x: 135, y: 200, at: 510 * ms) == [.moveBy(dx: 5, dy: 0)])
        #expect(g.ended(id: 1, at: 600 * ms) == [.button(.left, isDown: false)])
    }

    @Test func trackpadDoubleTapIsTwoClicks() {
        var g = TouchGestures(mode: .trackpad)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        #expect(g.ended(id: 1, at: 80 * ms) == click)
        _ = g.began(id: 2, x: 300, y: 400, at: 200 * ms)
        #expect(g.ended(id: 2, at: 260 * ms) == click, "anywhere on the screen: the pointer hasn't moved")
    }

    // MARK: Cancel, mode, off

    @Test func cancelReleasesWhatWasHeld() {
        var g = TouchGestures(mode: .direct)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        _ = g.tick(at: 100 * ms)
        #expect(g.cancelled() == [.button(.left, isDown: false)])
        #expect(!g.isActive)
        _ = g.began(id: 1, x: 100, y: 200, at: 1000 * ms)
        _ = g.began(id: 2, x: 140, y: 200, at: 1010 * ms)
        _ = g.moved(id: 1, x: 100, y: 260, at: 1050 * ms)
        #expect(g.cancelled() == [.scrollCancelled])
    }

    @Test func changingTheModeEndsTheGestureAndOffIgnoresTouches() {
        var g = TouchGestures(mode: .direct)
        _ = g.began(id: 1, x: 100, y: 200, at: 0)
        _ = g.tick(at: 100 * ms)
        #expect(g.setMode(.off) == [.button(.left, isDown: false)])
        #expect(g.began(id: 2, x: 100, y: 200, at: 500 * ms) == [])
        #expect(g.ended(id: 2, at: 550 * ms) == [])
        #expect(g.setMode(.off) == [])
    }
}
