import LainClientCore
import LainInput
import LainProtocol
import Testing

let ack = HelloAck(codec: .hevc, chroma: .yuv444, bitDepth: 10, displayMode: .extend, bitrate: 60_000_000,
                   refreshRate: 120, displayPointWidth: 1376, displayPointHeight: 1032,
                   audioSampleRate: 48_000, audioChannels: 2, audioEncoding: .pcm16LE,
                   doubleClickIntervalMs: 400, keyRepeatDelayMs: 250, keyRepeatIntervalMs: 40,
                   macInputSource: "com.apple.keylayout.Colemak")

/// A pipeline configured from `ack`, recording everything it sends.
final class Recorder {
    var sent: [Message] = []
    let pipeline: ClientInputPipeline

    init(configure: Bool = true) {
        let pipeline = ClientInputPipeline()
        self.pipeline = pipeline
        pipeline.send = { [unowned self] in self.sent.append($0) }
        if configure { pipeline.configure(ack) }
    }

    @discardableResult
    func take() -> [Message] { defer { sent.removeAll() }; return sent }
    var keys: [KeyEvent] { sent.compactMap { if case .keyEvent(let e) = $0 { e } else { nil } } }
    var moves: [PointerMove] { sent.compactMap { if case .pointerMove(let m) = $0 { m } else { nil } } }
    var buttons: [PointerButton] { sent.compactMap { if case .pointerButton(let b) = $0 { b } else { nil } } }
    var scrolls: [Scroll] { sent.compactMap { if case .scroll(let s) = $0 { s } else { nil } } }
}

let ms: UInt64 = 1_000_000

@Suite struct ClientInputPipelineTests {
    @Test func helloAckConfiguresBoundsRepeatAndDoubleClick() {
        let r = Recorder(configure: false)
        let p = r.pipeline
        #expect(!p.isConfigured)
        p.configure(ack)
        #expect(p.isConfigured)
        #expect(p.pointer.width == 1376 && p.pointer.height == 1032)
        #expect(p.pointer.x == 688 && p.pointer.y == 516)   // recentred
        #expect(p.keyRepeat.delayNs == 250 * ms && p.keyRepeat.intervalNs == 40 * ms)
        #expect(p.clicks.intervalNs == 400 * ms)
        #expect(p.macInputSource == "com.apple.keylayout.Colemak")
    }

    @Test func optTabBecomesCmdTabWithHoldSemantics() {
        let r = Recorder()
        let p = r.pipeline
        p.keyChanged(.leftOption, isDown: true, at: 0)
        p.keyChanged(.tab, isDown: true, at: 1 * ms)
        p.keyChanged(.tab, isDown: false, at: 2 * ms)
        p.keyChanged(.tab, isDown: true, at: 3 * ms)    // cycles again with Cmd still held
        p.keyChanged(.tab, isDown: false, at: 4 * ms)
        p.keyChanged(.leftOption, isDown: false, at: 5 * ms)
        #expect(r.keys.map(\.usage) == [0xE2, 0xE2, 0xE3, 0x2B, 0x2B, 0x2B, 0x2B, 0xE3])
        #expect(r.keys.map(\.isDown) == [true, false, true, true, false, true, false, false])
        #expect(r.keys[3].modifiers == .command)
        #expect(r.keys.allSatisfy { !$0.isRepeat })
    }

    @Test func remapsMatchTheLearnedLayoutCharacter() {
        // Whatever physical key the iPad layout says types "h", Opt-that-key is Cmd-H on the Mac.
        let r = Recorder()
        let p = r.pipeline
        p.learnCharacter(.key(0x0E), "H")
        p.keyChanged(.leftOption, isDown: true, at: 0)
        p.keyChanged(.key(0x0E), isDown: true, at: 1 * ms)
        #expect(r.keys.last?.usage == 0x0E)
        #expect(r.keys.last?.modifiers == .command)
    }

