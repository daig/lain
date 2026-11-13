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

    // MARK: Pinch to zoom

    /// Two fingers pinching apart on the picture, `to` times as far from each other, about (`x`, `y`).
    private func pinch(_ r: Recorder, x: Double, y: Double, to factor: Double) {
        r.pipeline.touchBegan(id: 1, x: x - 40, y: y, at: 0)
        r.pipeline.touchBegan(id: 2, x: x + 40, y: y, at: 10 * ms)
        r.pipeline.touchMoved(id: 1, x: x - 40 * factor, y: y, at: 30 * ms)
        r.pipeline.touchMoved(id: 2, x: x + 40 * factor, y: y, at: 40 * ms)
        r.pipeline.touchEnded(id: 1, at: 60 * ms)
        r.pipeline.touchEnded(id: 2, at: 70 * ms)
    }

    /// The Duo closed: a 382 × 269 view of the 1376 × 1032 display.
    @Test func aPinchZoomsAboutTheFingersAndSendsTheHostNoScroll() {
        let r = recorder(.direct, surface: (382, 287))
        #expect(r.pipeline.viewport == .full && r.pipeline.zoom == 1)
        // What is under the fingers' midpoint before...
        let before = r.pipeline.hostPoint(surfaceX: 100, surfaceY: 80)!
        pinch(r, x: 100, y: 80, to: 2)
        #expect(abs(r.pipeline.zoom - 2) < 1e-9)
        let v = r.pipeline.viewport
        #expect(abs(v.width - 0.5) < 1e-9 && abs(v.height - 0.5) < 0.01)
        // ...is still under it after.
        let after = r.pipeline.hostPoint(surfaceX: 100, surfaceY: 80)!
        #expect(abs(after.x - before.x) < 1e-6 && abs(after.y - before.y) < 1e-6)
        #expect(r.scrolls.isEmpty && r.buttons.isEmpty, "a pinch is the view's own: no scroll, no right-click")
        // Pinching back out past the whole display stops at it.
        pinch(r, x: 200, y: 100, to: 0.2)
        #expect(r.pipeline.zoom == 1 && r.pipeline.viewport == .full)
    }

    @Test func zoomStopsWhereADisplayPointIsTwoOfTheViews() {
        let r = recorder(.direct, surface: (382, 287))   // fits at 382 / 1376
        pinch(r, x: 191, y: 140, to: 4)
        pinch(r, x: 191, y: 140, to: 4)
        #expect(abs(r.pipeline.zoom - ClientInputPipeline.maxViewScale / (382.0 / 1376)) < 1e-9)
        #expect(abs(r.pipeline.viewport.width * 1376 - 191) < 1e-6)
    }

    @Test func twoFingersMovingTogetherStillScroll() {
        let r = recorder(.direct, surface: (382, 287))
        r.pipeline.touchBegan(id: 1, x: 100, y: 100, at: 0)
        r.pipeline.touchBegan(id: 2, x: 180, y: 100, at: 10 * ms)
        r.pipeline.touchMoved(id: 1, x: 100, y: 140, at: 30 * ms)
        r.pipeline.touchMoved(id: 2, x: 180, y: 140, at: 40 * ms)
        #expect(!r.scrolls.isEmpty && r.pipeline.zoom == 1)
    }

    @Test func zoomedInTheViewFollowsAPointerThatMovesAndStopsAtTheEdges() {
        let r = recorder(.direct, surface: (382, 287))
        pinch(r, x: 191, y: 143, to: 2)
        let before = r.pipeline.viewport
        // The pointer far to the right: the part follows, keeping it a margin inside its edge.
        r.pipeline.warp(x: 1200, y: 516)
        r.pipeline.updateViewport()
        let v = r.pipeline.viewport
        let margin = v.width * 1376 * ClientInputPipeline.viewportMargin
        #expect(v != before && abs((v.x + v.width) * 1376 - margin - 1200) < 1e-6)
        // The corner: it stops at the display's edge.
        r.pipeline.warp(x: 1375, y: 1031)
        r.pipeline.updateViewport()
        #expect(abs(r.pipeline.viewport.x + r.pipeline.viewport.width - 1) < 1e-9)
        // A pinch elsewhere moves the view without the pointer pulling it back.
        pinch(r, x: 60, y: 60, to: 0.5)
        let pinched = r.pipeline.viewport
        r.pipeline.updateViewport()
        #expect(r.pipeline.viewport == pinched)
    }

    @Test func aPortraitWindowStartsFilledWithTheDisplaysHeight() {
        // Half of the Duo's inner display: a 469 × 522 view of the 1376 × 1032 display.
        let r = recorder(.direct, surface: (469, 522))
        r.pipeline.fillsView = true
        var v = r.pipeline.viewport
        #expect(abs(v.height - 1) < 1e-9, "the display's whole height")
        #expect(abs(v.width * 1376 - 469 / (522.0 / 1032)) < 1e-6, "and as much of its width as fits")
        // Around the pointer, which is in the display's middle.
        #expect(v.x * 1376 < 688 && 688 < (v.x + v.width) * 1376)
        // A pinch out shows all of it; turning the fill off and on starts again.
        pinch(r, x: 234, y: 260, to: 0.2)
        #expect(r.pipeline.viewport == .full)
        r.pipeline.fillsView = false
        r.pipeline.fillsView = true
        v = r.pipeline.viewport
        #expect(abs(v.height - 1) < 1e-9 && v.width < 1)
        r.pipeline.fillsView = false
        #expect(r.pipeline.viewport == .full)
    }

    /// The deck (the Duo folded like a laptop): a pinch on the trackpad zooms the picture above it, about the
    /// pointer, which stays where it shows; off the deck, a pinch on the strip zooms nothing.
    @Test func aPinchOnTheDecksTrackpadZoomsThePictureAboutThePointer() {
        let r = recorder(.direct, surface: (669, 455))
        func padPinch(to factor: Double) {
            r.pipeline.padTouchBegan(id: 1, x: 200, y: 150, at: 0)
            r.pipeline.padTouchBegan(id: 2, x: 280, y: 150, at: 10 * ms)
            r.pipeline.padTouchMoved(id: 1, x: 240 - 40 * factor, y: 150, at: 30 * ms)
            r.pipeline.padTouchMoved(id: 2, x: 240 + 40 * factor, y: 150, at: 40 * ms)
            r.pipeline.padTouchEnded(id: 1, at: 60 * ms)
            r.pipeline.padTouchEnded(id: 2, at: 70 * ms)
        }
        r.pipeline.warp(x: 1000, y: 300)
        r.pipeline.updateViewport()
        padPinch(to: 2)
        #expect(r.pipeline.zoom == 1, "the strip's pinch zooms only on the deck")
        r.pipeline.padPinchZooms = true
        let fit = min(669 / 1376.0, 455 / 1032.0)
        let x = 1000 * fit + (669 - 1376 * fit) / 2, y = 300 * fit + (455 - 1032 * fit) / 2
        let scrolls = r.scrolls.count
        padPinch(to: 2)
        #expect(abs(r.pipeline.zoom - 2) < 1e-9)
        let under = r.pipeline.hostPoint(surfaceX: x, surfaceY: y)!
        #expect(abs(under.x - 1000) < 1e-6 && abs(under.y - 300) < 1e-6, "the pointer stays where it shows")
        #expect(r.scrolls.count == scrolls && r.buttons.isEmpty)
    }

    @Test func theScrollRibbonScrollsWithoutAPointerLock() {
        let r = recorder(.direct)
        r.pipeline.glassScroll(.scrollBegan, at: 0)
        r.pipeline.glassScroll(.scroll(dx: 0, dy: 12), at: 10 * ms)
        r.pipeline.glassScroll(.button(.left, isDown: true), at: 15 * ms)   // not a scroll: ignored
        r.pipeline.glassScroll(.scrollEnded, at: 20 * ms)
        #expect(!r.scrolls.isEmpty && r.buttons.isEmpty)
    }
}
