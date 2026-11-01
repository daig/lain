import LainInput
import LainProtocol
import Testing
@testable import LainClientCore

/// Holding Right Option, lain's system key, alone shows the overlay; every key still reaches the Mac.
@Suite struct OverlayHoldTests {
    final class Shown {
        var events: [Bool] = []
    }

    func rig() -> (Recorder, Shown) {
        let r = Recorder(), shown = Shown()
        r.pipeline.onLocalShortcut = { if case .overlay(let on) = $0 { shown.events.append(on) } }
        return (r, shown)
    }

    @Test func aLongHoldShowsItUntilTheRelease() {
        let (r, shown) = rig()
        let p = r.pipeline
        p.keyChanged(.rightOption, isDown: true, at: 0)
        p.tick(at: 300 * ms)
        #expect(shown.events.isEmpty, "not before the hold")
        p.tick(at: 350 * ms)
        #expect(shown.events == [true])
        p.tick(at: 400 * ms)
        #expect(shown.events == [true], "once")
        p.keyChanged(.rightOption, isDown: false, at: 500 * ms)
        #expect(shown.events == [true, false])
        // The Mac saw Right Option down and up, nothing else.
        #expect(r.keys.map(\.usage) == [0xE6, 0xE6])
    }

    @Test func aChordHidesItAndStillReachesTheMac() {
        let (r, shown) = rig()
        let p = r.pipeline
        p.keyChanged(.rightOption, isDown: true, at: 0)
        p.tick(at: 400 * ms)
        p.keyChanged(.key(0x05), isDown: true, at: 450 * ms)   // B
        #expect(shown.events == [true, false])
        #expect(r.keys.last?.usage == 0x05)
    }

    @Test func aQuickChordNeverShowsIt() {
        let (r, shown) = rig()
        let p = r.pipeline
        p.keyChanged(.rightOption, isDown: true, at: 0)
        p.keyChanged(.tab, isDown: true, at: 100 * ms)
        p.tick(at: 1000 * ms)
        #expect(shown.events.isEmpty)
    }

    @Test func notWithAnotherModifierHeld() {
        let (r, shown) = rig()
        let p = r.pipeline
        p.keyChanged(.leftOption, isDown: true, at: 0)
        p.keyChanged(.rightOption, isDown: true, at: 10 * ms)
        p.tick(at: 1000 * ms)
        #expect(shown.events.isEmpty)
    }

    @Test func aClickHidesIt() {
        let (r, shown) = rig()
        let p = r.pipeline
        p.keyChanged(.rightOption, isDown: true, at: 0)
        p.tick(at: 400 * ms)
        p.mouseButton(.left, isDown: true, at: 450 * ms)
        #expect(shown.events == [true, false])
    }

    @Test func releaseAllHidesIt() {
        let (r, shown) = rig()
        let p = r.pipeline
        p.keyChanged(.rightOption, isDown: true, at: 0)
        p.tick(at: 400 * ms)
        p.releaseAll(.focusLost)
        #expect(shown.events == [true, false])
        p.tick(at: 2000 * ms)
        #expect(shown.events == [true, false])
    }

    @Test func itsLongerThanTheHostsLongestTap() {
        #expect(ClientInputPipeline.overlayHoldNs > 300_000_000)
    }
}
