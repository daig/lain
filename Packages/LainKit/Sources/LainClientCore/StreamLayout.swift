import CoreGraphics

/// Where the client's one screen puts the stream and its touch controls, from the window's size alone (never
/// the device's kind): an iPad, an iPhone Duo open, half folded or closed, a Split View half. Pure: the stream
/// view measures the window and applies the frames.
///
/// Three forms:
/// - **landscape** (wider than tall): the stream fills the window, on a phone too; a trackpad patch sits in each
///   bottom corner and a microphone button floats at the right edge (its menu has the rest).
/// - **portrait** (taller than wide): the stream at the top at its own shape, and under it the band (more keys
///   and a trackpad strip) above the system keyboard, which is always up. Half folded like a laptop (set down,
///   to watch something long-running), the stream fills the half above the fold and the half below is the
///   `deck`: no keyboard, but dictation, keys that answer a prompt, and a large trackpad.
/// - **remote** (portrait and compact width: a phone's screen, the Duo closed): with the system keyboard up,
///   as it is whenever the host takes typing, the stream across the top and the keyboard at the bottom, with a
///   small trackpad between or over the picture's corners. Without the keyboard, the stream over a large
///   trackpad, with lain's controls in a strip: down the camera's side where the system
///   keeps one clear (the Duo's outer display), else in a row under the stream. The keyboard comes on request.
public struct StreamLayout: Sendable, Equatable {
    public struct Insets: Sendable, Equatable {
        public var top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat
        public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
            self.top = top; self.left = left; self.bottom = bottom; self.right = right
        }
    }

    public struct Input: Sendable, Equatable {
        /// The window (the stream view's bounds), in points.
        public var size: CGSize
        public var safeArea = Insets()
        /// How much of the bottom the docked system keyboard covers (with the row of keys above it, if shown).
        public var keyboardInset: CGFloat = 0
        /// How much of `keyboardInset` is the row of keys above the keyboard (0 when it isn't shown).
        public var keyRowHeight: CGFloat = 0
        /// The streamed display's width over its height; 0 until known.
        public var streamAspect: CGFloat = 0
        /// No hardware keyboard: the system keyboard, the key rows and the microphone button are lain's.
        public var softKeyboard = true
        /// No trackpad or mouse: the trackpad areas show.
        public var touchPointer = true
        /// Compact width (a phone-size window).
        public var isCompact = false
        /// The window is narrower than its screen: it shares it with another app (Split View on the Duo's inner
        /// display). The system keyboard then spans both apps and belongs to whichever is typed in, so lain
        /// brings it up only on request.
        public var sharesScreen = false
        /// Sharing the screen, the window is on its left side: the screen's outer edge, where the hand holding
        /// that side is, is the window's left one.
        public var isOnLeftOfScreen = false
        /// The fold, while the device is partly folded (the active division region), in the view's points.
        public var fold: CGRect?
        /// What covers the screen (the camera, the Dynamic Island), in the view's points.
        public var occlusions: [CGRect] = []

        public init(size: CGSize) { self.size = size }
    }

    /// lain's controls in the remote form.
    public struct Controls: Sendable, Equatable {
        public var frame: CGRect
        /// A column down the screen's side; else a row.
        public var isVertical: Bool
        public init(frame: CGRect, isVertical: Bool) {
            self.frame = frame
            self.isVertical = isVertical
        }
    }

    public var isPortrait = false
    public var isRemote = false
    /// The remote beside another app, the keyboard down: its own row of keys, and a view that fills the stream.
    public var isShared = false
    /// The view shows as much of the display as fills the stream's area (zoomed in), not all of it with bars,
    /// until a pinch says otherwise.
    public var fillsStream = false
    /// The stream's layer. In landscape the renderer fits the picture in it; in the other forms it has the
    /// picture's shape.
    public var stream = CGRect.zero
    /// Portrait and remote: the keys and the trackpad strip.
    public var band: CGRect?
    /// The band has room for its row of keys above the strip.
    public var bandHasKeys = false
    /// The band's keys are at the strip's left, in the same row, not above it.
    public var keysBesideStrip = false
    /// With `keysBesideStrip`: the keys are at the strip's right (a window on the screen's left side).
    public var keysOnRight = false
    /// The strip's row ends in a ribbon to scroll with, at its right, or with `ribbonOnLeft` at its left.
    public var stripHasRibbon = false
    public var ribbonOnLeft = false
    /// Landscape: the thumbs' trackpad patches.
    public var cornerPads: [CGRect] = []
    /// Remote: the strip of controls.
    public var controls: Controls?
    /// Landscape in a short window with the keyboard up: the keyboard's row of keys moves beside the stream,
    /// which gets the row's height. Two areas for the keys, left and right of the stream; the trackpad patches
    /// (`cornerPads`) are under them.
    public var sideKeys: [CGRect] = []
    /// Landscape, and beside another app: the centre of the microphone button.
    public var edgeButton: CGPoint?
    /// The system keyboard is up by itself (portrait, not the remote).
    public var keyboardIsAutomatic = false
    /// Where the dictation transcript is centred: clear of a vertical fold.
    public var transcriptCenterX: CGFloat = 0

    /// Half folded like a laptop (the fold across an upright window) and set down: the lower half is a deck for
    /// watching something long-running (an agent at work) with the hands off. Typing on a half that lies flat
    /// is no good (no thumbs, one finger), so there is no keyboard: dictation, a row of keys that answer a
    /// prompt, and a large trackpad that acts as a Magic Trackpad does (two fingers scroll, a pinch zooms the
    /// picture above). Frames in the view's points.
    public struct Deck: Sendable, Equatable {
        /// All of it, under the fold.
        public var frame: CGRect
        /// The row of keys, along the fold (where a laptop's function row is).
        public var keys: CGRect
        public var trackpad: CGRect
        /// The microphone, large, at the front corner, under the hand.
        public var mic: CGRect
        /// The settings, small, above the microphone.
        public var settings: CGRect
    }
    public var deck: Deck?

    /// A side strip the system keeps clear of content (the Duo's outer display: 84 points beside the camera).
    static let sideStrip: CGFloat = 60
    static let controlRow: CGFloat = 56
    static let bandMinHeight: CGFloat = 110
    /// The row of keys (38) and its gap (8), plus a strip worth having under them.
    static let bandKeysMinHeight: CGFloat = 150
    /// Side keys: only where height is scarce (a phone's screens; an iPad keeps its row), and only beside a
    /// stream that leaves this much at each side.
    static let sideKeysMaxHeight: CGFloat = 800
    static let sideKeysMinGutter: CGFloat = 120
    /// Three rows of keys.
    static let sideKeysHeight: CGFloat = 132
    /// The remote's stream takes at most this much of the height: the trackpad is the point.
    static let remoteStreamShare: CGFloat = 0.45
    /// Sharing the screen: one thin row, the keys and a trackpad strip.
    static let sharedStripHeight: CGFloat = 64
    /// The remote with the keyboard up: the trackpad strip between the picture and the keyboard is at least
    /// this tall.
    static let remoteStripMinHeight: CGFloat = 40
    /// Upright on a larger screen, where the band doesn't fit: the strip that replaces it is at least this tall.
    static let portraitStripMinHeight: CGFloat = 48
    /// Before the stream's shape is known.
    static let assumedAspect: CGFloat = 1.42
    /// The deck: its row of keys, the microphone's column, and the least height it needs (else the band).
    static let deckKeysHeight: CGFloat = 48
    static let deckMicWidth: CGFloat = 112
    static let deckSettingsHeight: CGFloat = 44
    static let deckMinHeight: CGFloat = 200

    public init() {}

    public init(_ i: Input) {
        let w = i.size.width, h = i.size.height
        isPortrait = h > w
        let bottom = h - max(i.keyboardInset, i.safeArea.bottom)
        transcriptCenterX = w / 2
        if isPortrait, i.isCompact {
            remote(i, bottom: bottom)
        } else if isPortrait {
            portrait(i, bottom: bottom)
        } else {
            landscape(i)
        }
    }

    /// The remote with the system keyboard up, which is how it is used (the keyboard comes up by itself): the
    /// picture across the whole width at the top (under the camera, which covers a little of one corner), the
    /// keyboard with its row of keys at the bottom, and between them a trackpad strip. The strip is thin,
    /// because a finger that starts on it keeps moving the pointer wherever it goes; it takes what the picture
    /// leaves above the keyboard, and where that is less than a finger needs, the picture gives up the rest.
    private mutating func remoteWithKeyboard(_ i: Input) {
        let w = i.size.width, room = max(i.size.height - i.keyboardInset, 1), gap: CGFloat = 4
        let aspect = i.streamAspect > 0 ? i.streamAspect : Self.assumedAspect
        // With a trackpad, the picture leaves at least the least strip and its gaps.
        let tallest = i.touchPointer ? max(room - Self.remoteStripMinHeight - 2 * gap, 1) : room
        let width = min(w, (tallest * aspect).rounded())
        stream = CGRect(x: ((w - width) / 2).rounded(), y: 0, width: width, height: min((width / aspect).rounded(), tallest))
        transcriptCenterX = w / 2
        if i.touchPointer {
            band = CGRect(x: 8, y: stream.maxY + gap, width: w - 16, height: room - stream.maxY - 2 * gap)
            // A ribbon to scroll with at the strip's outer end, under the thumb: the right, unless the window
            // is on the left side of a shared screen.
            stripHasRibbon = true
            ribbonOnLeft = i.sharesScreen && i.isOnLeftOfScreen
        }
    }

    /// Beside another app (Split View), the keyboard down: the window is a portrait's shape and the desktop a
    /// landscape's, so the stream's area takes nearly all of it and the view fills it (`fillsStream`): the
    /// desktop's whole height shows, and as much of its width as fits, following the pointer; a pinch out shows
    /// all of it. The controls take as little as they can: the microphone button floats over the picture's
    /// bottom corner, as in landscape (its menu has the keyboard and the settings), and under the picture is
    /// one thin row: Esc and Paste beside a trackpad strip, which is enough, since a finger that starts on it
    /// keeps the pointer wherever it goes.
    private mutating func shared(_ i: Input, bottom: CGFloat) {
        let x = i.safeArea.left, width = i.size.width - i.safeArea.left - i.safeArea.right, gap: CGFloat = 8
        isShared = true
        fillsStream = true
        stream = CGRect(x: x, y: i.safeArea.top, width: width, height: max(bottom - i.safeArea.top - Self.sharedStripHeight - 2 * gap, 1))
        band = CGRect(x: x + 8, y: stream.maxY + gap, width: width - 16, height: Self.sharedStripHeight)
        bandHasKeys = true
        keysBesideStrip = true
        // The thumb is at the screen's outer edge: the microphone button and the trackpad strip are on that
        // side, the keys towards the middle of the screen.
        keysOnRight = i.isOnLeftOfScreen
        stripHasRibbon = true
        ribbonOnLeft = i.isOnLeftOfScreen
        if i.softKeyboard { edgeButton = CGPoint(x: i.isOnLeftOfScreen ? stream.minX + 34 : stream.maxX - 34, y: stream.maxY - 34) }
        transcriptCenterX = x + width / 2
    }

    private mutating func remote(_ i: Input, bottom: CGFloat) {
        let w = i.size.width, h = i.size.height
        isRemote = true
        keyboardIsAutomatic = i.softKeyboard && !i.sharesScreen
        if i.softKeyboard, i.keyboardInset > 0 { return remoteWithKeyboard(i) }
        if i.sharesScreen { return shared(i, bottom: bottom) }
        var column = CGRect(x: i.safeArea.left, y: i.safeArea.top, width: w - i.safeArea.left - i.safeArea.right,
                            height: h - i.safeArea.top - i.safeArea.bottom)
        if let strip = Self.strip(i, bottom: bottom) {
            // The strip's side is outside the safe area, and what covers the top is only at its side.
            column.origin.y = 0
            column.size.height = h - i.safeArea.bottom
            controls = Controls(frame: strip, isVertical: true)
        }
        let aspect = i.streamAspect > 0 ? i.streamAspect : Self.assumedAspect
        var size = CGSize(width: column.width, height: (column.width / aspect).rounded())
        let tallest = (column.height * Self.remoteStreamShare).rounded()
        if size.height > tallest { size = CGSize(width: (tallest * aspect).rounded(), height: tallest) }
        stream = CGRect(x: (column.minX + (column.width - size.width) / 2).rounded(), y: column.minY, width: size.width, height: size.height)
        var top = stream.maxY + 8
        if controls == nil {
            controls = Controls(frame: CGRect(x: column.minX, y: stream.maxY, width: column.width, height: Self.controlRow), isVertical: false)
            top = stream.maxY + Self.controlRow
        }
        let frame = CGRect(x: column.minX + 8, y: top, width: column.width - 16, height: bottom - top - 8)
        if i.touchPointer, frame.height >= Self.bandMinHeight {
            band = frame
            bandHasKeys = frame.height >= Self.bandKeysMinHeight
        }
        transcriptCenterX = column.midX
    }

    /// The side strip the system keeps clear of content (the Duo's outer display, beside the camera), less what
    /// covers its ends (the camera) and what is under `bottom` (the keyboard); nil where there is none.
    private static func strip(_ i: Input, bottom: CGFloat) -> CGRect? {
        let x: CGFloat, width: CGFloat
        if i.safeArea.right >= sideStrip {
            (x, width) = (i.size.width - i.safeArea.right, i.safeArea.right)
        } else if i.safeArea.left >= sideStrip {
            (x, width) = (0, i.safeArea.left)
        } else {
            return nil
        }
        let whole = CGRect(x: x, y: 0, width: width, height: i.size.height)
        let covering = i.occlusions.filter { $0.intersects(whole) }
        var top = covering.isEmpty ? i.safeArea.top : 0, end = bottom
        for c in covering {
            if c.midY < whole.midY { top = max(top, c.maxY) } else { end = min(end, c.minY) }
        }
        return CGRect(x: x, y: top, width: width, height: max(end - top, 0))
    }

    /// Folded like a laptop: the picture fills the half above the fold (zoomed in, `fillsStream`, where its shape
    /// differs), and the deck takes the half below. The keyboard isn't part of it, so its inset is ignored (one
    /// left up from before the fold goes away). False, with nothing changed, where the half below is too small.
    private mutating func deckLayout(_ i: Input, fold: CGRect) -> Bool {
        let w = i.size.width, gap: CGFloat = 8
        let left = i.safeArea.left + gap, right = w - i.safeArea.right - gap
        let top = fold.maxY + gap, bottom = i.size.height - i.safeArea.bottom - gap
        guard bottom - top >= Self.deckMinHeight, right - left >= 2 * Self.deckMicWidth else { return false }
        let frame = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let keys = CGRect(x: left, y: top, width: frame.width, height: Self.deckKeysHeight)
        let below = keys.maxY + gap
        let column = right - Self.deckMicWidth
        let settings = CGRect(x: column, y: below, width: Self.deckMicWidth, height: Self.deckSettingsHeight)
        deck = Deck(frame: frame, keys: keys,
                    trackpad: CGRect(x: left, y: below, width: column - gap - left, height: bottom - below),
                    mic: CGRect(x: column, y: settings.maxY + gap, width: Self.deckMicWidth, height: bottom - settings.maxY - gap),
                    settings: settings)
        stream = CGRect(x: i.safeArea.left, y: 0, width: w - i.safeArea.left - i.safeArea.right, height: max(fold.minY, 1))
        fillsStream = true
        transcriptCenterX = frame.midX
        return true
    }

    private mutating func portrait(_ i: Input, bottom: CGFloat) {
        let w = i.size.width, h = i.size.height
        if let fold = i.fold, fold.width > fold.height, !i.sharesScreen, i.softKeyboard || i.touchPointer,
           deckLayout(i, fold: fold) { return }
        keyboardIsAutomatic = i.softKeyboard && !i.sharesScreen
        // What the docked keyboard leaves; at the top at the stream's own shape, which leaves the band.
        var area = CGRect(x: 0, y: 0, width: w, height: max(h - i.keyboardInset, 1))
        let fold = i.fold.flatMap { $0.width > $0.height ? $0 : nil }   // across: the laptop pose
        if let fold { area.size.height = min(area.height, max(fold.minY, 1)) }
        stream = area
        if i.streamAspect > 0 {
            let width = min(area.width, area.height * i.streamAspect).rounded()
            let height = (width / i.streamAspect).rounded()
            // Above a fold the picture sits in the middle of its half, as a laptop's screen does.
            stream = CGRect(x: ((w - width) / 2).rounded(), y: fold == nil ? 0 : ((area.height - height) / 2).rounded(), width: width, height: height)
        }
        let top = (fold?.maxY ?? stream.maxY) + 8
        let frame = CGRect(x: 8, y: top, width: w - 16, height: bottom - top - 8)
        guard i.streamAspect > 0, i.softKeyboard || i.touchPointer else { return }
        if frame.height >= Self.bandMinHeight {
            band = frame
            bandHasKeys = true
        } else if i.touchPointer {
            // A tall keyboard leaves no room for the band (the Duo's inner display, upright): the pointer still
            // needs a trackpad, so there is a thin strip with a scroll ribbon at its end, as on the front
            // screen, and the picture gives up what the strip lacks.
            let gap: CGFloat = 4
            if fold == nil {
                let tallest = max(bottom - Self.portraitStripMinHeight - 2 * gap, 1)
                if stream.height > tallest {
                    let width = (tallest * i.streamAspect).rounded()
                    stream = CGRect(x: ((w - width) / 2).rounded(), y: 0, width: width, height: tallest)
                }
                band = CGRect(x: 8, y: stream.maxY + gap, width: w - 16, height: bottom - stream.maxY - 2 * gap)
                stripHasRibbon = true
            } else if frame.height >= Self.remoteStripMinHeight {
                band = frame
                stripHasRibbon = true
            }
        }
    }

    /// The keyboard is up in a short landscape window: the picture is as tall as the keyboard allows, which
    /// leaves room at its sides. The row of keys goes there (and gives its height to the picture), with the
    /// trackpad patches under it. False, with nothing changed, where that doesn't fit.
    private mutating func sideKeysLayout(_ i: Input) -> Bool {
        let w = i.size.width, h = i.size.height
        guard i.softKeyboard, i.keyboardInset > 0, i.streamAspect > 0, h < Self.sideKeysMaxHeight else { return false }
        // As it will be once the row is gone (so that showing the side keys doesn't undo itself).
        let room = h - (i.keyboardInset - i.keyRowHeight)
        let width = min(w, (room * i.streamAspect).rounded()), gutter = ((w - width) / 2).rounded(.down)
        guard room > Self.sideKeysHeight + 24, gutter >= Self.sideKeysMinGutter else { return false }
        stream = CGRect(x: gutter, y: 0, width: width, height: (width / i.streamAspect).rounded())
        let margin: CGFloat = 8, keyWidth = gutter - 2 * margin
        sideKeys = [CGRect(x: margin, y: margin, width: keyWidth, height: Self.sideKeysHeight),
                    CGRect(x: w - margin - keyWidth, y: margin, width: keyWidth, height: Self.sideKeysHeight)]
        let padTop = margin + Self.sideKeysHeight + margin, padHeight = room - padTop - margin
        if i.touchPointer, padHeight >= 60 {
            cornerPads = sideKeys.map { CGRect(x: $0.minX, y: padTop, width: keyWidth, height: padHeight) }
        }
        transcriptCenterX = w / 2
        return true
    }

    private mutating func landscape(_ i: Input) {
        let w = i.size.width, h = i.size.height
        // The whole window, on a phone too: the Duo's outer display has nearly the shape of its inner one, which
        // the desktop has, so the picture fills it (under the side the system keeps for its bars, where the
        // camera covers a little of one corner).
        stream = CGRect(x: 0, y: 0, width: w, height: max(h - i.keyboardInset, 1))
        if sideKeysLayout(i) { return }
        if i.softKeyboard {
            // Floats over the picture at the right edge; a wide side strip is the camera's, not a margin to keep.
            let margin = i.safeArea.right >= Self.sideStrip ? 0 : i.safeArea.right
            edgeButton = CGPoint(x: w - margin - 34, y: h / 2)
        }
        if i.touchPointer {
            // Tuned on a 13-inch iPad: where the thumbs rest when it is held by its lower corners, clear of the
            // host's Dock. A short window (a phone's) has smaller ones, lower.
            let small = h < 600
            let size = small ? CGSize(width: 124, height: 100) : CGSize(width: 150, height: 120)
            let inset: CGFloat = small ? 14 : 36, lift: CGFloat = small ? 44 : 104
            let y = h - i.keyboardInset - lift - size.height
            cornerPads = [CGRect(x: stream.minX + inset, y: y, width: size.width, height: size.height),
                          CGRect(x: stream.maxX - inset - size.width, y: y, width: size.width, height: size.height)]
            // A patch the camera would cover sits above it.
            cornerPads = cornerPads.map { pad in
                guard let covered = i.occlusions.filter({ $0.intersects(pad) }).map(\.minY).min() else { return pad }
                return pad.offsetBy(dx: 0, dy: covered - 8 - pad.maxY)
            }
        }
        // Folded like a book: the transcript on the right page, not across the fold.
        if let fold = i.fold, fold.height > fold.width { transcriptCenterX = (fold.maxX + stream.maxX) / 2 } else { transcriptCenterX = stream.midX }
    }
}