    @Test func keyRepeatStartsAfterTheDelayOnTick() {
        let r = Recorder()
        let p = r.pipeline
        p.keyChanged(.key(0x04), isDown: true, at: 1000 * ms)
        r.take()
        p.tick(at: 1100 * ms)
        #expect(r.sent.isEmpty)
        p.tick(at: 1250 * ms)
        p.tick(at: 1260 * ms)   // the next one is due at 1290
        p.tick(at: 1290 * ms)
        #expect(r.keys.count == 2)
        #expect(r.keys.allSatisfy { $0.isRepeat && $0.isDown && $0.usage == 0x04 })
        p.keyChanged(.key(0x04), isDown: false, at: 1300 * ms)
        r.take()
        p.tick(at: 2000 * ms)
        #expect(r.sent.isEmpty)
    }

    @Test func pointerMovesClampAndCarryButtonsWhileDragging() throws {
        let r = Recorder()
        let p = r.pipeline
        p.mouseButton(.left, isDown: true, at: 0)
        p.mouseMoved(dx: 100_000, dy: -100_000, at: 8 * ms)   // far right and (y up-positive in) far down
        let m = try #require(r.moves.last)
        #expect(m.buttons == 1)
        #expect(m.x == 1375 && m.y == 1031)
        p.mouseButton(.left, isDown: false, at: 20 * ms)
        p.mouseMoved(dx: -1, dy: 0, at: 28 * ms)
        #expect(r.moves.last?.buttons == 0)
        #expect(r.buttons.map(\.isDown) == [true, false])
        #expect(r.buttons.last?.x == 1375)
    }

    @Test func zeroDeltasAreIgnored() {
        let r = Recorder()
        r.pipeline.mouseMoved(dx: 0, dy: 0, at: 0)
        #expect(r.sent.isEmpty)
    }

    @Test func clicksGetCountsAndModifiers() {
        let r = Recorder()
        let p = r.pipeline
        p.keyChanged(.leftControl, isDown: true, at: 0)
        for i in 0..<3 {
            let t = UInt64(i) * 150 * ms
            p.mouseButton(.left, isDown: true, at: t)
            p.mouseButton(.left, isDown: false, at: t + 50 * ms)
        }
        #expect(r.buttons.map(\.clickCount) == [1, 1, 2, 2, 3, 3])
        #expect(r.buttons.allSatisfy { $0.modifiers == .control })
        // Past the Mac's 400 ms interval the sequence restarts.
        p.mouseButton(.left, isDown: true, at: 2000 * ms)
        #expect(r.buttons.last?.clickCount == 1)
        // A duplicate down and an orphan up are dropped.
        let before = r.buttons.count
        p.mouseButton(.left, isDown: true, at: 2001 * ms)
        p.mouseButton(.right, isDown: false, at: 2002 * ms)
        #expect(r.buttons.count == before)
    }

    @Test func scrollPassesThroughThenMomentumRunsOnTicks() throws {
        let r = Recorder()
        let p = r.pipeline
        p.scrollBegan(at: 0)
        var t: UInt64 = 0
        for _ in 0..<10 {
            t += 8_333_333
            p.scrollChanged(dx: 0, dy: -12, at: t)
        }
        p.scrollEnded(at: t + 1 * ms)
        let phases = r.scrolls.map(\.phase)
        #expect(phases.first == .began)
        #expect(phases.dropFirst().dropLast().allSatisfy { $0 == .changed })
        #expect(phases.last == .ended)
        #expect(r.scrolls.first?.dy == -12)   // direction passes through unchanged
        #expect(r.scrolls.allSatisfy { $0.momentumPhase == .none })
        r.take()
        for _ in 0..<600 {
            t += 8_333_333
            p.tick(at: t)
        }
        let momentum = r.scrolls.map(\.momentumPhase)
        #expect(momentum.count > 10)
        #expect(momentum.first == .began)
        #expect(momentum.last == .ended)
        #expect(momentum.dropFirst().dropLast().allSatisfy { $0 == .changed })
        #expect(try #require(r.scrolls.first).dy < 0)
        #expect(!p.momentum.isActive)
    }

