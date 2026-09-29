#if os(macOS)
import CoreGraphics
import LainProtocol
import Testing
@testable import LainHostCore

@Suite struct InjectorMapping {
    @Test func modifierFlags() {
        #expect(InputInjector.cgFlags([]) == [])
        #expect(InputInjector.cgFlags([.command, .shift]) == [.maskCommand, .maskShift])
        #expect(InputInjector.cgFlags([.control, .option, .function, .capsLock])
                == [.maskControl, .maskAlternate, .maskSecondaryFn, .maskAlphaShift])
    }

    @Test func movesWithAButtonHeldAreDrags() {
        #expect(InputInjector.moveType(buttons: 0) == (.mouseMoved, .left))
        #expect(InputInjector.moveType(buttons: 0b01) == (.leftMouseDragged, .left))
        #expect(InputInjector.moveType(buttons: 0b10) == (.rightMouseDragged, .right))
        #expect(InputInjector.moveType(buttons: 0b100) == (.otherMouseDragged, .center))
    }

    @Test func buttons() {
        #expect(InputInjector.buttonType(.left, down: true) == (.leftMouseDown, .left))
        #expect(InputInjector.buttonType(.right, down: false) == (.rightMouseUp, .right))
        #expect(InputInjector.buttonType(.other, down: true) == (.otherMouseDown, .center))
    }

    @Test func scrollPhasesUseTheSDKConstants() {
        // kCGScrollPhase*: Began 1, Changed 2, Ended 4, Cancelled 8, MayBegin 128.
        #expect(GesturePhase.allCases.map(InputInjector.scrollPhase) == [0, 128, 1, 2, 4, 8])
        // kCGMomentumScrollPhase*: None 0, Begin 1, Continue 2, End 3.
        #expect(MomentumPhase.allCases.map(InputInjector.momentumPhase) == [0, 1, 2, 3])
    }

    @Test func macSettingsAreSane() {
        #expect((100...5000).contains(MacInputSettings.doubleClickIntervalMs))
        #expect(MacInputSettings.keyRepeatIntervalMs > 0)
        #expect(MacInputSettings.inputSourceID.contains("."))
    }
}
#endif
