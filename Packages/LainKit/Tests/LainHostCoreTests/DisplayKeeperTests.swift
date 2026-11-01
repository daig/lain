import Foundation
import Synchronization
import Testing
@testable import LainHostCore

/// The display keep-alive (rust/HOST-PARITY.md §1).
@Suite struct DisplayKeeperTests {
    final class FakeDisplay: KeepableDisplay {
        let name: String
        private let state = Mutex((usable: true, removed: 0))
        init(_ name: String) { self.name = name }
        var isUsable: Bool { state.withLock { $0.usable } }
        var removed: Int { state.withLock { $0.removed } }
        func makeUnusable() { state.withLock { $0.usable = false } }
        func remove() async { state.withLock { $0.removed += 1 } }
    }

    @Test func theSameKindIsTakenBack() async {
        let keeper = DisplayKeeper(keepFor: .seconds(30))
        let d = FakeDisplay("a")
        #expect(keeper.keep(d, key: "k"))
        #expect(keeper.isHolding)
        let back = await keeper.take(key: "k")
        #expect(back === d)
        #expect(d.removed == 0)
        #expect(!keeper.isHolding)
        #expect(await keeper.take(key: "k") == nil, "once")
    }

    @Test func anotherKindRemovesItFirst() async {
        let keeper = DisplayKeeper(keepFor: .seconds(30))
        let d = FakeDisplay("a")
        #expect(keeper.keep(d, key: "k"))
        #expect(await keeper.take(key: "other") == nil)
        #expect(d.removed == 1)
    }

    @Test func anUnusableDisplayIsRemoved() async {
        let keeper = DisplayKeeper(keepFor: .seconds(30))
        let d = FakeDisplay("a")
        #expect(keeper.keep(d, key: "k"))
        d.makeUnusable()
        #expect(await keeper.take(key: "k") == nil)
        #expect(d.removed == 1)
    }

    @Test func offKeepsNothing() {
        let keeper = DisplayKeeper(keepFor: .zero)
        #expect(!keeper.keep(FakeDisplay("a"), key: "k"))
        keeper.keepFor = .seconds(5)
        #expect(keeper.keep(FakeDisplay("b"), key: "k"))
    }

    @Test func itExpires() async throws {
        let keeper = DisplayKeeper(keepFor: .milliseconds(50))
        let d = FakeDisplay("a")
        #expect(keeper.keep(d, key: "k"))
        let deadline = ContinuousClock.now + .seconds(2)
        while d.removed == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(d.removed == 1)
        #expect(!keeper.isHolding)
        #expect(await keeper.take(key: "k") == nil)
    }

    @Test func takenBackBeforeTheExpiryItStays() async throws {
        let keeper = DisplayKeeper(keepFor: .milliseconds(50))
        let d = FakeDisplay("a")
        #expect(keeper.keep(d, key: "k"))
        #expect(await keeper.take(key: "k") === d)
        try await Task.sleep(for: .milliseconds(150))
        #expect(d.removed == 0)
    }

    @Test func closeRemovesItAndRefusesMore() async {
        let keeper = DisplayKeeper(keepFor: .seconds(30))
        let d = FakeDisplay("a")
        #expect(keeper.keep(d, key: "k"))
        await keeper.close()
        #expect(d.removed == 1)
        #expect(!keeper.keep(FakeDisplay("b"), key: "k"))
    }

    @Test func aSecondKeptDisplayReplacesTheFirst() async {
        let keeper = DisplayKeeper(keepFor: .seconds(30))
        let a = FakeDisplay("a"), b = FakeDisplay("b")
        #expect(keeper.keep(a, key: "k"))
        #expect(keeper.keep(b, key: "k"))
        await keeper.waitForRemovals()
        #expect(a.removed == 1)
        #expect(await keeper.take(key: "k") === b)
    }
}

#if os(macOS)
@Suite struct DisplayScaleTests {
    func spec(_ scale: Double) -> VirtualDisplay.Spec {
        var s = VirtualDisplay.Spec()
        s.scale = scale
        return s
    }

    @Test func twoIsTheNativeMode() {
        let s = spec(2)
        #expect((s.pointWidth, s.pointHeight) == (1376, 1032))
        #expect((s.backingWidth, s.backingHeight) == (2752, 2064))
        #expect((s.streamWidth, s.streamHeight) == (2752, 2064))
    }

    @Test func moreSpaceRendersLargerAndStreamsThePanelsSize() {
        let s = spec(1.5)
        #expect((s.pointWidth, s.pointHeight) == (1834, 1376))
        #expect((s.backingWidth, s.backingHeight) == (3668, 2752))
        #expect((s.streamWidth, s.streamHeight) == (2752, 2064))
    }

    @Test func largerStreamsItsOwnBackingSize() {
        let s = spec(2.5)
        #expect((s.pointWidth, s.pointHeight) == (1100, 826))
        #expect((s.streamWidth, s.streamHeight) == (2200, 1652))
    }

    @Test func everyChoiceIsEvenAndDistinct() {
        let specs = HostPreferences.scaleChoices.map(spec)
        for s in specs { #expect(s.pointWidth % 2 == 0 && s.pointHeight % 2 == 0 && s.streamWidth % 2 == 0 && s.streamHeight % 2 == 0) }
        #expect(Set(specs.map(\.keeperKey)).count == specs.count)
    }
}
#endif

@Suite struct HostPreferencesTests {
    @Test func defaults() {
        let p = HostPreferences()
        #expect(p.displayKeepAliveSeconds == 30 && p.displayScale == 2 && p.resumeAfterStop && p.systemKey)
    }

    @Test func roundTripsAndClamps() throws {
        let defaults = try #require(UserDefaults(suiteName: "lain.tests.\(UUID().uuidString)"))
        #expect(HostPreferences.load(from: defaults) == HostPreferences())
        var p = HostPreferences()
        p.displayKeepAliveSeconds = 5000
        p.displayScale = 9
        p.resumeAfterStop = false
        p.systemKey = false
        #expect(p.displayKeepAliveSeconds == 600 && p.displayScale == 3)
        p.save(to: defaults)
        #expect(HostPreferences.load(from: defaults) == p)
        defaults.set(-4, forKey: "displayKeepAliveSeconds")
        defaults.set(Double.nan, forKey: "displayScale")
        let q = HostPreferences.load(from: defaults)
        #expect(q.displayKeepAliveSeconds == 0 && q.displayScale == 2)
    }
}
