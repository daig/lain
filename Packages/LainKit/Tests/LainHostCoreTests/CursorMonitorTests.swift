import LainProtocol
import Synchronization
import Testing
@testable import LainHostCore

private func image(_ fill: UInt8, hotspot: Float = 1) -> CursorImage {
    CursorImage(pixelWidth: 4, pixelHeight: 4, scale: 2, hotspotX: hotspot, hotspotY: hotspot,
                pixels: [UInt8](repeating: fill, count: 64))
}

private func describe(_ messages: [Message]) -> [String] {
    messages.map {
        switch $0 {
        case .cursorShape(let s): "shape \(s.shapeId)"
        case .cursorSelect(let s): "select \(s.shapeId)\(s.visible ? "" : " hidden")"
        default: "other"
        }
    }
}

@Suite struct CursorShapeTrackerTests {
    @Test func sendsEachShapeOnceAndSelectsOnChange() {
        var t = CursorShapeTracker()
        let arrow = image(10), beam = image(20)
        #expect(describe(t.update(arrow)) == ["shape 1", "select 1"])
        #expect(t.update(arrow).isEmpty)                                    // unchanged: nothing
        #expect(describe(t.update(beam)) == ["shape 2", "select 2"])
        #expect(describe(t.update(arrow)) == ["select 1"])                  // known shape: select only
        #expect(describe(t.update(image(10))) == [])                        // equal content, new instance
        #expect(describe(t.update(image(10, hotspot: 3))) == ["shape 3", "select 3"])   // hotspot is part of the shape
        #expect(t.uniqueShapes == 3)
    }

    @Test func pastTheLiveWindowShapesAreResentUnderNewIds() {
        var t = CursorShapeTracker()
        for i in 0..<CursorShape.maxLive { _ = t.update(image(UInt8(i))) }          // ids 1...64
        #expect(describe(t.update(image(0))) == ["select 1"])
        #expect(describe(t.update(image(200))) == ["shape 65", "select 65"])       // the table starts over
        #expect(t.uniqueShapes == 1)
        #expect(describe(t.update(image(0))) == ["shape 66", "select 66"])         // resent, not just selected
    }

    @Test func hiddenKeepsTheShapeAndShowsAgain() {
        var t = CursorShapeTracker()
        #expect(t.update(nil).isEmpty)                                      // nothing shown yet: nothing to hide
        _ = t.update(image(1))
        #expect(describe(t.update(nil)) == ["select 1 hidden"])
        #expect(t.update(nil).isEmpty)
        #expect(describe(t.update(image(1))) == ["select 1"])
        #expect(describe(t.update(nil)) == ["select 1 hidden"])
        #expect(describe(t.update(image(2))) == ["shape 2", "select 2"])
    }

    @Test func shapeCarriesPixelsAndHotspot() throws {
        var t = CursorShapeTracker()
        let img = CursorImage(pixelWidth: 2, pixelHeight: 3, scale: 2, hotspotX: 0.5, hotspotY: 1.5,
                              pixels: Array(0..<24).map(UInt8.init))
        guard case .cursorShape(let s)? = t.update(img).first else { Issue.record("no shape"); return }
        #expect(s.pixelWidth == 2 && s.pixelHeight == 3 && s.scale == 2)
        #expect(s.hotspotX == 0.5 && s.hotspotY == 1.5)
        #expect(s.pixels == img.pixels)
        // And it survives the wire.
        let bytes = MessageCodec.encode(.cursorShape(s), sequence: 0, timestampNs: 0)
        var parser = FrameParser()
        parser.append(bytes)
        #expect(try parser.next()?.message == .cursorShape(s))
    }
}

final class SequenceCursor: CursorImageSource {
    let images: Mutex<[CursorImage?]>
    init(_ images: [CursorImage?]) { self.images = Mutex(images) }
    func currentCursor() -> CursorImage? {
        images.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? nil }
    }
}

@Suite struct CursorMonitorTests {
    @Test func samplesSendThroughTheClosureAndStopSilences() {
        let sent = Mutex<[Message]>([])
        let source = SequenceCursor([image(1), image(1), image(2), nil, image(2)])
        let monitor = CursorMonitor(source: source) { m in sent.withLock { $0.append(m) } }
        for _ in 0..<5 { monitor.sampleNow() }
        #expect(describe(sent.withLock { $0 }) == ["shape 1", "select 1", "shape 2", "select 2", "select 2 hidden", "select 2"])
        monitor.stop()
        monitor.stop()
        let count = sent.withLock { $0.count }
        monitor.sampleNow()
        #expect(sent.withLock { $0.count } == count)
    }

    @Test func timerSamples() async throws {
        let sent = Mutex<[Message]>([])
        let monitor = CursorMonitor(source: SequenceCursor([image(1)])) { m in sent.withLock { $0.append(m) } }
        monitor.start(hz: 200)
        try await Task.sleep(for: .milliseconds(100))
        monitor.stop()
        #expect(describe(sent.withLock { $0 }) == ["shape 1", "select 1"])
    }
}

#if os(macOS)
import AppKit

@Suite struct SystemCursorRenderTests {
    @Test func rendersAt2xPremultipliedBGRATopDown() throws {
        // 8×8 pt: top half opaque red, bottom half transparent.
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: true) { _ in
            NSColor.red.setFill()
            NSRect(x: 0, y: 0, width: 8, height: 4).fill()
            return true
        }
        let r = try #require(SystemCursorSource.render(img, hotspot: CGPoint(x: 3, y: 5), scale: 2))
        #expect(r.pixelWidth == 16 && r.pixelHeight == 16 && r.scale == 2)
        #expect(r.hotspotX == 3 && r.hotspotY == 5)
        func px(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let i = (y * 16 + x) * 4
            return (r.pixels[i], r.pixels[i + 1], r.pixels[i + 2], r.pixels[i + 3])
        }
        let top = px(8, 2), bottom = px(8, 13)
        #expect(top.a == 255 && top.r > 200 && top.g < 100 && top.b < 100)   // red, in P3 (row 0 = top)
        #expect(bottom.a == 0 && bottom.r == 0)                               // premultiplied transparent
    }
}
#endif