    @Test func invertScrollNegatesDeltas() {
        let r = Recorder()
        r.pipeline.invertScroll = true
        r.pipeline.scrollBegan(at: 0)
        r.pipeline.scrollChanged(dx: 3, dy: -4, at: 8 * ms)
        #expect(r.scrolls.first?.dx == -3 && r.scrolls.first?.dy == 4)
    }

    @Test func newTouchCancelsMomentum() {
        let r = Recorder()
        let p = r.pipeline
        p.scrollBegan(at: 0)
        var t: UInt64 = 0
        for _ in 0..<6 { t += 8 * ms; p.scrollChanged(dx: 20, dy: 0, at: t) }
        p.scrollEnded(at: t)
        t += 8 * ms
        p.tick(at: t)
        #expect(p.momentum.isActive)
        r.take()
        p.scrollBegan(at: t + 1 * ms)
        #expect(r.scrolls.map(\.momentumPhase) == [.ended])
        #expect(!p.momentum.isActive)
    }

    @Test func gesturesAreForwarded() {
        let r = Recorder()
        r.pipeline.gesture(.magnify, phase: .began, value: 0.05, at: 0)
        r.pipeline.gesture(.rotate, phase: .changed, value: -0.1, at: 1)
        #expect(r.sent == [.gesture(Gesture(kind: .magnify, phase: .began, value: 0.05)),
                           .gesture(Gesture(kind: .rotate, phase: .changed, value: -0.1))])
    }

    @Test func pointerInputIsPausedWhileUnlocked() {
        let r = Recorder()
        let p = r.pipeline
        p.pointerEnabled = false
        p.mouseMoved(dx: 5, dy: 5, at: 0)
        p.mouseButton(.left, isDown: true, at: 1)
        p.scrollBegan(at: 2)
        p.scrollChanged(dx: 1, dy: 1, at: 3)
        p.gesture(.magnify, phase: .began, value: 0.1, at: 4)
        #expect(r.sent.isEmpty)
        p.keyChanged(.key(0x04), isDown: true, at: 5)   // the keyboard still flows (D19)
        #expect(r.keys.count == 1)
    }

    @Test func releaseAllSendsReleaseAllAndForgetsHeldState() {
        let r = Recorder()
        let p = r.pipeline
        p.keyChanged(.leftCommand, isDown: true, at: 0)
        p.keyChanged(.key(0x04), isDown: true, at: 1 * ms)
        p.mouseButton(.left, isDown: true, at: 2 * ms)
        p.scrollBegan(at: 3 * ms)
        p.scrollChanged(dx: 0, dy: 5, at: 4 * ms)
        r.take()
        p.releaseAll(.focusLost)
        #expect(r.sent == [.scroll(Scroll(dx: 0, dy: 0, phase: .cancelled, momentumPhase: .none)),
                           .releaseAll(ReleaseAll(reason: .focusLost))])
        #expect(p.keyboard.macHeldKeys.isEmpty)
        #expect(p.heldButtons.mask == 0 && !p.keyRepeat.isRepeating && !p.isScrolling)
        r.take()
        // Orphan ups after returning from the background send nothing, and nothing repeats.
        p.keyChanged(.key(0x04), isDown: false, at: 10 * ms)
        p.keyChanged(.leftCommand, isDown: false, at: 11 * ms)
        p.mouseButton(.left, isDown: false, at: 12 * ms)
        p.scrollEnded(at: 13 * ms)
        p.tick(at: 1000 * ms)
        #expect(r.sent.isEmpty)
    }

    @Test func releaseAllStopsMomentumOnTheMac() {
        let r = Recorder()
        let p = r.pipeline
        p.scrollBegan(at: 0)
        var t: UInt64 = 0
        for _ in 0..<6 { t += 8 * ms; p.scrollChanged(dx: 0, dy: 30, at: t) }
        p.scrollEnded(at: t)
        p.tick(at: t + 8 * ms)
        r.take()
        p.releaseAll(.pointerLockLost)
        #expect(r.sent == [.scroll(Scroll(dx: 0, dy: 0, phase: .none, momentumPhase: .ended)),
                           .releaseAll(ReleaseAll(reason: .pointerLockLost))])
        r.take()
        p.tick(at: t + 100 * ms)
        #expect(r.sent.isEmpty)
    }

    @Test func localReleaseSendsNothing() {
        let r = Recorder()
        r.pipeline.keyChanged(.key(0x04), isDown: true, at: 0)
        r.take()
        r.pipeline.releaseAll(.disconnect, notify: false)
        #expect(r.sent.isEmpty)
        #expect(r.pipeline.keyboard.macHeldKeys.isEmpty)
    }

    @Test func keyboardDisconnectLiftsHeldKeysAndStopsRepeat() {
        let r = Recorder()
        let p = r.pipeline
        p.keyChanged(.leftShift, isDown: true, at: 0)
        p.keyChanged(.key(0x2A), isDown: true, at: 1 * ms)   // Delete, held
        p.tick(at: 400 * ms)
        #expect(p.keyRepeat.isRepeating)
        r.take()
        p.keyboardDisconnected()   // no key-ups will come from a detached keyboard
        #expect(r.keys.map(\.usage) == [0x2A, 0xE1] && r.keys.allSatisfy { !$0.isDown })
        #expect(p.keyboard.macHeldKeys.isEmpty && !p.keyRepeat.isRepeating)
        r.take()
        p.tick(at: 2000 * ms)
        #expect(r.sent.isEmpty)   // no more repeats
    }

    @Test func mouseDisconnectLiftsHeldButtons() {
        let r = Recorder()
        let p = r.pipeline
        p.mouseButton(.left, isDown: true, at: 0)
        r.take()
        p.mouseDisconnected()
        #expect(r.buttons.map(\.button) == [.left] && r.buttons.allSatisfy { !$0.isDown })
        #expect(p.heldButtons.mask == 0)
        r.take()
        p.mouseMoved(dx: 3, dy: 0, at: 10 * ms)
        #expect(r.moves.first?.buttons == 0)   // later moves are not drags
        p.mouseDisconnected()   // nothing held: nothing sent
        #expect(r.buttons.isEmpty)
    }

    @Test func wheelNotchesHaveNoPhaseAndNoMomentum() {
        let r = Recorder()
        let p = r.pipeline
        p.scrollWheel(dx: 0, dy: 10, at: 0)
        p.tick(at: 8 * ms)
        p.tick(at: 16 * ms)
        #expect(r.scrolls == [Scroll(dx: 0, dy: 10, phase: .none, momentumPhase: .none)])
        #expect(!p.momentum.isActive)
        r.take()
        p.pointerEnabled = false
        p.scrollWheel(dx: 0, dy: 10, at: 20 * ms)
        #expect(r.sent.isEmpty)
    }

    @Test func warpMovesTheTracker() {
        let r = Recorder()
        let p = r.pipeline
        p.warp(x: 10, y: 20)
        #expect(p.pointer.x == 10 && p.pointer.y == 20)
        p.warp(x: -5, y: 5000)
        #expect(p.pointer.x == 0 && p.pointer.y == 1031)
        #expect(r.sent.isEmpty)
        p.mouseMoved(dx: 1, dy: 0, at: 0)
        #expect(r.moves.last.map { $0.x > 0 && $0.y == 1031 } == true)
    }
}

