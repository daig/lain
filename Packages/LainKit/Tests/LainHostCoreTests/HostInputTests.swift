import CoreGraphics
import LainProtocol
import Testing
@testable import LainHostCore

@Suite struct PinchZoomMapperTests {
    @Test func zoomsInOnceEachFactorCrossed() {
        var m = PinchZoomMapper(threshold: 1.25)
        #expect(m.add(0.1) == 0)        // 1.10
        #expect(m.add(0.1) == 0)        // 1.20
        #expect(m.add(0.06) == 1)       // 1.26 ≥ 1.25
        #expect(m.anchor == 1.25)
        #expect(m.add(0.25) == 0)       // 1.51 < 1.5625
        #expect(m.add(0.06) == 1)       // 1.57 ≥ 1.5625
    }

    @Test func zoomsOutBelowTheInverseFactor() {
        var m = PinchZoomMapper(threshold: 1.25)
        #expect(m.add(-0.1) == 0)       // 0.90
        #expect(m.add(-0.11) == -1)     // 0.79 ≤ 0.8
        #expect(m.add(-0.14) == 0)      // 0.65 > 0.64
        #expect(m.add(-0.02) == -1)     // 0.63 ≤ 0.64
    }

    @Test func oneBigDeltaCanCrossSeveralFactors() {
        var m = PinchZoomMapper(threshold: 1.25)
        #expect(m.add(1.0) == 3)        // 2.0: 1.25, 1.5625, 1.953
        var n = PinchZoomMapper(threshold: 1.25)
        #expect(n.add(-0.5) == -3)      // 0.5: 0.8, 0.64, 0.512
    }

    @Test func reversingNeedsAFullFactorFromTheLastStep() {
        var m = PinchZoomMapper(threshold: 1.25)
        #expect(m.add(0.3) == 1)        // 1.30, anchor 1.25
        #expect(m.add(-0.25) == 0)      // 1.05 > 1.0
        #expect(m.add(-0.06) == -1)     // 0.99 ≤ 1.0
        #expect(m.anchor == 1.0)
    }

    @Test func resetStartsTheNextGestureFromOne() {
        var m = PinchZoomMapper(threshold: 1.25)
        _ = m.add(0.2)
        m.reset()
        #expect(m.scale == 1 && m.anchor == 1)
        #expect(m.add(0.2) == 0)        // would have fired without the reset (1.4)
    }

    @Test func ignoresNonFiniteDeltas() {
        var m = PinchZoomMapper()
        #expect(m.add(.nan) == 0 && m.add(.infinity) == 0)
        #expect(m.scale == 1)
    }
}

@Suite struct HostInputRouterTests {
    let sink = RecordingSink()

    func route(_ router: inout HostInputRouter, _ message: Message) -> HostInputRouter.Outcome {
        router.handle(message)
    }

    @Test func forwardsEveryInputMessage() {
        var r = HostInputRouter(sink: sink)
        let key = KeyEvent(usage: 0x04, isDown: true, modifiers: [.shift])
        let move = PointerMove(x: 10.5, y: 20.25, dx: 1.5, dy: -2, buttons: 0)
        let button = PointerButton(button: .left, isDown: true, clickCount: 2, x: 11, y: 21, modifiers: [.command])
        let scroll = Scroll(dx: 0, dy: -12.5, phase: .changed, momentumPhase: .none)
        #expect(r.handle(.keyEvent(key)) == .injected(pointer: nil))
        #expect(r.modifiers == [.shift])
        #expect(r.handle(.pointerMove(move)) == .injected(pointer: CGPoint(x: 10.5, y: 20.25)))
        #expect(r.handle(.pointerButton(button)) == .injected(pointer: CGPoint(x: 11, y: 21)))
        #expect(r.modifiers == [.command])
        #expect(r.handle(.scroll(scroll)) == .injected(pointer: nil))
        #expect(r.handle(.releaseAll(ReleaseAll(reason: .focusLost))) == .released)
        #expect(r.modifiers == [])
        #expect(sink.calls == [.key(key), .move(move), .button(button), .scroll(scroll), .releaseAll])
    }

