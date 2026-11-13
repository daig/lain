import CoreGraphics
import LainClientCore
import Testing

/// The stream view's frames from the window's size. The Duo's numbers are measured on its simulator (27.2):
/// closed, the window is 466 × 678 with 84 points kept clear beside the camera.
@Suite struct StreamLayoutTests {
    /// A 13-inch iPad Pro's Mac display, and the Duo's inner display: both near 4:3.
    private let iPadAspect: CGFloat = 1376.0 / 1032.0
    private let duoAspect: CGFloat = 951.0 / 669.0

    private func input(_ w: CGFloat, _ h: CGFloat, aspect: CGFloat, _ change: (inout StreamLayout.Input) -> Void = { _ in }) -> StreamLayout.Input {
        var i = StreamLayout.Input(size: CGSize(width: w, height: h))
        i.streamAspect = aspect
        change(&i)
        return i
    }

    // MARK: iPad (unchanged by the phone's forms)

    @Test func iPadLandscapeFillsTheWindowWithThumbPatches() {
        let l = StreamLayout(input(1376, 1032, aspect: iPadAspect) { $0.safeArea.bottom = 20 })
        #expect(!l.isPortrait && !l.isRemote && l.band == nil && l.controls == nil)
        #expect(l.stream == CGRect(x: 0, y: 0, width: 1376, height: 1032))
        #expect(l.cornerPads == [CGRect(x: 36, y: 808, width: 150, height: 120), CGRect(x: 1190, y: 808, width: 150, height: 120)])
        #expect(l.edgeButton == CGPoint(x: 1342, y: 516))
            }

    @Test func iPadWithMagicKeyboardShowsNoTouchControls() {
        let l = StreamLayout(input(1376, 1032, aspect: iPadAspect) { $0.softKeyboard = false; $0.touchPointer = false })
        #expect(l.cornerPads.isEmpty && l.edgeButton == nil && l.band == nil)
        let p = StreamLayout(input(1032, 1376, aspect: iPadAspect) { $0.softKeyboard = false; $0.touchPointer = false })
        #expect(p.band == nil && !p.keyboardIsAutomatic)
    }

    @Test func iPadPortraitPutsTheBandBetweenTheStreamAndTheKeyboard() {
        let l = StreamLayout(input(1032, 1376, aspect: iPadAspect) { $0.keyboardInset = 400 })
        #expect(l.isPortrait && !l.isRemote && l.keyboardIsAutomatic)
        #expect(l.stream == CGRect(x: 0, y: 0, width: 1032, height: 774))
        #expect(l.band == CGRect(x: 8, y: 782, width: 1016, height: 186))
        #expect(l.bandHasKeys)
    }

    @Test func aKeyboardWithoutATrackpadKeepsTheTrackpadAreas() {
        // A Bluetooth keyboard on a phone: keys come from it, the pointer still from the glass.
        let l = StreamLayout(input(951, 669, aspect: duoAspect) { $0.softKeyboard = false })
        #expect(l.cornerPads.count == 2 && l.edgeButton == nil)
    }

    // MARK: iPhone Duo, open

    @Test func duoOpenLandscapeIsTheIPadLayout() {
        let l = StreamLayout(input(951, 669, aspect: duoAspect))
        #expect(l.stream == CGRect(x: 0, y: 0, width: 951, height: 669))
        #expect(l.cornerPads.count == 2 && l.cornerPads.allSatisfy { $0.size == CGSize(width: 150, height: 120) })
        #expect(l.transcriptCenterX == 475.5)
    }