@Suite struct ClientInputQueueTests {
    @Test func callsRunInOrderAndPublishTheCursor() {
        let input = ClientInput()
        let box = SentBox()
        input.connect { box.append($0) }
        input.configure(ack)
        input.mouseMoved(dx: 10, dy: 0)
        input.warp(x: 100, y: 200)
        input.keyChanged(.key(0x04), isDown: true)
        input.releaseAll(.pointerLockLost)
        input.sync { _ in }
        #expect(input.cursor == CursorSnapshot(x: 100, y: 200, displayPointWidth: 1376, displayPointHeight: 1032))
        let sent = box.messages
        #expect(sent.count == 3)
        if case .pointerMove = sent.first {} else { Issue.record("expected a move first, got \(sent)") }
        #expect(sent.last == .releaseAll(ReleaseAll(reason: .pointerLockLost)))
        // After a disconnect nothing goes out.
        input.disconnect()
        input.keyChanged(.key(0x05), isDown: true)
        input.sync { _ in }
        #expect(box.messages.count == 3)
    }

    @Test func snapshotTracksTheStreamedDisplay() {
        let input = ClientInput()
        input.configure(ack)
        input.sync { _ in }
        // No layout yet: the HelloAck display at (0, 0) is streamed (M2 fallback).
        #expect(input.cursor == CursorSnapshot(x: 688, y: 516, displayPointWidth: 1376, displayPointHeight: 1032,
                                               globalX: 688, globalY: 516, onStream: true))
        input.applyLayout(DesktopLayoutTests.layout)
        input.warp(x: -100, y: 500)
        input.sync { _ in }
        #expect(input.cursor == CursorSnapshot(x: -100, y: 500 - 1050, displayPointWidth: 1376, displayPointHeight: 1032,
                                               globalX: -100, globalY: 500, onStream: false))
        input.warp(x: 10, y: 1060)
        input.sync { _ in }
        #expect(input.cursor.onStream && input.cursor.x == 10 && input.cursor.y == 10)
        // A layout with nothing streamed: never on stream.
        input.applyLayout(DisplayLayout(displays: DesktopLayoutTests.layout.displays.map {
            var d = $0; d.isStreamed = false; return d
        }))
        input.sync { _ in }
        #expect(!input.cursor.onStream && input.cursor.displayPointWidth == 0 && input.cursor.globalY == 1060)
    }

    @Test func callsFromTheInputQueueRunInline() {
        let input = ClientInput()
        let box = SentBox()
        input.connect { box.append($0) }
        input.queue.sync {
            input.keyChanged(.key(0x04), isDown: true)
            // Ran inline: already sent before this block returns.
            #expect(box.messages.count == 1)
        }
    }
}