    @Test func nonInputMessagesAreLeftToTheCaller() {
        var r = HostInputRouter(sink: sink)
        #expect(r.handle(.ping(Ping(id: 1, sentAtNs: 2))) == .notInput)
        #expect(r.handle(.start(Start())) == .notInput)
        #expect(r.handle(.keyframeRequest(KeyframeRequest(reason: .startup, lastGoodFrameId: 0))) == .notInput)
        #expect(sink.calls.isEmpty)
    }

    @Test func pinchOutPressesCommandEquals() {
        var r = HostInputRouter(sink: sink)
        #expect(r.handle(.gesture(Gesture(kind: .magnify, phase: .began, value: 0))) == .ignored)
        #expect(r.handle(.gesture(Gesture(kind: .magnify, phase: .changed, value: 0.2))) == .ignored)
        #expect(r.handle(.gesture(Gesture(kind: .magnify, phase: .changed, value: 0.1))) == .injected(pointer: nil))
        #expect(sink.calls == [
            .key(KeyEvent(usage: 0xE3, isDown: true, modifiers: [.command])),
            .key(KeyEvent(usage: 0x2E, isDown: true, modifiers: [.command])),
            .key(KeyEvent(usage: 0x2E, isDown: false, modifiers: [.command])),
            .key(KeyEvent(usage: 0xE3, isDown: false, modifiers: [])),
        ])
    }

    @Test func pinchInPressesCommandMinusAndRestoresHeldModifiers() {
        var r = HostInputRouter(sink: sink)
        _ = r.handle(.keyEvent(KeyEvent(usage: 0xE1, isDown: true, modifiers: [.shift])))
        sink.clear()
        _ = r.handle(.gesture(Gesture(kind: .magnify, phase: .changed, value: -0.25)))
        #expect(sink.calls == [
            .key(KeyEvent(usage: 0xE3, isDown: true, modifiers: [.shift, .command])),
            .key(KeyEvent(usage: 0x2D, isDown: true, modifiers: [.shift, .command])),
            .key(KeyEvent(usage: 0x2D, isDown: false, modifiers: [.shift, .command])),
            .key(KeyEvent(usage: 0xE3, isDown: false, modifiers: [.shift])),
        ])
    }

    @Test func pinchWithCommandAlreadyHeldDoesNotTouchCommand() {
        var r = HostInputRouter(sink: sink)
        _ = r.handle(.keyEvent(KeyEvent(usage: 0xE3, isDown: true, modifiers: [.command])))
        sink.clear()
        _ = r.handle(.gesture(Gesture(kind: .magnify, phase: .changed, value: 0.3)))
        #expect(sink.calls == [
            .key(KeyEvent(usage: 0x2E, isDown: true, modifiers: [.command])),
            .key(KeyEvent(usage: 0x2E, isDown: false, modifiers: [.command])),
        ])
    }

    @Test func pinchAccumulatorResetsAtGestureEnd() {
        var r = HostInputRouter(sink: sink)
        _ = r.handle(.gesture(Gesture(kind: .magnify, phase: .changed, value: 0.2)))
        _ = r.handle(.gesture(Gesture(kind: .magnify, phase: .ended, value: 0)))
        #expect(r.pinch.scale == 1)
        _ = r.handle(.gesture(Gesture(kind: .magnify, phase: .began, value: 0)))
        _ = r.handle(.gesture(Gesture(kind: .magnify, phase: .changed, value: 0.2)))
        #expect(sink.calls.isEmpty)   // two separate 1.2× pinches never add up to a step
        _ = r.handle(.gesture(Gesture(kind: .magnify, phase: .cancelled, value: 0)))
        #expect(r.pinch.scale == 1)
    }

    @Test func releaseAllResetsPinch() {
        var r = HostInputRouter(sink: sink)
        _ = r.handle(.gesture(Gesture(kind: .magnify, phase: .changed, value: 0.2)))
        _ = r.handle(.releaseAll(ReleaseAll(reason: .pointerLockLost)))
        #expect(r.pinch.scale == 1)
        #expect(sink.calls == [.releaseAll])
    }

    @Test func rotateIsIgnored() {
        var r = HostInputRouter(sink: sink)
        #expect(r.handle(.gesture(Gesture(kind: .rotate, phase: .changed, value: 1.5))) == .ignored)
        #expect(r.handle(.gesture(Gesture(kind: .rotate, phase: .changed, value: 1.5))) == .ignored)
        #expect(sink.calls.isEmpty)
    }
}