    @Test func duoOpenLandscapeWithTheKeyboardPutsItsKeysBesideTheStream() {
        // The keyboard and its row cover 300; without the row (48) the picture has 417 of height.
        let l = StreamLayout(input(951, 669, aspect: duoAspect) { $0.keyboardInset = 300; $0.keyRowHeight = 48 })
        #expect(l.stream == CGRect(x: 179, y: 0, width: 593, height: 417))
        #expect(l.sideKeys == [CGRect(x: 8, y: 8, width: 163, height: 132), CGRect(x: 780, y: 8, width: 163, height: 132)])
        #expect(l.cornerPads == [CGRect(x: 8, y: 148, width: 163, height: 261), CGRect(x: 780, y: 148, width: 163, height: 261)])
        #expect(l.edgeButton == nil, "the microphone is among the side keys")
        // Once the row is gone the keyboard covers 252: the same layout, so it doesn't flip back.
        #expect(StreamLayout(input(951, 669, aspect: duoAspect) { $0.keyboardInset = 252 }) == l)
        // Without the keyboard: the whole window, as before.
        #expect(StreamLayout(input(951, 669, aspect: duoAspect)).sideKeys.isEmpty)
    }

    @Test func anIPadKeepsItsRowOfKeys() {
        let l = StreamLayout(input(1376, 1032, aspect: iPadAspect) { $0.keyboardInset = 450; $0.keyRowHeight = 48 })
        #expect(l.sideKeys.isEmpty && l.stream == CGRect(x: 0, y: 0, width: 1376, height: 582) && l.edgeButton != nil)
    }

    @Test func duoFoldedLikeABookMovesTheTranscriptOffTheFold() {
        let l = StreamLayout(input(951, 669, aspect: duoAspect) { $0.fold = CGRect(x: 455, y: 0, width: 41, height: 669) })
        #expect(l.stream.width == 951, "the picture stays whole")
        #expect(l.transcriptCenterX == 723.5)
    }

    @Test func duoOpenPortraitHasTheStreamOverTheBand() {
        let l = StreamLayout(input(669, 951, aspect: duoAspect) { $0.keyboardInset = 340 })
        #expect(l.stream == CGRect(x: 0, y: 0, width: 669, height: 471))
        #expect(l.band == CGRect(x: 8, y: 479, width: 653, height: 124))
        #expect(l.keyboardIsAutomatic && !l.isRemote)
    }

    @Test func duoOpenPortraitWithATallKeyboardStillHasATrackpad() {
        // The keyboard leaves 551: too little for the band under the picture, so a strip with a scroll ribbon.
        let l = StreamLayout(input(669, 951, aspect: duoAspect) { $0.keyboardInset = 400 })
        #expect(l.stream == CGRect(x: 0, y: 0, width: 669, height: 471))
        #expect(l.band == CGRect(x: 8, y: 475, width: 653, height: 72) && !l.bandHasKeys && l.stripHasRibbon)
        // Taller still: the picture gives up what a 48-point strip lacks.
        let taller = StreamLayout(input(669, 951, aspect: duoAspect) { $0.keyboardInset = 460 })
        #expect(taller.stream.height == 435 && taller.band?.height == 48)
    }

    // MARK: iPhone Duo, folded like a laptop: the deck

    private let laptopFold = CGRect(x: 0, y: 455, width: 669, height: 41)

    @Test func duoFoldedLikeALaptopHasTheDeckUnderTheFold() throws {
        let l = StreamLayout(input(669, 951, aspect: duoAspect) { $0.fold = laptopFold; $0.safeArea.bottom = 20 })
        let deck = try #require(l.deck)
        // The picture fills the half above the fold, zoomed in where its shape differs.
        #expect(l.stream == CGRect(x: 0, y: 0, width: 669, height: 455) && l.fillsStream)
        #expect(!l.keyboardIsAutomatic && l.band == nil && l.controls == nil && l.edgeButton == nil && l.cornerPads.isEmpty)
        #expect(deck.frame == CGRect(x: 8, y: 504, width: 653, height: 419))
        // The keys along the fold; under them the trackpad, and the microphone's column at the right.
        #expect(deck.keys == CGRect(x: 8, y: 504, width: 653, height: 48))
        #expect(deck.trackpad == CGRect(x: 8, y: 560, width: 533, height: 363))
        #expect(deck.settings == CGRect(x: 549, y: 560, width: 112, height: 44))
        // The microphone reaches the front corner, under the hand.
        #expect(deck.mic == CGRect(x: 549, y: 612, width: 112, height: 311))
    }

