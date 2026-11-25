import LainClientCore
import LainInput
import LainProtocol
import Testing

@Suite struct SiriRemotePipelineTests {
    private let ms: UInt64 = 1_000_000

    private func makePipeline() -> (ClientInputPipeline, Box<[Message]>, Box<[ClientInputPipeline.LocalShortcut]>, Box<[ClientInputPipeline.RemoteState]>) {
        let sent = Box<[Message]>([])
        let shortcuts = Box<[ClientInputPipeline.LocalShortcut]>([])
        let states = Box<[ClientInputPipeline.RemoteState]>([])
        let p = ClientInputPipeline(displayPointWidth: 1920, displayPointHeight: 1080) { sent.value.append($0) }
        p.referenceWidth = 1920
        p.touchSurface = (1920, 1080)
        p.onLocalShortcut = { shortcuts.value.append($0) }
        p.onRemoteStateChange = { states.value.append($0) }
        return (p, sent, shortcuts, states)
    }

    @Test func slowRollIsPreciseAndFastSwipeCoversWideDistance() {
        let (p, _, _, _) = makePipeline()
        let startX = p.pointer.x

        // Slow roll: 0.10 normalized over 100 ms in 5 small steps (low speed → gain = 1.0).
        p.remoteSurfaceTouched(true, at: 0)
        p.remoteSurfaceMoved(x: 0.1, y: 0.0, at: 10 * ms)
        for i in 1...5 {
            p.remoteSurfaceMoved(x: 0.1 + Double(i) * 0.02, y: 0.0, at: UInt64(10 + i * 20) * ms)
        }
        p.remoteSurfaceTouched(false, at: 150 * ms)
        let slowDelta = p.pointer.x - startX
        #expect(slowDelta > 4 && slowDelta < 15)

        // Fast swipe across 6× the pad distance (0.60 over 60 ms → high speed → acceleration gain).
        let midX = p.pointer.x
        p.remoteSurfaceTouched(true, at: 300 * ms)
        p.remoteSurfaceMoved(x: -0.3, y: 0.05, at: 305 * ms)
        for i in 1...6 {
            p.remoteSurfaceMoved(x: -0.3 + Double(i) * 0.10, y: 0.05, at: UInt64(305 + i * 10) * ms)
        }
        p.remoteSurfaceTouched(false, at: 400 * ms)
        let fastDelta = p.pointer.x - midX
        #expect(fastDelta > slowDelta * 12)
    }

    @Test func centerClickDoubleClickAndDragLockEmitCorrectWireMessages() {
        let (p, sent, _, states) = makePipeline()

        // Double click within double-click interval.
        p.remoteCenterButton(isDown: true, at: 10 * ms)
        p.remoteCenterButton(isDown: false, at: 60 * ms)
        p.remoteCenterButton(isDown: true, at: 160 * ms)
        p.remoteCenterButton(isDown: false, at: 210 * ms)
        let clicks = sent.value.compactMap { msg -> PointerButton? in
            if case .pointerButton(let b) = msg { b } else { nil }
        }
        #expect(clicks.map(\.clickCount) == [1, 1, 2, 2])
        #expect(clicks.map(\.isDown) == [true, false, true, false])

        // Hold Center still for Drag Lock, release Center, move pointer with left button still held.
        sent.value.removeAll()
        p.remoteCenterButton(isDown: true, at: 1000 * ms)
        p.tick(at: 1450 * ms)
        p.remoteCenterButton(isDown: false, at: 1500 * ms)
        #expect(states.value.last == .init(dragLocked: true, zoomed: false))

        p.remoteIndirectMoved(dx: 0.2, dy: 0.0, at: 1550 * ms)
        let dragMoves = sent.value.compactMap { msg -> PointerMove? in
            if case .pointerMove(let m) = msg { m } else { nil }
        }
        #expect(dragMoves.count == 1 && dragMoves[0].buttons == 1)

        // Second click drops Drag Lock cleanly.
        p.remoteCenterButton(isDown: true, at: 1600 * ms)
        p.remoteCenterButton(isDown: false, at: 1650 * ms)
        #expect(states.value.last == .init(dragLocked: false, zoomed: false))
        #expect(p.heldButtons.mask == 0)
    }