/// `DisplayLayout` on the pipeline: the cursor roams the Mac's desktop in global points.
@Suite struct DesktopLayoutTests {
    /// Main at (0, 0), the streamed iPad display below it, a side monitor to the left.
    static let layout = DisplayLayout(displays: [
        .init(displayID: 1, x: 0, y: 0, width: 1680, height: 1050, isStreamed: false),
        .init(displayID: 9, x: 0, y: 1050, width: 1376, height: 1032, isStreamed: true),
        .init(displayID: 4, x: -1920, y: 0, width: 1920, height: 1080, isStreamed: false),
    ])

    func pipeline() -> Recorder {
        let r = Recorder()
        r.pipeline.curve = AccelerationCurve(sensitivity: 1, acceleration: 0)
        return r
    }

    @Test func withoutALayoutTheHelloAckDisplayIsTheDesktop() {
        let p = pipeline().pipeline
        #expect(!p.hasLayout)
        #expect(p.pointer.displays == [DesktopDisplay(x: 0, y: 0, width: 1376, height: 1032)])
        #expect(p.streamedDisplay == DesktopDisplay(x: 0, y: 0, width: 1376, height: 1032))
        #expect(p.cursorOnStream)
    }

    @Test func firstLayoutRecentresOnTheStreamedDisplayAndMovesAreGlobal() {
        let r = pipeline()
        let p = r.pipeline
        p.applyLayout(Self.layout)
        #expect(p.hasLayout && p.pointer.displays.count == 3)
        #expect(p.streamedDisplay == DesktopDisplay(x: 0, y: 1050, width: 1376, height: 1032))
        #expect(p.pointer.x == 688 && p.pointer.y == 1050 + 516 && p.cursorOnStream)
        // Up 600 pt crosses onto main; the move carries global coordinates.
        p.mouseMoved(dx: 0, dy: 600, at: 0)
        #expect(r.moves.last == PointerMove(x: 688, y: 1566 - 600, dx: 0, dy: -600, buttons: 0))
        #expect(!p.cursorOnStream && p.pointer.displayIndex == 0)
        // Left 1000 pt onto the side monitor; clicks there are global too.
        p.mouseMoved(dx: -1000, dy: 0, at: 8 * ms)
        p.mouseButton(.left, isDown: true, at: 10 * ms)
        #expect(r.buttons.last.map { $0.x == -312 && $0.y == 966 } == true)
        #expect(p.pointer.displayIndex == 2)
    }