    @Test func theDeckIgnoresAKeyboardLeftUpFromBeforeTheFold() {
        let up = StreamLayout(input(669, 951, aspect: duoAspect) { $0.fold = laptopFold; $0.keyboardInset = 340 })
        #expect(up == StreamLayout(input(669, 951, aspect: duoAspect) { $0.fold = laptopFold }))
        #expect(up.deck != nil && !up.keyboardIsAutomatic)
    }

    @Test func theDeckIsOnlyForTheLaptopPose() {
        // Open, folded like a book, or with a Magic Keyboard and a mouse: no deck.
        #expect(StreamLayout(input(669, 951, aspect: duoAspect) { $0.keyboardInset = 340 }).deck == nil)
        #expect(StreamLayout(input(951, 669, aspect: duoAspect) { $0.fold = CGRect(x: 455, y: 0, width: 41, height: 669) }).deck == nil)
        #expect(StreamLayout(input(669, 951, aspect: duoAspect) { $0.fold = laptopFold; $0.softKeyboard = false; $0.touchPointer = false }).deck == nil)
        // A keyboard alone still wants the trackpad and the microphone.
        #expect(StreamLayout(input(669, 951, aspect: duoAspect) { $0.fold = laptopFold; $0.softKeyboard = false }).deck != nil)
    }

    // MARK: iPhone Duo, closed

    private func closed(_ change: (inout StreamLayout.Input) -> Void = { _ in }) -> StreamLayout {
        StreamLayout(input(466, 678, aspect: duoAspect) {
            $0.isCompact = true
            $0.safeArea = .init(bottom: 34, right: 84)
            $0.occlusions = [CGRect(x: 399.67, y: 29.33, width: 37, height: 37), CGRect(x: 382, y: 0, width: 84, height: 82)]
            change(&$0)
        })
    }

    @Test func duoClosedIsARemote() throws {
        let l = closed()
        #expect(l.isRemote && l.cornerPads.isEmpty && l.edgeButton == nil)
        // The stream beside the camera's strip, the controls down the strip under the camera.
        #expect(l.stream == CGRect(x: 0, y: 0, width: 382, height: 269))
        #expect(l.controls == StreamLayout.Controls(frame: CGRect(x: 382, y: 82, width: 84, height: 562), isVertical: true))
        // The rest is the trackpad.
        let band = try #require(l.band)
        #expect(band == CGRect(x: 8, y: 277, width: 366, height: 359))
        #expect(l.bandHasKeys)
        #expect(l.transcriptCenterX == 191)
    }

    @Test func duoClosedWithTheKeyboardHasATrackpadStripBetweenThePictureAndTheKeyboard() {
        // As measured on the phone: the keyboard and its row cover 313, which leaves 365. The picture at full
        // width would leave 37: it gives up a little so that the strip is 40.
        let l = closed { $0.keyboardInset = 313 }
        #expect(l.isRemote && l.keyboardIsAutomatic && l.controls == nil && l.cornerPads.isEmpty)
        #expect(l.stream == CGRect(x: 8, y: 0, width: 451, height: 317), "nearly the whole width, under the camera")
        #expect(l.band == CGRect(x: 8, y: 321, width: 450, height: 40) && !l.bandHasKeys)
        #expect(l.stripHasRibbon && !l.ribbonOnLeft, "a ribbon to scroll with at the strip's right end")
        // A shorter keyboard: the picture at full width, and the strip takes all that is left.
        let short = closed { $0.keyboardInset = 280 }
        #expect(short.stream == CGRect(x: 0, y: 0, width: 466, height: 328))
        #expect(short.band == CGRect(x: 8, y: 332, width: 450, height: 62))
        // A very tall one: the picture is as tall as the room allows, and narrower.
        let tall = closed { $0.keyboardInset = 400 }
        #expect(tall.stream.height == 230 && tall.band?.height == 40)
    }

    @Test func duoClosedBringsTheKeyboardUpByItself() {
        #expect(closed().keyboardIsAutomatic)
        #expect(!closed { $0.softKeyboard = false }.keyboardIsAutomatic, "not with a hardware keyboard")
    }