    @Test func zoomToggleBackEscapeAndPlayPauseLongPressOpensPanel() {
        let (p, sent, shortcuts, states) = makePipeline()
        #expect(p.viewport == .full)

        // Programmatic zoom toggle (e.g. from overlay) → 2× zoom centered about pointer.
        p.toggleZoom()
        #expect(abs(p.viewport.width - 0.5) < 1e-6)
        #expect(abs(p.viewport.height - 0.5) < 1e-6)
        #expect(states.value.last == .init(dragLocked: false, zoomed: true))
        #expect(sent.value.isEmpty)

        p.toggleZoom()
        #expect(p.viewport == .full)
        #expect(states.value.last == .init(dragLocked: false, zoomed: false))

        // Short-press Back → Escape key event on host.
        p.remoteMenu(isDown: true, at: 1200 * ms)
        p.remoteMenu(isDown: false, at: 1280 * ms)
        let keys = sent.value.compactMap { msg -> KeyEvent? in
            if case .keyEvent(let k) = msg { k } else { nil }
        }
        #expect(keys.count == 2 && keys[0].isDown && !keys[1].isDown)

        // Long-press Play/Pause → opens overlay panel and blocks subsequent remote moves until closed.
        sent.value.removeAll()
        p.remotePlayPause(isDown: true, at: 1500 * ms)
        p.tick(at: 1900 * ms)
        p.remotePlayPause(isDown: false, at: 1950 * ms)
        #expect(shortcuts.value == [.overlay(true)])
        #expect(p.overlayShown)

        p.remoteIndirectMoved(dx: 0.25, dy: 0.0, at: 2000 * ms)
        #expect(sent.value.isEmpty)

        p.closePanel()
        p.remoteIndirectMoved(dx: 0.25, dy: 0.0, at: 2100 * ms)
        #expect(!sent.value.isEmpty)
    }

    @Test func outerRingHoldProducesSmoothScrollAndRespectsInvertScroll() {
        let (p, sent, _, _) = makePipeline()
        p.remoteRingDirection(.down, isDown: true, at: 0)
        for step in 1...15 {
            p.tick(at: UInt64(step * 25) * ms)
        }
        p.remoteRingDirection(.down, isDown: false, at: 400 * ms)
        let scrolls = sent.value.compactMap { msg -> Scroll? in
            if case .scroll(let s) = msg { s } else { nil }
        }
        #expect(scrolls.first?.phase == .began)
        #expect(scrolls.last?.phase == .ended)
        #expect(scrolls.contains { $0.dy < 0 })

        // Invert scroll flips the sign.
        sent.value.removeAll()
        p.invertScroll = true
        p.remoteRingDirection(.down, isDown: true, at: 1000 * ms)
        p.remoteRingDirection(.down, isDown: false, at: 1050 * ms)
        let inverted = sent.value.compactMap { msg -> Scroll? in
            if case .scroll(let s) = msg { s } else { nil }
        }
        #expect(inverted.first { $0.phase == .began }.map { $0.dy > 0 } == true)
    }

    @Test func releaseAllClearsDragLockAndHeldButtons() {
        let (p, sent, _, states) = makePipeline()
        p.remoteCenterButton(isDown: true, at: 0)
        p.tick(at: 450 * ms)
        p.remoteCenterButton(isDown: false, at: 500 * ms)
        #expect(p.remoteState.dragLocked)

        p.releaseAll(.focusLost)
        #expect(!p.remoteState.dragLocked)
        #expect(p.heldButtons.mask == 0)
        #expect(states.value.last?.dragLocked == false)
        #expect(sent.value.contains { if case .releaseAll = $0 { true } else { false } })
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
