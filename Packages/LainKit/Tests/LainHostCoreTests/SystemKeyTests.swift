import LainProtocol
import Testing
@testable import LainHostCore

/// Right Option as lain's system key (rust/HOST-PARITY.md §4).
@Suite struct SystemKeyTests {
    typealias M = ModifierFlags
    static let rightOption: UInt16 = 0xE6, leftOption: UInt16 = 0xE2, leftCommand: UInt16 = 0xE3, leftControl: UInt16 = 0xE0
    static let b: UInt16 = 0x05, tab: UInt16 = 0x2B, up: UInt16 = 0x52, down: UInt16 = 0x51, left: UInt16 = 0x50, right: UInt16 = 0x4F

    func k(_ usage: UInt16, _ down: Bool, _ m: M = [], repeat r: Bool = false) -> KeyEvent {
        KeyEvent(usage: usage, isDown: down, isRepeat: r, modifiers: m)
    }

    func chord(_ arrow: UInt16) -> [KeyEvent] {
        [k(Self.leftControl, true, .control), k(arrow, true, [.control, .function]), k(arrow, false, [.control, .function]),
         k(Self.leftControl, false)]
    }

    func feed(_ sk: inout SystemKey, _ events: [KeyEvent]) -> [KeyEvent] { events.flatMap { sk.key($0) } }

    @Test func holdingItWithAKeyIsCommand() {
        var sk = SystemKey()
        let out = feed(&sk, [k(Self.rightOption, true, .option), k(Self.b, true, .option), k(Self.b, false, .option),
                             k(Self.rightOption, false)])
        #expect(out == [k(Self.leftCommand, true, .command), k(Self.b, true, .command), k(Self.b, false, .command), k(Self.leftCommand, false)])
        #expect(sk.pendingTap == nil, "not a tap")
    }

