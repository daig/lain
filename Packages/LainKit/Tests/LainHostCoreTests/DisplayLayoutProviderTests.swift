import CoreGraphics
import LainProtocol
import Synchronization
import Testing
@testable import LainHostCore

/// A settable display list standing in for `CGGetActiveDisplayList`.
final class FakeDisplaySource: ActiveDisplaySource {
    let displays: Mutex<[ActiveDisplay]>
    init(_ displays: [ActiveDisplay]) { self.displays = Mutex(displays) }
    func activeDisplays() -> [ActiveDisplay] { displays.withLock { $0 } }
}

@Suite struct DisplayLayoutProviderTests {
    static let main = ActiveDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1680, height: 1050),
                                    vendor: 0x10AC, model: 0xA0C4, isMain: true)
    static let lain = ActiveDisplay(displayID: 17, bounds: CGRect(x: 0, y: 1050, width: 1376, height: 1032),
                                    vendor: 0x4C41, model: 1)
    static let side = ActiveDisplay(displayID: 4, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                    vendor: 0x10AC, model: 0xA0C5)
    static let placeholder = ActiveDisplay(displayID: 30, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                           vendor: ActiveDisplay.placeholderVendor,
                                           model: ActiveDisplay.placeholderModel, isMain: true)

    @Test func everyDisplayWithTheStreamedOneMarked() {
        let source = FakeDisplaySource([Self.main, Self.lain, Self.side])
        let provider = DisplayLayoutProvider(source: source, streamedDisplayID: { 17 })
        #expect(provider.desktopLayout() == DisplayLayout(displays: [
            .init(displayID: 1, x: 0, y: 0, width: 1680, height: 1050, isStreamed: false),
            .init(displayID: 17, x: 0, y: 1050, width: 1376, height: 1032, isStreamed: true),
            .init(displayID: 4, x: -1920, y: 0, width: 1920, height: 1080, isStreamed: false),
        ]))
        #expect(provider.targetDisplay() == HostDisplay(displayID: 17, origin: CGPoint(x: 0, y: 1050),
                                                        pointSize: CGSize(width: 1376, height: 1032)))
    }

    @Test func thePlaceholderIsLeftOutWhenARealDisplayExists() {
        #expect(Self.placeholder.isPlaceholder && !Self.main.isPlaceholder)
        // Headless with lain's display up: only ours counts.
        let layout = DisplayLayoutProvider.layout([Self.placeholder, Self.lain], streamed: 17)
        #expect(layout.displays.map(\.displayID) == [17])
        #expect(layout.displays.first?.isStreamed == true)
        // The placeholder alone (lain's display not up yet) is still where the cursor is.
        let alone = DisplayLayoutProvider.layout([Self.placeholder], streamed: nil)
        #expect(alone.displays.map(\.displayID) == [30] && alone.displays.allSatisfy { !$0.isStreamed })
    }

    @Test func streamedFollowsTheClosureAndFallsBackToMainForTheTarget() {
        let source = FakeDisplaySource([Self.main, Self.side])
        let streamed = Mutex<UInt32?>(1)
        let provider = DisplayLayoutProvider(source: source, streamedDisplayID: { streamed.withLock { $0 } })
        #expect(provider.desktopLayout().displays.filter(\.isStreamed).map(\.displayID) == [1])
        // Video binds the virtual display later; until it appears nothing is streamed.
        streamed.withLock { $0 = 17 }
        #expect(provider.desktopLayout().displays.allSatisfy { !$0.isStreamed })
        #expect(provider.targetDisplay().displayID == 1)   // HelloAck falls back to main
        source.displays.withLock { $0.append(Self.lain) }
        #expect(provider.desktopLayout().displays.filter(\.isStreamed).map(\.displayID) == [17])
        #expect(provider.targetDisplay().pointSize == CGSize(width: 1376, height: 1032))
    }

    @Test func noDisplaysGiveAnEmptyLayoutAndAZeroTarget() {
        let provider = DisplayLayoutProvider(source: FakeDisplaySource([]), streamedDisplayID: { nil })
        #expect(provider.desktopLayout().displays.isEmpty)
        #expect(provider.targetDisplay().pointSize == .zero)
    }

    /// Implements only the required members, so `desktopLayout()` is the protocol's default.
    struct TargetOnly: DisplayProvider {
        func targetDisplay() -> HostDisplay {
            HostDisplay(displayID: 3, origin: CGPoint(x: -1512, y: 0), pointSize: CGSize(width: 1512, height: 982))
        }
        func cursorLocation() -> CGPoint? { nil }
    }

    @Test func theDefaultLayoutIsTheTargetDisplayAlone() {
        #expect(TargetOnly().desktopLayout() == DisplayLayout(displays: [
            .init(displayID: 3, x: -1512, y: 0, width: 1512, height: 982, isStreamed: true)]))
    }
}
