import CoreGraphics
import LainProtocol
import Testing
@testable import LainHostCore

/// v7: the client asks for its display's scale; the host makes the nearest it can, and says which it made and
/// which it could have.
@Suite struct DisplayScaleChoiceTests {
    let quarters = [1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0]

    @Test func theAskedForScaleWhenItIsOffered() {
        let c = DisplayScaleChoice.choose(requested: 300, supported: quarters, own: 2)
        #expect(c.applied == 3 && c.askedFor && c.supported == quarters)
        #expect(c.wireApplied == 300 && c.wireSupported == [150, 175, 200, 225, 250, 275, 300])
    }

    @Test func otherwiseTheNearestAndOnATieTheLarger() {
        #expect(DisplayScaleChoice.choose(requested: 310, supported: quarters, own: 2).applied == 3)
        #expect(DisplayScaleChoice.choose(requested: 120, supported: quarters, own: 2).applied == 1.5)
        #expect(DisplayScaleChoice.choose(requested: 200, supported: [1.5, 2.5], own: 2).applied == 2.5)
    }

    @Test func aClientThatAsksForNoneGetsTheHostsOwn() {
        // An older client (v6) says nothing: the owner's scale, as before v7.
        let c = DisplayScaleChoice.choose(requested: 0, supported: quarters, own: 1.75)
        #expect(c.applied == 1.75 && !c.askedFor)
        // A provider that makes only its own scale: that, and no list.
        let alone = DisplayScaleChoice.choose(requested: 300, supported: [], own: 2)
        #expect(alone.applied == 2 && alone.supported.isEmpty)
    }

    @Test func helloAckCarriesTheChoice() {
        let display = HostDisplay(displayID: 1, origin: .zero, pointSize: CGSize(width: 951, height: 669))
        let settings = HostInputSettings(doubleClickIntervalMs: 500, keyRepeatDelayMs: 225, keyRepeatIntervalMs: 30, inputSourceID: "")
        let ack = HelloAck.host(display: display, settings: settings, scale: DisplayScaleChoice(applied: 3, supported: [2, 3]))
        #expect(ack.displayScale == 300 && ack.displayScales == [200, 300])
        #expect(HelloAck.host(display: display, settings: settings).displayScales.isEmpty)
    }
}

#if os(macOS)
@Suite struct VirtualDisplayScaleTests {
    @Test func theIPadsPanelOffersOneAndAHalfToThree() {
        // 1.25 would make a 4404 px backing store.
        #expect(VirtualDisplay.Spec.scales(pixelWidth: 2752, pixelHeight: 2064) == [1.5, 1.75, 2, 2.25, 2.5, 2.75, 3])
    }

    @Test func theDuosInnerDisplayOffersTheSameIncludingItsNativeThree() {
        let scales = VirtualDisplay.Spec.scales(pixelWidth: 2853, pixelHeight: 2007)
        #expect(scales == [1.5, 1.75, 2, 2.25, 2.5, 2.75, 3])
        // Every one makes a distinct, even desktop that fits.
        var keys = Set<String>()
        for scale in scales {
            var s = VirtualDisplay.Spec().sized(pixelWidth: 2853, pixelHeight: 2007)
            s.scale = scale
            #expect(s.pointWidth % 2 == 0 && s.pointHeight % 2 == 0 && s.backingWidth <= VirtualDisplay.Spec.maxBackingPixels)
            keys.insert(s.keeperKey)
        }
        #expect(keys.count == scales.count)
    }

    @Test func aSmallerPanelOffersOneToo() {
        #expect(VirtualDisplay.Spec.scales(pixelWidth: 1920, pixelHeight: 1080).first == 1)
    }
}
#endif