    @Test func laterLayoutsKeepOrSnapThePosition() {
        let p = pipeline().pipeline
        p.applyLayout(Self.layout)
        p.warp(x: -500, y: 200)
        // The iPad display moves to the right of main (the owner rearranged): the cursor stays put.
        var moved = Self.layout
        moved.displays[1].x = 1680
        moved.displays[1].y = 0
        p.applyLayout(moved)
        #expect(p.pointer.x == -500 && p.pointer.y == 200 && !p.cursorOnStream)
        #expect(p.streamedDisplay == DesktopDisplay(x: 1680, y: 0, width: 1376, height: 1032))
        // The side monitor goes away: snap onto main's left edge.
        p.applyLayout(DisplayLayout(displays: Array(moved.displays.prefix(2))))
        #expect(p.pointer.x == 0 && p.pointer.y == 200)
        // An empty layout is ignored.
        p.applyLayout(DisplayLayout(displays: []))
        #expect(p.pointer.displays.count == 2)
    }

    @Test func aNewHelloAckForgetsTheLayout() {
        let p = pipeline().pipeline
        p.applyLayout(Self.layout)
        p.configure(ack)
        #expect(!p.hasLayout && p.pointer.displays.count == 1 && p.pointer.x == 688 && p.pointer.y == 516)
    }
}

@Suite struct LocalShortcuts {
    @Test func hudShortcutIsHandledLocallyAndNeverReachesTheMac() {
        var sent: [Message] = []
        let pipeline = ClientInputPipeline(send: { sent.append($0) })
        var fired: [ClientInputPipeline.LocalShortcut] = []
        pipeline.onLocalShortcut = { fired.append($0) }
        let keyU = PhysicalKey.key(0x18)
        pipeline.learnCharacter(keyU, "l")                       // Colemak: the key labelled U types "l"
        for m in [PhysicalKey.leftControl, .leftOption, .leftCommand] { pipeline.keyChanged(m, isDown: true, at: 1) }
        pipeline.keyChanged(keyU, isDown: true, at: 2)
        pipeline.keyChanged(keyU, isDown: false, at: 3)
        #expect(fired == [.toggleHUD])
        let usages = sent.compactMap { m -> UInt16? in if case .keyEvent(let e) = m { e.usage } else { nil } }
        #expect(!usages.contains(0x18))                          // the L key never went to the Mac
        #expect(usages == [0xE0, 0xE2, 0xE3])                    // the modifiers did (harmless alone)
        // The same physical key without the shortcut modifiers types normally.
        for m in [PhysicalKey.leftControl, .leftOption, .leftCommand] { pipeline.keyChanged(m, isDown: false, at: 4) }
        pipeline.keyChanged(keyU, isDown: true, at: 5)
        #expect(sent.contains { if case .keyEvent(let e) = $0 { e.usage == 0x18 && e.isDown } else { false } })
    }
}
