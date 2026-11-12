import LainClientCore
import LainInput
import LainProtocol
import Testing

/// Fingers on the screen, through the pipeline to the wire. `ack`: a 1376 × 1032 point display.
@Suite struct TouchInputTests {
    private func recorder(_ mode: TouchMode, surface: (Double, Double) = (1376, 1032)) -> Recorder {
        let r = Recorder()
        r.pipeline.touchSurface = (surface.0, surface.1)
        r.pipeline.setTouchMode(mode, at: 0)
        r.pipeline.pointerEnabled = false   // no pointer lock: touch needs none
        return r
    }

    @Test func directTapClicksUnderTheFinger() {
        let r = recorder(.direct)
        r.pipeline.touchBegan(id: 1, x: 200, y: 300, at: 10 * ms)
        #expect(r.moves.last.map { [$0.x, $0.y] } == [200, 300])
        r.pipeline.touchEnded(id: 1, at: 50 * ms)
        #expect(r.buttons.map(\.isDown) == [true, false])
        #expect(r.buttons.allSatisfy { $0.button == .left && $0.x == 200 && $0.y == 300 && $0.clickCount == 1 })
    }

    @Test func directHoldDragsWithTheButtonInTheMoves() {
        let r = recorder(.direct)
        r.pipeline.touchBegan(id: 1, x: 200, y: 300, at: 0)
        r.pipeline.tick(at: 100 * ms)
        #expect(r.buttons.map(\.isDown) == [true])
        r.take()
        r.pipeline.touchMoved(id: 1, x: 400, y: 500, at: 200 * ms)
        #expect(r.moves.map { [$0.x, $0.y] } == [[400, 500]])
        #expect(r.moves[0].buttons == 1, "the left button is held")
        r.pipeline.touchEnded(id: 1, at: 300 * ms)
        #expect(r.buttons.last.map { [$0.x, $0.y] } == [400, 500] && r.buttons.last?.isDown == false)
    }

    @Test func directDoubleTapIsADoubleClick() {
        let r = recorder(.direct)
        r.pipeline.touchBegan(id: 1, x: 200, y: 300, at: 0)
        r.pipeline.touchEnded(id: 1, at: 40 * ms)
        r.pipeline.touchBegan(id: 2, x: 212, y: 293, at: 150 * ms)
        r.pipeline.touchEnded(id: 2, at: 190 * ms)
        #expect(r.buttons.map(\.clickCount) == [1, 1, 2, 2])
    }

    @Test func directMapsALetterboxedSurfaceOntoTheDisplay() {
        // A surface twice as wide as the display's shape: the stream is centred, with bars left and right.
        let r = recorder(.direct, surface: (2752, 1032))
        r.pipeline.touchBegan(id: 1, x: 688 + 100, y: 50, at: 0)
        #expect(r.moves.last.map { [$0.x, $0.y] } == [100, 50])
        r.pipeline.touchEnded(id: 1, at: 20 * ms)
        r.pipeline.touchBegan(id: 2, x: 10, y: 2000, at: 1000 * ms)
        #expect(r.moves.last.map { [$0.x, $0.y] } == [0, 1031], "in a bar or beyond: the nearest point of the display")
    }

    @Test func directTouchesTheStreamedDisplayOfALayout() {
        let r = recorder(.direct)
        r.pipeline.applyLayout(DisplayLayout(displays: [
            .init(displayID: 1, x: 0, y: 0, width: 1920, height: 1080, isStreamed: false),
            .init(displayID: 2, x: 1920, y: 0, width: 1376, height: 1032, isStreamed: true),
        ]))
        r.pipeline.touchBegan(id: 1, x: 100, y: 100, at: 0)
        #expect(r.moves.last.map { [$0.x, $0.y] } == [2020, 100])
    }

    @Test func trackpadMovesFromWhereThePointerIsAndTapsClickThere() {
        let r = recorder(.trackpad)
        let (x0, y0) = (r.pipeline.pointer.x, r.pipeline.pointer.y)
        r.pipeline.touchBegan(id: 1, x: 900, y: 900, at: 0)
        #expect(r.sent.isEmpty, "touching moves nothing")
        r.pipeline.touchMoved(id: 1, x: 940, y: 900, at: 500 * ms)
        r.pipeline.touchEnded(id: 1, at: 600 * ms)
        let x1 = r.pipeline.pointer.x
        #expect(x1 > x0 && r.pipeline.pointer.y == y0, "right, by the finger's travel through the speed curve")
        #expect(r.buttons.isEmpty)
        r.pipeline.touchBegan(id: 2, x: 50, y: 50, at: 2000 * ms)
        r.pipeline.touchEnded(id: 2, at: 2050 * ms)
        #expect(r.buttons.map(\.isDown) == [true, false] && r.buttons.allSatisfy { $0.x == x1 && $0.y == y0 })
    }

    @Test func twoFingersScrollWithoutAPointerLock() {
        let r = recorder(.direct)
        r.pipeline.touchBegan(id: 1, x: 200, y: 300, at: 0)
        r.pipeline.touchBegan(id: 2, x: 260, y: 300, at: 20 * ms)
        r.take()
        r.pipeline.touchMoved(id: 1, x: 200, y: 340, at: 40 * ms)
        r.pipeline.touchMoved(id: 2, x: 260, y: 340, at: 50 * ms)
        r.pipeline.touchEnded(id: 1, at: 400 * ms)
        #expect(r.buttons.isEmpty)
        #expect(r.scrolls.map(\.phase) == [.began, .changed, .ended])
        #expect(r.scrolls.map(\.dy) == [20, 20, 0])
    }

    @Test func theTrackpadStaysGatedByThePointerLock() {
        let r = recorder(.direct)
        r.pipeline.mouseMoved(dx: 10, dy: 0, at: 0)
        r.pipeline.mouseButton(.left, isDown: true, at: 10 * ms)
        #expect(r.sent.isEmpty)
    }

    @Test func releaseAllForgetsAHeldTouch() {
        let r = recorder(.direct)
        r.pipeline.touchBegan(id: 1, x: 200, y: 300, at: 0)
        r.pipeline.tick(at: 100 * ms)
        r.pipeline.releaseAll(.focusLost)
        r.take()
        r.pipeline.touchMoved(id: 1, x: 500, y: 500, at: 200 * ms)
        r.pipeline.touchEnded(id: 1, at: 300 * ms)
        #expect(r.sent.isEmpty, "the finger that was down sends nothing more")
    }

    @Test func offSendsNothing() {
        let r = recorder(.off)
        r.pipeline.touchBegan(id: 1, x: 200, y: 300, at: 0)
        r.pipeline.touchEnded(id: 1, at: 40 * ms)
        #expect(r.sent.isEmpty)
    }
}
