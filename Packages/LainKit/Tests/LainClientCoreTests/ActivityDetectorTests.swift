import CoreVideo
import LainClientCore
import Testing

/// The deck's alert: when what the view shows has been changing and stops.
@Suite struct ActivityDetectorTests {
    private let s: UInt64 = 1_000_000_000
    private let ms: UInt64 = 1_000_000
    private let region = Viewport(x: 0, y: 0, width: 1, height: 1)

    /// A 4 × 2 grid, grey, with `cell` set to `value`.
    private func grid(_ cell: Int = 0, _ value: Float = 100) -> [Float] {
        var g = [Float](repeating: 100, count: 8)
        g[cell] = value
        return g
    }

    /// Samples every 250 ms from `from` until `to` (exclusive), each with something new in cell 1 (text
    /// arriving, a spinner): never the same twice, so never a toggle.
    private func working(_ d: inout ActivityDetector, from: UInt64, to: UInt64) -> [ActivityDetector.Event] {
        var events: [ActivityDetector.Event] = []
        var t = from, n: Float = 0
        while t < to {
            n += 1
            if let e = d.sample(grid(1, 100 + 10 * n), region: region, at: t) { events.append(e) }
            t += 250 * ms
        }
        return events
    }

    @Test func workingThenQuietAlertsOnce() {
        var d = ActivityDetector()
        _ = d.sample(grid(), region: region, at: 0)
        #expect(working(&d, from: 250 * ms, to: 3 * s).isEmpty)
        #expect(d.phase == .working)
        // Still frames (the host's refinements), then none at all: only the clock.
        #expect(d.sample(grid(1, 100 + 10 * 11), region: region, at: 3 * s) == nil)
        #expect(d.tick(at: 5 * s) == nil, "not quiet long enough")
        #expect(d.tick(at: 7 * s) == .wentQuiet)
        #expect(d.phase == .quiet)
        #expect(d.tick(at: 9 * s) == nil, "once")
        // It starts again: quiet ends, and only a new run of work arms it.
        _ = working(&d, from: 10 * s, to: 10 * s + 500 * ms)
        #expect(d.phase == .still)
    }

    @Test func aBlinkingCursorIsNotWork() {
        var d = ActivityDetector()
        _ = d.sample(grid(), region: region, at: 0)
        var t: UInt64 = 500 * ms, on = true
        while t < 20 * s {
            #expect(d.sample(grid(2, on ? 220 : 100), region: region, at: t) == nil)
            on.toggle()
            t += 500 * ms
        }
        #expect(d.phase == .still && d.lastChangedCells == 0)
        #expect(d.tick(at: 30 * s) == nil)
    }