    @Test func duoClosedLandscapeFillsTheWindowWithTheButtonFloating() {
        // As measured on the phone: the camera in the bottom right corner, where a thumb patch would be.
        let l = StreamLayout(input(678, 466, aspect: duoAspect) {
            $0.isCompact = true
            $0.safeArea = .init(bottom: 34, right: 84)
            $0.occlusions = [CGRect(x: 611.67, y: 399.67, width: 37, height: 37), CGRect(x: 594, y: 384, width: 84, height: 82)]
        })
        #expect(!l.isRemote && l.controls == nil)
        #expect(l.stream == CGRect(x: 0, y: 0, width: 678, height: 466))
        #expect(l.edgeButton == CGPoint(x: 644, y: 233))
        // The right patch sits above the camera.
        #expect(l.cornerPads == [CGRect(x: 14, y: 322, width: 124, height: 100), CGRect(x: 540, y: 276, width: 124, height: 100)])
    }

    @Test func aPhoneWithoutASideStripFloatsTheMicrophoneButton() {
        let l = StreamLayout(input(874, 402, aspect: duoAspect) { $0.isCompact = true; $0.safeArea = .init(left: 59, right: 59) })
        #expect(l.controls == nil && l.stream.width == 874 && l.edgeButton == CGPoint(x: 781, y: 201))
    }

    // MARK: iPhone Duo, open, beside another app (Split View)

    @Test func besideAnotherAppTheStreamTakesNearlyAllOfTheHalf() throws {
        // Half of the inner display, as measured from a screenshot: about 469 × 669, compact, no side strip.
        let l = StreamLayout(input(469, 669, aspect: duoAspect) { $0.isCompact = true; $0.sharesScreen = true; $0.safeArea = .init(bottom: 21) })
        #expect(l.isRemote && l.isShared && l.fillsStream && !l.keyboardIsAutomatic && l.controls == nil)
        // A portrait's shape, which the view fills; under it one thin row, Esc and Paste beside a trackpad strip;
        // the microphone button floats over the picture's bottom corner.
        #expect(l.stream == CGRect(x: 0, y: 0, width: 469, height: 568))
        #expect(l.band == CGRect(x: 8, y: 576, width: 453, height: 64) && l.bandHasKeys && l.keysBesideStrip)
        #expect(l.edgeButton == CGPoint(x: 435, y: 534))
        // On the screen's left side everything is mirrored: the thumb is at the other edge.
        let left = StreamLayout(input(469, 669, aspect: duoAspect) {
            $0.isCompact = true; $0.sharesScreen = true; $0.isOnLeftOfScreen = true; $0.safeArea = .init(bottom: 21)
        })
        #expect(left.edgeButton == CGPoint(x: 34, y: 534) && left.keysOnRight && !l.keysOnRight && left.stream == l.stream)
        // Asked for, the keyboard gets the bottom and the whole picture the top, as on the front screen.
        let typing = StreamLayout(input(469, 669, aspect: duoAspect) { $0.isCompact = true; $0.sharesScreen = true; $0.keyboardInset = 313 })
        #expect(typing.stream == CGRect(x: 16, y: 0, width: 438, height: 308) && typing.band?.height == 40 && !typing.fillsStream && !typing.isShared)
        // The front screen is not shared: it keeps its own form.
        #expect(!closed().isShared && !closed().fillsStream)
    }

    // MARK: An ordinary iPhone

    @Test func aPhoneWithoutASideStripHasItsControlsInARow() throws {
        let l = StreamLayout(input(402, 874, aspect: duoAspect) { $0.isCompact = true; $0.safeArea = .init(top: 62, bottom: 34) })
        #expect(l.isRemote)
        #expect(l.stream == CGRect(x: 0, y: 62, width: 402, height: 283))
        #expect(l.controls == StreamLayout.Controls(frame: CGRect(x: 0, y: 345, width: 402, height: 56), isVertical: false))
        #expect(try #require(l.band).minY == 401)
    }

    @Test func beforeTheStreamsShapeIsKnownTheRemoteStillLaysOut() {
        let l = closed { $0.streamAspect = 0 }
        #expect(l.stream.width == 382 && l.stream.height == 269)
    }
}