    @Test func commandStaysHeldSoTabCyclesTheAppSwitcher() {
        var sk = SystemKey()
        let out = feed(&sk, [k(Self.rightOption, true, .option), k(Self.tab, true, .option), k(Self.tab, false, .option),
                             k(Self.tab, true, .option), k(Self.tab, false, .option), k(Self.rightOption, false)])
        #expect(out == [k(Self.leftCommand, true, .command), k(Self.tab, true, .command), k(Self.tab, false, .command),
                        k(Self.tab, true, .command), k(Self.tab, false, .command), k(Self.leftCommand, false)])
    }

    @Test func arrowsAreControlArrowChordsAndTheirReleaseSendsNothing() {
        for arrow in [Self.up, Self.down, Self.left, Self.right] {
            var sk = SystemKey()
            let out = feed(&sk, [k(Self.rightOption, true, .option), k(arrow, true, .option), k(arrow, true, .option, repeat: true),
                                 k(arrow, false, .option), k(Self.rightOption, false)])
            #expect(out == chord(arrow), "arrow \(arrow)")
            #expect(sk.pendingTap == nil)
        }
    }

    @Test func aChordLiftsTheSystemKeysCommandFirst() {
        var sk = SystemKey()
        let out = feed(&sk, [k(Self.rightOption, true, .option), k(Self.b, true, .option), k(Self.b, false, .option),
                             k(Self.left, true, .option), k(Self.left, false, .option), k(Self.rightOption, false)])
        #expect(out == [k(Self.leftCommand, true, .command), k(Self.b, true, .command), k(Self.b, false, .command), k(Self.leftCommand, false)]
                + chord(Self.left))
    }

    @Test func aTapAloneIsMissionControlOnceTheTimerFires() {
        var sk = SystemKey()
        #expect(feed(&sk, [k(Self.rightOption, true, .option), k(Self.rightOption, false)]).isEmpty)
        let tap = try! #require(sk.pendingTap)
        let first = sk.flushTap(tap), again = sk.flushTap(tap)
        #expect(first == chord(Self.up))
        #expect(again.isEmpty, "once")
    }

    @Test func aTapIsTakenAtOnceWhenAnotherKeyFollows() {
        var sk = SystemKey()
        let out = feed(&sk, [k(Self.rightOption, true, .option), k(Self.rightOption, false), k(Self.b, true), k(Self.b, false)])
        #expect(out == chord(Self.up) + [k(Self.b, true), k(Self.b, false)])
        #expect(sk.pendingTap == nil)
    }

    /// An older client's remap (`KeyboardProcessor`): Opt-Tab arrives as Opt up, then Cmd down and Tab.
    @Test func theClientsOwnRemapIsNotATap() {
        var sk = SystemKey()
        let out = feed(&sk, [k(Self.rightOption, true, .option), k(Self.rightOption, false), k(Self.leftCommand, true, .command),
                             k(Self.tab, true, .command), k(Self.tab, false, .command), k(Self.leftCommand, false)])
        #expect(out == [k(Self.leftCommand, true, .command), k(Self.tab, true, .command), k(Self.tab, false, .command),
                        k(Self.leftCommand, false)])
        #expect(sk.pendingTap == nil)
    }

    @Test func aStaleTimerDoesNothingToANewerTap() {
        var sk = SystemKey()
        _ = feed(&sk, [k(Self.rightOption, true, .option), k(Self.rightOption, false)])
        let first = try! #require(sk.pendingTap)
        _ = feed(&sk, [k(Self.rightOption, true, .option), k(Self.rightOption, false)])   // the first became a tap here
        let second = try! #require(sk.pendingTap)
        #expect(first != second)
        let stale = sk.flushTap(first), fresh = sk.flushTap(second)
        #expect(stale.isEmpty)
        #expect(fresh == chord(Self.up))
    }

    @Test func leftOptionIsPlainOption() {
        var sk = SystemKey()
        let events = [k(Self.leftOption, true, .option), k(Self.left, true, .option), k(Self.left, false, .option),
                      k(Self.leftOption, false)]
        #expect(feed(&sk, events) == events)
        #expect(sk.pendingTap == nil)
    }

    @Test func bothOptionsArePlainOption() {
        var sk = SystemKey()
        let events = [k(Self.leftOption, true, .option), k(Self.rightOption, true, .option), k(Self.b, true, .option),
                      k(Self.b, false, .option), k(Self.rightOption, false, .option), k(Self.leftOption, false)]
        #expect(feed(&sk, events) == events)
    }

    @Test func otherModifiersPassWithoutOption() {
        var sk = SystemKey()
        let out = feed(&sk, [k(Self.rightOption, true, .option), k(0xE1, true, [.option, .shift]), k(Self.b, true, [.option, .shift]),
                             k(Self.b, false, [.option, .shift]), k(0xE1, false, .option), k(Self.rightOption, false)])
        #expect(out == [k(0xE1, true, .shift), k(Self.leftCommand, true, [.shift, .command]), k(Self.b, true, [.shift, .command]),
                        k(Self.b, false, [.shift, .command]), k(0xE1, false, .command), k(Self.leftCommand, false)])
    }

    @Test func aClickWithItIsACommandClick() {
        var sk = SystemKey()
        _ = sk.key(k(Self.rightOption, true, .option))
        let held = sk.buttonModifiers(.option)
        let release = sk.key(k(Self.rightOption, false))
        let after = sk.buttonModifiers([])
        #expect(held == .command)
        #expect(release.isEmpty)
        #expect(sk.pendingTap == nil, "a click isn't a tap")
        #expect(after == [])
    }

    @Test func offPassesEverything() {
        var sk = SystemKey(isEnabled: false)
        let events = [k(Self.rightOption, true, .option), k(Self.up, true, .option), k(Self.up, false, .option), k(Self.rightOption, false)]
        #expect(feed(&sk, events) == events)
        #expect(sk.pendingTap == nil)
    }

    @Test func lostOptionStateLiftsTheCommand() {
        var sk = SystemKey()
        _ = feed(&sk, [k(Self.rightOption, true, .option), k(Self.b, true, .option)])
        // The client says no Option is held (its Right Option release was lost).
        let out = sk.key(k(Self.b, false))
        #expect(out == [k(Self.leftCommand, false), k(Self.b, false)])
        #expect(!sk.isHeld)
    }

    @Test func theRouterPostsThroughTheSystemKeyAndReleasesIt() {
        let sink = RecordingSink()
        var router = HostInputRouter(sink: sink, systemKey: true)
        _ = router.handle(.keyEvent(k(Self.rightOption, true, .option)))
        _ = router.handle(.keyEvent(k(Self.rightOption, false)))
        let tap = try! #require(router.pendingSystemKeyTap)
        let flushed = router.flushSystemKeyTap(tap)
        #expect(flushed)
        #expect(sink.inputCalls == chord(Self.up).map { .key($0) })
        sink.clear()
        _ = router.handle(.keyEvent(k(Self.rightOption, true, .option)))
        _ = router.handle(.keyEvent(k(Self.b, true, .option)))
        router.releaseAll()
        #expect(sink.inputCalls == [.key(k(Self.leftCommand, true, .command)), .key(k(Self.b, true, .command)), .releaseAll])
        #expect(!router.systemKey.isHeld)
    }
}
