import Dispatch
import LainProtocol
import Synchronization

/// One cursor image as it goes on the wire (§5.4): premultiplied BGRA rendered at `scale`, hotspot in
/// points from the top-left.
public struct CursorImage: Sendable, Hashable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Int
    public var hotspotX: Float
    public var hotspotY: Float
    public var pixels: [UInt8]

    public init(pixelWidth: Int, pixelHeight: Int, scale: Int, hotspotX: Float, hotspotY: Float, pixels: [UInt8]) {
        precondition(pixels.count == pixelWidth * pixelHeight * 4)
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
    }
}

/// Where the monitor reads the Mac's current cursor. Injected so tests don't depend on the real one.
/// Called on the monitor's background queue.
public protocol CursorImageSource: Sendable {
    /// The current system cursor, or nil when there is none (treated as hidden).
    func currentCursor() -> CursorImage?
}

/// The shape bookkeeping, without timers or AppKit: each unique image gets an ID and is sent once as
/// `CursorShape`; `CursorSelect` goes out whenever the current shape or its visibility changes.
public struct CursorShapeTracker: Sendable {
    private var ids: [CursorImage: UInt32] = [:]
    private var nextId: UInt32 = 1
    private var current: (id: UInt32, visible: Bool)?
    /// The last image seen, so an unchanged cursor (the common case at 60 Hz) skips hashing.
    private var last: (image: CursorImage, id: UInt32)?

    public init() {}

    public var uniqueShapes: Int { ids.count }

    /// The messages to send for this sample, in order (a new shape precedes its select).
    public mutating func update(_ image: CursorImage?) -> [Message] {
        guard let image else {
            // Hidden: keep the last shape selected, just invisible.
            guard let c = current, c.visible else { return [] }
            current = (c.id, false)
            return [.cursorSelect(CursorSelect(shapeId: c.id, visible: false))]
        }
        var out: [Message] = []
        let id: UInt32
        if let last, last.image == image {
            id = last.id
        } else if let known = ids[image] {
            id = known
        } else {
            id = nextId
            nextId &+= 1
            ids[image] = id
            out.append(.cursorShape(CursorShape(shapeId: id, pixelWidth: UInt16(clamping: image.pixelWidth),
                                                pixelHeight: UInt16(clamping: image.pixelHeight), scale: UInt8(clamping: image.scale),
                                                hotspotX: image.hotspotX, hotspotY: image.hotspotY, pixels: image.pixels)))
        }
        last = (image, id)
        if current?.id != id || current?.visible != true {
            current = (id, true)
            out.append(.cursorSelect(CursorSelect(shapeId: id, visible: true)))
        }
        return out
    }
}

/// Samples the system cursor at about 60 Hz on a background queue and sends `CursorShape` /
/// `CursorSelect` through `send` (bound to the realtime channel by the session). Nothing here is on a
/// real-time path; the client draws the cursor itself (invariant 1).
///
/// S6: `NSCursor.currentSystem` is verified to return a cursor on macOS 27, but whether it follows other
/// apps' cursors (I-beam in a text view, resize arrows) is **untested until the owner runs it** (M3).
public final class CursorMonitor: Sendable {
    public let source: any CursorImageSource
    private let send: @Sendable (Message) -> Void
    private let queue = DispatchQueue(label: "lain.cursor", qos: .userInitiated)
    private struct State {
        var tracker = CursorShapeTracker()
        var timer: DispatchSourceTimer?
        var stopped = false
    }
    private let state = Mutex(State())

    public init(source: any CursorImageSource, send: @escaping @Sendable (Message) -> Void) {
        self.source = source
        self.send = send
    }

    /// Starts periodic sampling (the first sample is immediate).
    public func start(hz: Double = 60) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Int((1e9 / hz).rounded())
        timer.schedule(deadline: .now(), repeating: .nanoseconds(interval), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sampleNow() }
        let started = state.withLock { s -> Bool in
            guard !s.stopped, s.timer == nil else { return false }
            s.timer = timer
            return true
        }
        if started { timer.resume() }
    }

    /// Samples once and sends whatever changed. Also used by tests.
    public func sampleNow() {
        let image = source.currentCursor()
        let messages = state.withLock { s -> [Message] in s.stopped ? [] : s.tracker.update(image) }
        for m in messages { send(m) }
    }

    /// Idempotent. No message is sent after this returns, except by a `sampleNow` already past its lock.
    public func stop() {
        let timer = state.withLock { s -> DispatchSourceTimer? in
            s.stopped = true
            defer { s.timer = nil }
            return s.timer
        }
        timer?.cancel()
    }

    public var uniqueShapes: Int { state.withLock { $0.tracker.uniqueShapes } }
}

#if os(macOS)
import AppKit

/// The real source: `NSCursor.currentSystem` (WebRTC's approach, §5.4), rendered at 2× into premultiplied
/// BGRA in Display P3 (the stream's color space). Re-renders only when the cursor's image object or
/// hotspot changes; the tracker dedups by content.
public final class SystemCursorSource: CursorImageSource {
    public let scale: Int
    private struct Cache: @unchecked Sendable {
        var image: NSImage?
        var hotspot = CGPoint.zero
        var rendered: CursorImage?
    }
    private let cache = Mutex(Cache())

    public init(scale: Int = 2) { self.scale = scale }

    public func currentCursor() -> CursorImage? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let image = cursor.image
        let hotspot = cursor.hotSpot
        if let hit = cache.withLock({ c in c.image === image && c.hotspot == hotspot ? c.rendered : nil }) { return hit }
        let rendered = Self.render(image, hotspot: hotspot, scale: scale)
        cache.withLock { c in
            c.image = image
            c.hotspot = hotspot
            c.rendered = rendered
        }
        return rendered
    }

    static func render(_ image: NSImage, hotspot: CGPoint, scale: Int) -> CursorImage? {
        let size = image.size
        let w = Int((size.width * CGFloat(scale)).rounded(.up)), h = Int((size.height * CGFloat(scale)).rounded(.up))
        guard w > 0, h > 0, w <= 1024, h <= 1024, let space = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .high
            // Bitmap row 0 is the image's top row, so the pixels are top-down as the wire expects.
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return CursorImage(pixelWidth: w, pixelHeight: h, scale: scale, hotspotX: Float(hotspot.x), hotspotY: Float(hotspot.y),
                           pixels: pixels)
    }
}
#endif