@Suite struct CursorWarpDetectorTests {
    let ms: UInt64 = 1_000_000

    @Test func firstQuietSampleReportsTheStartingPosition() {
        var d = CursorWarpDetector()
        #expect(d.sample(CGPoint(x: 5, y: 6), atNs: 1_000 * ms) == CGPoint(x: 5, y: 6))
        #expect(d.sample(CGPoint(x: 5, y: 6), atNs: 1_016 * ms) == nil)
    }

    @Test func noWarpWhileInputIsRecent() {
        var d = CursorWarpDetector()
        d.noteInput(pointer: CGPoint(x: 100, y: 100), atNs: 1_000 * ms)
        #expect(d.sample(CGPoint(x: 300, y: 300), atNs: 1_050 * ms) == nil)
        #expect(d.sample(CGPoint(x: 300, y: 300), atNs: 1_099 * ms) == nil)
        // A key press also counts as input.
        d.noteInput(pointer: nil, atNs: 1_090 * ms)
        #expect(d.sample(CGPoint(x: 300, y: 300), atNs: 1_150 * ms) == nil)
    }

    @Test func warpAfterQuietPeriodWhenMoved() {
        var d = CursorWarpDetector()
        d.noteInput(pointer: CGPoint(x: 100, y: 100), atNs: 1_000 * ms)
        #expect(d.sample(CGPoint(x: 100, y: 100), atNs: 1_100 * ms) == nil)
        #expect(d.sample(CGPoint(x: 140, y: 90), atNs: 1_200 * ms) == CGPoint(x: 140, y: 90))
        // Reported once; the reported position is now the expected one.
        #expect(d.sample(CGPoint(x: 140, y: 90), atNs: 1_216 * ms) == nil)
        #expect(d.expected == CGPoint(x: 140, y: 90))
    }

    @Test func noWarpForSubPointJitter() {
        var d = CursorWarpDetector()
        d.noteInput(pointer: CGPoint(x: 100, y: 100), atNs: 1_000 * ms)
        #expect(d.sample(CGPoint(x: 100.7, y: 99.4), atNs: 1_200 * ms) == nil)
        #expect(d.sample(CGPoint(x: 101, y: 100), atNs: 1_300 * ms) == nil)
        #expect(d.sample(CGPoint(x: 101.1, y: 100), atNs: 1_400 * ms) == CGPoint(x: 101.1, y: 100))
    }

    @Test func resetForgetsTheSession() {
        var d = CursorWarpDetector()
        d.noteInput(pointer: CGPoint(x: 1, y: 1), atNs: 1_000 * ms)
        d.reset()
        #expect(d.expected == nil && d.lastInputNs == nil)
        #expect(d.sample(CGPoint(x: 1, y: 1), atNs: 1_001 * ms) == CGPoint(x: 1, y: 1))
    }
}

@Suite struct HelloAckTests {
    @Test func builtFromDisplayAndSettings() {
        let ack = HelloAck.host(
            display: HostDisplay(displayID: 1, origin: CGPoint(x: -1512, y: 0), pointSize: CGSize(width: 1512, height: 982)),
            settings: HostInputSettings(doubleClickIntervalMs: 500, keyRepeatDelayMs: 225, keyRepeatIntervalMs: 30,
                                        inputSourceID: "com.apple.keylayout.Colemak"))
        #expect(ack.codec == .hevc && ack.chroma == .yuv444 && ack.bitDepth == 10)
        #expect(ack.displayMode == .extend && ack.bitrate == 60_000_000 && ack.refreshRate == 120)
        #expect(ack.displayPointWidth == 1512 && ack.displayPointHeight == 982)
        #expect(ack.audioSampleRate == 48_000 && ack.audioChannels == 2 && ack.audioEncoding == .pcm16LE)
        #expect(ack.doubleClickIntervalMs == 500 && ack.keyRepeatDelayMs == 225 && ack.keyRepeatIntervalMs == 30)
        #expect(ack.macInputSource == "com.apple.keylayout.Colemak")
    }
}