    /// Claude Code thinking: nothing moves but a spinner (cycling through several glyphs) and a timer's seconds,
    /// one character each. That is work, not a wait; a blinking cursor beside it changes nothing.
    @Test func anAgentThinkingIsWorking() {
        var d = ActivityDetector()
        let spinner: [Float] = [120, 160, 140, 180, 150, 130]
        func frame(_ i: Int) -> [Float] {
            var g = [Float](repeating: 100, count: 8)
            g[3] = spinner[i % spinner.count]            // the spinner, a new glyph every sample
            if i % 4 == 0 { g[5] = Float(100 + (i / 4) % 10 * 8) }   // the seconds, once a second
            g[7] = i % 2 == 0 ? 100 : 230                // the text cursor blinking
            return g
        }
        var t: UInt64 = 0
        for i in 0..<240 {   // a minute of thinking
            #expect(d.sample(frame(i), region: region, at: t) == nil)
            t += 250 * ms
        }
        #expect(d.phase == .working)
        // It finishes and waits: only the cursor blinks.
        for i in 0..<40 {
            var g = frame(239)
            g[7] = i % 2 == 0 ? 100 : 230
            if let e = d.sample(g, region: region, at: t) { #expect(e == .wentQuiet) }
            t += 250 * ms
        }
        #expect(d.phase == .quiet)
    }

    /// At the watch's resolution a cell is about a character: one digit of a timer changing is seen.
    @Test func oneCharacterChangingIsSeen() throws {
        // A 1536 × 1024 frame (8 pixels a cell at 192 × 128), black, with a "glyph" in one cell.
        func frame(glyphPixels: Int) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1536, 1024, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
            let image = try #require(buffer)
            CVPixelBufferLockBaseAddress(image, [])
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(image, 0))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            for y in 0..<1024 { memset(base.advanced(by: y * stride), 0, 1536) }
            for p in 0..<glyphPixels { base.storeBytes(of: UInt8(220), toByteOffset: (400 + p / 6) * stride + 800 + p % 6, as: UInt8.self) }
            CVPixelBufferUnlockBaseAddress(image, [])
            return image
        }
        let five = ActivityDetector.lumaGrid(try frame(glyphPixels: 30), region: region, columns: ActivityWatch.columns, rows: ActivityWatch.rows)
        let six = ActivityDetector.lumaGrid(try frame(glyphPixels: 36), region: region, columns: ActivityWatch.columns, rows: ActivityWatch.rows)
        let moved = zip(five, six).map { abs($0 - $1) }
        #expect(moved.filter { $0 > ActivityDetector.Options().changeThreshold }.count >= 1)
    }

    /// The link drops while it works: the frozen picture isn't going quiet. Back, quiet counts from then.
    @Test func aDroppedLinkIsNotGoingQuiet() {
        var d = ActivityDetector()
        _ = d.sample(grid(), region: region, at: 0)
        _ = working(&d, from: 250 * ms, to: 3 * s)
        #expect(d.phase == .working)
        d.setPaused(true, at: 3 * s)
        #expect(d.tick(at: 20 * s) == nil, "down for 17 s: no alert")
        // Back, and the work had ended during the drop: the same picture. Alerts 4 s after the link came back.
        d.setPaused(false, at: 30 * s)
        #expect(d.sample(grid(1, 210), region: region, at: 30 * s + 100 * ms) == nil)
        #expect(d.tick(at: 33 * s) == nil)
        #expect(d.tick(at: 34 * s + 1) == .wentQuiet)
    }

    @Test func workThatCarriedOnThroughADropIsStillWork() {
        var d = ActivityDetector()
        _ = d.sample(grid(), region: region, at: 0)
        _ = working(&d, from: 250 * ms, to: 3 * s)
        d.setPaused(true, at: 3 * s)
        d.setPaused(false, at: 10 * s)
        // The new picture differs, and changes keep coming: no alert.
        var t = 10 * s, n: Float = 0
        while t < 20 * s {
            n += 1
            #expect(d.sample(grid(4, 20 + 5 * n), region: region, at: t) == nil)
            #expect(d.tick(at: t) == nil)
            t += 500 * ms
        }
        #expect(d.phase == .working)
    }

    @Test func aBriefChangeDoesNotArmIt() {
        var d = ActivityDetector()
        _ = d.sample(grid(), region: region, at: 0)
        _ = working(&d, from: 250 * ms, to: 1500 * ms)
        #expect(d.phase == .still)
        #expect(d.tick(at: 10 * s) == nil)
    }

    @Test func theOwnersOwnInputIsNotWorkAndEndsAnAlertOrAWait() {
        var d = ActivityDetector()
        _ = d.sample(grid(), region: region, at: 0)
        // A scroll: the screen changes for a second after the touch.
        d.noteInput(at: 0)
        _ = working(&d, from: 250 * ms, to: 1250 * ms)
        #expect(d.phase == .still && d.tick(at: 10 * s) == nil)
        // Working, and the owner acts: they are looking, so no alert when it stops.
        _ = working(&d, from: 11 * s, to: 14 * s)
        #expect(d.phase == .working)
        d.noteInput(at: 14 * s)
        #expect(d.phase == .still && d.tick(at: 20 * s) == nil)
    }

    @Test func theViewMovingStartsTheComparisonAgain() {
        var d = ActivityDetector()
        _ = d.sample(grid(), region: region, at: 0)
        // Every 250 ms the view follows the pointer somewhere new: all of it changes, none of it is work.
        for i in 1...20 {
            let moved = Viewport(x: Double(i) / 100, y: 0, width: 0.5, height: 0.5)
            _ = d.sample(grid(i % 8, Float(i * 10)), region: moved, at: UInt64(i) * 250 * ms)
            #expect(d.lastChangedCells == 0)
        }
        #expect(d.phase == .still)
    }

    @Test func theGridIsTheShownPartsMeanBrightness() throws {
        // An 8-bit 64 × 32 frame: black on the left half, 200 on the right.
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
        let image = try #require(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(image, 0))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        for y in 0..<32 { for x in 0..<64 { base.storeBytes(of: UInt8(x < 32 ? 0 : 200), toByteOffset: y * stride + x, as: UInt8.self) } }
        CVPixelBufferUnlockBaseAddress(image, [])

        let whole = ActivityDetector.lumaGrid(image, region: region, columns: 4, rows: 2)
        #expect(whole == [0, 0, 200, 200, 0, 0, 200, 200])
        // The right half alone.
        let right = ActivityDetector.lumaGrid(image, region: Viewport(x: 0.5, y: 0, width: 0.5, height: 1), columns: 2, rows: 2)
        #expect(right == [200, 200, 200, 200])
    }
}
