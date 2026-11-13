import CoreVideo
import Dispatch
import LainTelemetry
import Synchronization

/// Whether what the view shows is changing: for the deck (the Duo folded like a laptop and set down), so that
/// the phone can tell its owner when something long-running (an agent at work) has gone quiet, likely waiting
/// for them. Pure: fed a grid of the shown part's brightness (`ActivityWatch` makes it from the decoded
/// frames) and the time.
///
/// - A cell **changes** when its mean brightness moves by more than `changeThreshold`. A cell that changes back
///   to the value it had before its last change is a toggle (a blinking text cursor), and doesn't count.
/// - **Working**: changes have kept coming (no gap of `quietAfterNs`) for `armAfterNs`.
/// - **Went quiet**: working, then nothing for `quietAfterNs`: `Event.wentQuiet`, once; `phase` is `.quiet`
///   until something changes again or the owner acts.
/// - The owner's own input moves things (a scroll, a click): changes within `inputGraceNs` of it don't count,
///   and acting ends working or quiet (they are looking).
/// - The shown part moving (the view followed the pointer, a pinch) starts the comparison again.
///
/// - The link going down (the session closed) freezes the picture, which would look like going quiet: while
///   it is down the detector is paused (no time passes for it, so it can't alert). Back up, it compares the
///   new picture with the last one from before, and quiet is counted from the moment it came back: work that
///   carried on shows as a change; work that ended during the drop alerts once the link has been back
///   `quietAfterNs`.
///
/// The host's mouse pointer is drawn by the client (never in the video), so it is never activity.
public struct ActivityDetector: Sendable {
    public struct Options: Sendable {
        /// Mean brightness (0–255) a cell must move by. Cells are about a character of terminal text, where a
        /// digit or a spinner's glyph changing moves the mean by 10 or more; the host's refinement of a still
        /// frame (a sharper copy) moves it by 1–2.
        public var changeThreshold: Float = 4
        /// Cells that must change in one sample for it to count.
        public var minChangedCells = 1
        public var armAfterNs: UInt64 = 2_000_000_000
        public var quietAfterNs: UInt64 = 4_000_000_000
        public var inputGraceNs: UInt64 = 1_500_000_000
        public init() {}
    }

    public enum Phase: Sendable, Equatable {
        /// Nothing going on worth watching.
        case still
        /// Changes have kept coming for a while.
        case working
        /// It was working and stopped (the alert went off); until a change or the owner acts.
        case quiet
    }

    public enum Event: Sendable, Equatable { case wentQuiet }

    public var options: Options
    public private(set) var phase = Phase.still
    /// The last sample's changed cells, not counting toggles (for the console while tuning).
    public private(set) var lastChangedCells = 0

    private var current: [Float] = []
    /// Each cell's value before its last change (NaN: none yet), to know a toggle.
    private var before: [Float] = []
    private var region: Viewport?
    /// When the current run of changes started, and the last change in it.
    private var runStartNs: UInt64?
    private var lastChangeNs: UInt64 = 0
    private var lastInputNs: UInt64?
    /// The link is down: nothing counts, and no time passes.
    public private(set) var isPaused = false

    public init(options: Options = Options()) { self.options = options }

    /// A grid of the shown part's mean brightness (row-major, 0–255) at `now`.
    public mutating func sample(_ grid: [Float], region: Viewport, at now: UInt64) -> Event? {
        guard !isPaused else { return nil }
        guard grid.count == current.count, region == self.region else {
            current = grid
            before = Array(repeating: .nan, count: grid.count)
            self.region = region
            lastChangedCells = 0
            return tick(at: now)
        }
        let t = options.changeThreshold
        var changed = 0
        for i in grid.indices where abs(grid[i] - current[i]) > t {
            let toggle = !before[i].isNaN && abs(grid[i] - before[i]) <= t
            before[i] = current[i]
            current[i] = grid[i]
            if !toggle { changed += 1 }
        }
        lastChangedCells = changed
        if let input = lastInputNs, now &- input < options.inputGraceNs { return nil }
        guard changed >= options.minChangedCells else { return tick(at: now) }
        if runStartNs == nil || now &- lastChangeNs >= options.quietAfterNs { runStartNs = now }
        lastChangeNs = now
        if phase == .quiet { phase = .still }
        if let start = runStartNs, now &- start >= options.armAfterNs { phase = .working }
        return nil
    }

    /// The time passing with no sample (a still screen sends no frames).
    public mutating func tick(at now: UInt64) -> Event? {
        guard !isPaused, phase == .working, now &- lastChangeNs >= options.quietAfterNs else { return nil }
        phase = .quiet
        runStartNs = nil
        return .wentQuiet
    }

    /// The link went down (true) or came back (false). Back, quiet counts from now, and the run of changes
    /// that armed it goes on (a drop isn't a gap in the work).
    public mutating func setPaused(_ paused: Bool, at now: UInt64) {
        guard paused != isPaused else { return }
        isPaused = paused
        if !paused { lastChangeNs = now }
    }

    /// The owner touched, typed or dictated.
    public mutating func noteInput(at now: UInt64) {
        lastInputNs = now
        runStartNs = nil
        phase = .still
    }

