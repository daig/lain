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

    // MARK: Text (the on-screen keyboard, dictation)

    @Test func typedTextGoesOutAsTextWithItsModifiers() {
        let r = Recorder()
        r.pipeline.typeText("héllo {x}\n")
        r.pipeline.typeText("c", modifiers: [.control])
        r.pipeline.typeText("")
        let texts = r.sent.compactMap { if case .textInput(let t) = $0 { t } else { nil } }
        #expect(texts == [TextInput(text: "héllo {x}\n"), TextInput(text: "c", modifiers: [.control])])
        r.take()
        r.pipeline.typeText(String(repeating: "a", count: 2_300))
        #expect(r.sent.count == 3, "long text is split")
    }

    @Test func thePanelOpensWithoutAKeyboardAndTakesTheInput() {
        let r = Recorder()
        var shortcuts: [ClientInputPipeline.LocalShortcut] = []
        r.pipeline.onLocalShortcut = { shortcuts.append($0) }
        r.pipeline.openPanel(at: 0)
        #expect(shortcuts == [.overlay(true)] && r.pipeline.overlayShown)
        r.pipeline.typeText("x")
        r.pipeline.touchBegan(id: 1, x: 10, y: 10, at: 10 * ms)
        #expect(r.sent.isEmpty, "nothing reaches the host while the panel is open")
        r.pipeline.closePanel()
        #expect(shortcuts == [.overlay(true), .overlay(false)])
    }

    // MARK: The trackpad strip

    @Test func theStripIsATrackpadWhateverTheScreensMode() {
        let r = recorder(.direct)
        let (x0, y0) = (r.pipeline.pointer.x, r.pipeline.pointer.y)
        r.pipeline.padTouchBegan(id: 1, x: 20, y: 20, at: 0)
        #expect(r.sent.isEmpty, "touching the strip moves nothing")
        r.pipeline.padTouchMoved(id: 1, x: 60, y: 20, at: 100 * ms)
        r.pipeline.padTouchEnded(id: 1, at: 200 * ms)
        let x1 = r.pipeline.pointer.x
        #expect(x1 > x0 && r.pipeline.pointer.y == y0 && r.buttons.isEmpty)
        r.pipeline.padTouchBegan(id: 2, x: 5, y: 5, at: 1000 * ms)
        r.pipeline.padTouchEnded(id: 2, at: 1050 * ms)
        #expect(r.buttons.map(\.isDown) == [true, false] && r.buttons.allSatisfy { $0.x == x1 }, "a tap clicks where the pointer is")
        // The screen is still direct at the same time.
        r.take()
        r.pipeline.touchBegan(id: 9, x: 200, y: 300, at: 5000 * ms)
        #expect(r.moves.last.map { [$0.x, $0.y] } == [200, 300])
    }

    @Test func theStripHoldsToDragAndReleaseAllForgetsIt() {
        let r = recorder(.off)
        r.pipeline.padTouchBegan(id: 1, x: 20, y: 20, at: 0)
        r.pipeline.tick(at: 450 * ms)
        #expect(r.buttons.map(\.isDown) == [true], "works with the screen's touch off")
        r.pipeline.releaseAll(.focusLost)
        r.take()
        r.pipeline.padTouchMoved(id: 1, x: 90, y: 20, at: 500 * ms)
        r.pipeline.padTouchEnded(id: 1, at: 600 * ms)
        #expect(r.sent.isEmpty)
    }

    // MARK: Speeds: fixed per control, following the resolution

    /// Slow, even moves (no acceleration): the pointer's travel per unit of the hand's. Each call uses later
    /// times and its own finger.
    private func travel(_ r: Recorder, pad: Bool, from start: UInt64 = 0) -> Double {
        let t0 = start * 1000 * ms
        if pad {
            r.pipeline.padTouchBegan(id: Int(start) + 1, x: 0, y: 0, at: t0)
            r.pipeline.padTouchMoved(id: Int(start) + 1, x: 11, y: 0, at: t0 + 100 * ms)   // past the tap's slop
            let x0 = r.pipeline.pointer.x
            for i in 1...20 { r.pipeline.padTouchMoved(id: Int(start) + 1, x: 11 + Double(i), y: 0, at: t0 + 100 * ms + UInt64(i) * 8 * ms) }
            r.pipeline.padTouchEnded(id: Int(start) + 1, at: t0 + 500 * ms)
            return (r.pipeline.pointer.x - x0) / 20
        }
        let x0 = r.pipeline.pointer.x
        for i in 1...20 { r.pipeline.mouseMoved(dx: 1, dy: 0, at: t0 + UInt64(i) * 8 * ms) }
        return (r.pipeline.pointer.x - x0) / 20
    }

    @Test func theTrackpadAreasAreTwiceAsFastAsTheMagicKeyboards() {
        let r = Recorder()
        r.pipeline.curve = ClientInputPipeline.trackpadCurve
        #expect(abs(travel(r, pad: false) - 0.6) < 1e-9)
        #expect(abs(travel(r, pad: true, from: 1) - 1.2) < 1e-9)
    }

    @Test func speedsFollowTheResolution() {
        let r = Recorder()   // a 1376-point display
        r.pipeline.curve = ClientInputPipeline.trackpadCurve
        r.pipeline.referenceWidth = 1376
        #expect(r.pipeline.resolutionScale == 1)
        r.pipeline.applyLayout(DisplayLayout(displays: [.init(displayID: 1, x: 0, y: 0, width: 2752, height: 2064, isStreamed: true)]))
        #expect(r.pipeline.resolutionScale == 2, "twice the points across the same glass")
        #expect(abs(travel(r, pad: false) - 1.2) < 1e-9 && abs(travel(r, pad: true, from: 1) - 2.4) < 1e-9)
        r.take()
        r.pipeline.scrollBegan(at: 5000 * ms)
        r.pipeline.scrollChanged(dx: 0, dy: 10, at: 5010 * ms)
        #expect(r.scrolls.last?.dy == 20)
        r.pipeline.referenceWidth = 0
        #expect(r.pipeline.resolutionScale == 1, "no reference: as tuned")
    }
}
