import LainProtocol
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
        func releaseNow() { state.withLock { $0.removed += 1 } }
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

    @Test func clearSyncAndCloseSyncReleaseImmediately() {
        let keeper = DisplayKeeper(keepFor: .seconds(30))
        let a = FakeDisplay("a"), b = FakeDisplay("b")
        #expect(keeper.keep(a, key: "k"))
        keeper.clearSync()
        #expect(a.removed == 1 && !keeper.isHolding)
        #expect(keeper.keep(b, key: "k"), "keeping still works after clearSync")
        keeper.closeSync()
        #expect(b.removed == 1 && !keeper.isHolding)
        #expect(!keeper.keep(FakeDisplay("c"), key: "k"), "closed after closeSync")
    }

    @Test func powerAssertionIsHeldOnlyWhileKeepingADisplay() async throws {
        let power = RecordingPower()
        let keeper = DisplayKeeper(keepFor: .milliseconds(60), power: power)
        let a = FakeDisplay("a"), b = FakeDisplay("b"), c = FakeDisplay("c")

        #expect(keeper.keep(a, key: "k"))
        #expect(power.holding && power.begins == 1 && power.ends == 0)

        // Replacing a kept display keeps power balanced (1 begin, 0 ends).
        #expect(keeper.keep(b, key: "k"))
        #expect(power.holding && power.begins == 1 && power.ends == 0)

        // Taking it back releases the keeper's power hold.
        #expect(await keeper.take(key: "k") === b)
        #expect(!power.holding && power.begins == 1 && power.ends == 1)

        // Letting it expire releases power automatically.
        #expect(keeper.keep(c, key: "k"))
        #expect(power.holding && power.begins == 2 && power.ends == 1)
        let deadline = ContinuousClock.now + .seconds(2)
        while power.holding, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!power.holding && power.begins == 2 && power.ends == 2)

        // clearSync and closeSync release immediately too.
        #expect(keeper.keep(FakeDisplay("d"), key: "k"))
        #expect(power.holding)
        keeper.clearSync()
        #expect(!power.holding && power.begins == 3 && power.ends == 3)
        #expect(keeper.keep(FakeDisplay("e"), key: "k"))
        keeper.closeSync()
        #expect(!power.holding && power.begins == 4 && power.ends == 4)
    }
}

#if os(macOS)
@Suite struct DisplayScaleTests {
    func spec(_ scale: Double) -> VirtualDisplay.Spec {
        var s = VirtualDisplay.Spec()
        s.scale = scale
        return s
    }

    @Test func aClientsRequestShapesItsDisplay() {
        // An iPhone Duo asks for its inner display; here at the owner's 2.5.
        let duo = spec(2.5).sized(pixelWidth: 2853, pixelHeight: 2007)
        #expect((duo.pointWidth, duo.pointHeight) == (1142, 802))
        #expect((duo.streamWidth, duo.streamHeight) == (2284, 1604))
        #expect(duo.serial != 1 && duo.keeperKey != spec(2.5).keeperKey, "macOS and the keeper tell it from the iPad's")
        // Portrait display sizes (e.g. iPhone 18 Pro Max above the portrait keyboard) are supported too.
        let portrait = spec(2).sized(pixelWidth: 1320, pixelHeight: 1584)
        #expect((portrait.pointWidth, portrait.pointHeight) == (660, 792))
        #expect((portrait.streamWidth, portrait.streamHeight) == (1320, 1584))
        #expect(portrait.serial != 1 && portrait.serial != duo.serial)
        // The iPad's own size, or none that makes a display: the iPad's display, as before.
        for (w, h) in [(2752, 2064), (0, 0), (400, 1000), (100_000, 2000)] {
            let same = spec(2).sized(pixelWidth: w, pixelHeight: h)
            #expect((same.pixelWidth, same.pixelHeight, same.serial) == (2752, 2064, 1))
        }
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

    @Test func cappedCaptureSizePreservesMacBookAndCaps6K() {
        #expect(VirtualDisplay.cappedCaptureSize(pixelWidth: 3456, pixelHeight: 2234) == (3456, 2234))
        #expect(VirtualDisplay.cappedCaptureSize(pixelWidth: 3024, pixelHeight: 1964) == (3024, 1964))
        let sixK = VirtualDisplay.cappedCaptureSize(pixelWidth: 6016, pixelHeight: 3384)
        #expect(sixK == (3840, 2160))
    }
}
#endif

@Suite struct HostPreferencesTests {
    @Test func defaults() {
        let p = HostPreferences()
        #expect(p.displayKeepAliveSeconds == 30 && p.displayScale == 2 && p.resumeAfterStop && p.systemKey && p.colorFormat == .full)
    }

    @Test func roundTripsAndClamps() throws {
        let defaults = try #require(UserDefaults(suiteName: "lain.tests.\(UUID().uuidString)"))
        #expect(HostPreferences.load(from: defaults) == HostPreferences())
        var p = HostPreferences()
        p.displayKeepAliveSeconds = 5000
        p.displayScale = 9
        p.resumeAfterStop = false
        p.systemKey = false
        p.colorFormat = .reduced
        #expect(p.displayKeepAliveSeconds == 600 && p.displayScale == 3)
        p.save(to: defaults)
        #expect(HostPreferences.load(from: defaults) == p)
        defaults.set(-4, forKey: "displayKeepAliveSeconds")
        defaults.set(Double.nan, forKey: "displayScale")
        let q = HostPreferences.load(from: defaults)
        #expect(q.displayKeepAliveSeconds == 0 && q.displayScale == 2)
    }
}

@Suite struct ColorFormatTests {
    @Test func reducedForces420AndFullNeedsTheIPadsHardware() {
        let with444 = Hello(deviceModel: "iPad", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                            decodeCapabilities: [.hevcMain, .hevcMain44410Hardware], keyboardType: .ansi)
        var without = with444
        without.decodeCapabilities = [.hevcMain]
        #expect(HostVideoPipeline.requestedChroma(for: with444, allows444: true) == .yuv444)
        #expect(HostVideoPipeline.requestedChroma(for: with444, allows444: false) == .yuv420)
        #expect(HostVideoPipeline.requestedChroma(for: without, allows444: true) == .yuv420)
    }
}