    /// The mean brightness of a `columns` × `rows` grid over `region` of a decoded frame's luma plane (8- or
    /// 16-bit, biplanar), 0–255. Every pixel: a cell is about a character, and a glyph's thin stroke may be one
    /// row of pixels. Empty where the frame isn't biplanar or the region is smaller than the grid.
    public static func lumaGrid(_ image: CVPixelBuffer, region: Viewport, columns: Int, rows: Int) -> [Float] {
        guard CVPixelBufferGetPlaneCount(image) >= 1, columns > 0, rows > 0 else { return [] }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return [] }
        let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let sixteen = Self.isSixteenBit(image)
        let x0 = max(Int((region.x * Double(width)).rounded()), 0), y0 = max(Int((region.y * Double(height)).rounded()), 0)
        let w = min(Int((region.width * Double(width)).rounded()), width - x0)
        let h = min(Int((region.height * Double(height)).rounded()), height - y0)
        guard w >= columns, h >= rows else { return [] }
        let columnOf = (0..<w).map { $0 * columns / w }
        var perColumn = [UInt32](repeating: 0, count: columns)
        for c in columnOf { perColumn[c] += 1 }
        var sums = [UInt64](repeating: 0, count: columns * rows), counts = [UInt32](repeating: 0, count: columns * rows)
        sums.withUnsafeMutableBufferPointer { sums in
            columnOf.withUnsafeBufferPointer { columnOf in
                for y in 0..<h {
                    let cellRow = y * rows / h * columns
                    let row = base.advanced(by: (y0 + y) * stride)
                    if sixteen {
                        let p = row.assumingMemoryBound(to: UInt16.self).advanced(by: x0)
                        for x in 0..<w { sums[cellRow &+ columnOf[x]] &+= UInt64(p[x] >> 8) }
                    } else {
                        let p = row.assumingMemoryBound(to: UInt8.self).advanced(by: x0)
                        for x in 0..<w { sums[cellRow &+ columnOf[x]] &+= UInt64(p[x]) }
                    }
                    for c in 0..<columns { counts[cellRow + c] &+= perColumn[c] }
                }
            }
        }
        return zip(sums, counts).map { $1 > 0 ? Float($0) / Float($1) : 0 }
    }

    private static func isSixteenBit(_ image: CVPixelBuffer) -> Bool {
        switch CVPixelBufferGetPixelFormatType(image) {
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
            true
        default:
            false
        }
    }
}

/// The detector on the decoded frames: off until the deck turns it on. The decoder's thread offers each frame,
/// after it has gone to the renderer; at most four a second are measured, on a queue of their own (reading
/// every pixel takes milliseconds, which the decoder must not wait for). The main thread ticks it and takes
/// the phase and any event.
public final class ActivityWatch: Sendable {
    /// About 8 points a cell over a whole Mac display: a character of terminal text. Coarser cells miss what an
    /// agent shows while it thinks (a spinner's glyph, a timer's seconds), which is one character each.
    public static let columns = 192, rows = 128
    public static let sampleIntervalNs: UInt64 = 250_000_000

    private struct State {
        var enabled = false
        var region = Viewport.full
        var detector = ActivityDetector()
        var lastSampleNs: UInt64 = 0
        var measuring = false
        var pending: ActivityDetector.Event?
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "lain.activity", qos: .utility)

    public init() {}

    /// On: from nothing (what was seen before doesn't count). Off: stops measuring.
    public func setEnabled(_ on: Bool) {
        state.withLock { s in
            guard s.enabled != on else { return }
            s.enabled = on
            let paused = s.detector.isPaused
            s.detector = ActivityDetector(options: s.detector.options)
            s.detector.setPaused(paused, at: MonotonicClock.now())
            s.pending = nil
        }
    }

    /// The part of the display the view shows.
    public func setRegion(_ region: Viewport) { state.withLock { $0.region = region } }

    /// The link is down (the session closed): the picture is frozen, which isn't going quiet.
    public func setLinkDown(_ down: Bool) {
        let now = MonotonicClock.now()
        state.withLock { $0.detector.setPaused(down, at: now) }
    }

    public func noteInput() {
        let now = MonotonicClock.now()
        state.withLock { $0.detector.noteInput(at: now) }
    }

    /// The decoder's thread, with each decoded frame.
    public func offer(_ image: CVPixelBuffer) {
        let now = MonotonicClock.now()
        let region: Viewport? = state.withLock { s in
            guard s.enabled, !s.measuring, now &- s.lastSampleNs >= Self.sampleIntervalNs else { return nil }
            s.measuring = true
            s.lastSampleNs = now
            return s.region
        }
        guard let region else { return }
        let frame = UncheckedFrame(image: image)
        queue.async { [self] in
            let grid = ActivityDetector.lumaGrid(frame.image, region: region, columns: Self.columns, rows: Self.rows)
            state.withLock { s in
                s.measuring = false
                guard s.enabled, !grid.isEmpty, let event = s.detector.sample(grid, region: region, at: now) else { return }
                s.pending = event
            }
        }
    }

    /// A decoded frame is only read once decoded (VideoToolbox doesn't write it again while it is held).
    private struct UncheckedFrame: @unchecked Sendable { let image: CVPixelBuffer }

    /// The main thread, regularly: the phase now, an event since the last call, and the last sample's changed
    /// cells.
    public func tick() -> (phase: ActivityDetector.Phase, event: ActivityDetector.Event?, changedCells: Int) {
        let now = MonotonicClock.now()
        return state.withLock { s in
            let event = s.pending ?? (s.enabled ? s.detector.tick(at: now) : nil)
            s.pending = nil
            return (s.detector.phase, event, s.detector.lastChangedCells)
        }
    }
}
