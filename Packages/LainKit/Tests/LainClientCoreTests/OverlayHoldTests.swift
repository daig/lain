import LainInput
import LainProtocol
import Testing
@testable import LainClientCore

/// Holding Right Option, lain's system key, alone opens the panel; it stays open, taking the keyboard and
/// trackpad, until Esc (`closePanel`) or a Right Option tap. Before it opens, every key reaches the host.
@Suite struct OverlayHoldTests {
    final class Seen {
        var events: [ClientInputPipeline.LocalShortcut] = []
        var shown: [Bool] { events.compactMap { if case .overlay(let on) = $0 { on } else { nil } } }
    }

    func rig() -> (Recorder, Seen) {
        let r = Recorder(), seen = Seen()
        r.pipeline.onLocalShortcut = { seen.events.append($0) }
        return (r, seen)
    }

    func open(_ p: ClientInputPipeline) {
        p.keyChanged(.rightOption, isDown: true, at: 0)
        p.tick(at: 400 * ms)
    }

    @Test func aLongHoldOpensItAndItStaysOpenAfterTheRelease() {
        let (r, seen) = rig()
        let p = r.pipeline
        p.keyChanged(.rightOption, isDown: true, at: 0)
        p.tick(at: 300 * ms)
        #expect(seen.shown.isEmpty, "not before the hold")
        p.tick(at: 350 * ms)
        #expect(seen.shown == [true])
        p.keyChanged(.rightOption, isDown: false, at: 500 * ms)
        #expect(seen.shown == [true], "latched")
        #expect(p.overlayShown)
        // The host saw the opening press go down and up (more than 300 ms apart: no tap there).
        #expect(r.keys.map(\.usage) == [0xE6, 0xE6])
    }

    @Test func whileOpenKeysAndTheTrackpadGoToThePanelOnly() {
        let (r, seen) = rig()
        let p = r.pipeline
        open(p)
        p.keyChanged(.rightOption, isDown: false, at: 450 * ms)
        r.take()
        p.keyChanged(.key(0x51), isDown: true, at: 500 * ms)   // ↓
        p.keyChanged(.key(0x51), isDown: false, at: 520 * ms)
        p.mouseMoved(dx: 5, dy: -3, at: 530 * ms)
        p.mouseButton(.left, isDown: true, at: 540 * ms)
        p.mouseButton(.left, isDown: false, at: 560 * ms)
        p.scrollChanged(dx: 0, dy: 10, at: 570 * ms)
        #expect(r.sent.isEmpty, "nothing reaches the host")
        #expect(seen.events.contains(.panelKey(.key(0x51))))
        #expect(seen.events.contains(.panelPointer(dx: 5, dy: -3)))
        #expect(seen.events.contains(.panelClick))
    }

    @Test func aRightOptionTapClosesItWithoutTheHostSeeingIt() {
        let (r, seen) = rig()
        let p = r.pipeline
        open(p)
        p.keyChanged(.rightOption, isDown: false, at: 450 * ms)
        r.take()
        p.keyChanged(.rightOption, isDown: true, at: 600 * ms)
        p.keyChanged(.rightOption, isDown: false, at: 650 * ms)
        #expect(seen.shown == [true, false])
        #expect(r.sent.isEmpty, "no Mission Control")
        // Input goes to the host again.
        p.keyChanged(.key(0x05), isDown: true, at: 700 * ms)
        #expect(r.keys.map(\.usage) == [0x05])
    }

    @Test func closePanelHandsInputBack() {
        let (r, seen) = rig()
        let p = r.pipeline
        open(p)
        p.keyChanged(.key(0x29), isDown: true, at: 450 * ms)   // Esc: the panel's (the view calls closePanel)
        p.closePanel()
        p.keyChanged(.key(0x29), isDown: false, at: 470 * ms)  // its release stays with the panel
        p.keyChanged(.rightOption, isDown: false, at: 500 * ms) // the opening press, still owed to the host
        #expect(seen.shown == [true, false])
        #expect(r.keys.map(\.usage) == [0xE6, 0xE6])
    }

    @Test func aQuickChordNeverOpensIt() {
        let (r, seen) = rig()
        let p = r.pipeline
        p.keyChanged(.rightOption, isDown: true, at: 0)
        p.keyChanged(.tab, isDown: true, at: 100 * ms)
        p.tick(at: 1000 * ms)
        #expect(seen.shown.isEmpty)
        #expect(r.keys.last?.usage == 0x2B)
    }

    @Test func notWithAnotherModifierHeld() {
        let (r, seen) = rig()
        let p = r.pipeline
        p.keyChanged(.leftOption, isDown: true, at: 0)
        p.keyChanged(.rightOption, isDown: true, at: 10 * ms)
        p.tick(at: 1000 * ms)
        #expect(seen.shown.isEmpty)
        _ = r
    }

    @Test func releaseAllClosesIt() {
        let (r, seen) = rig()
        let p = r.pipeline
        open(p)
        p.releaseAll(.focusLost)
        #expect(seen.shown == [true, false])
        p.tick(at: 2000 * ms)
        #expect(seen.shown == [true, false])
        _ = r
    }

    @Test func itsLongerThanTheHostsLongestTap() {
        #expect(ClientInputPipeline.overlayHoldNs > 300_000_000)
    }
}
