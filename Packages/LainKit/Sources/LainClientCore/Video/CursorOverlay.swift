import Foundation
import LainProtocol
import Synchronization

/// A cursor image for the renderer: premultiplied BGRA at `scale` pixels per point, hotspot in points.
public struct CursorSprite: Sendable, Equatable {
    /// Unique per image (the renderer caches textures by it).
    public var key: UInt64
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var hotspotX: Double
    public var hotspotY: Double
    public var pixels: [UInt8]

    public init(key: UInt64, pixelWidth: Int, pixelHeight: Int, scale: Double, hotspotX: Double, hotspotY: Double,
                pixels: [UInt8]) {
        precondition(pixels.count == pixelWidth * pixelHeight * 4)
        self.key = key
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.pixels = pixels
    }

    /// Mac `CursorShape` ids occupy the low 32 bits; the built-in arrow uses a key outside them.
    public init(_ shape: CursorShape) {
        self.init(key: UInt64(shape.shapeId), pixelWidth: Int(shape.pixelWidth), pixelHeight: Int(shape.pixelHeight),
                  scale: Double(max(shape.scale, 1)), hotspotX: Double(shape.hotspotX), hotspotY: Double(shape.hotspotY),
                  pixels: shape.pixels)
    }

    /// The classic arrow (black with a white outline), drawn until the Mac's first `CursorShape`.
    public static let arrow: CursorSprite = makeArrow(scale: 2)

    static func makeArrow(scale: Int) -> CursorSprite {
        // Outline of the arrow in points, tip at (1, 1).
        let poly: [(Double, Double)] = [(1, 1), (1, 17), (5, 13.2), (8, 20), (10.6, 18.9), (7.7, 12.3), (13, 12.3)]
        let w = 15 * scale, h = 22 * scale
        let s = Double(scale)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        func inside(_ x: Double, _ y: Double) -> Bool {
            var c = false
            var j = poly.count - 1
            for i in 0..<poly.count {
                let (xi, yi) = poly[i], (xj, yj) = poly[j]
                if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { c.toggle() }
                j = i
            }
            return c
        }
        func edgeDistance(_ x: Double, _ y: Double) -> Double {
            var d = Double.infinity
            var j = poly.count - 1
            for i in 0..<poly.count {
                let (ax, ay) = poly[j], (bx, by) = poly[i]
                let vx = bx - ax, vy = by - ay
                let t = max(0, min(1, ((x - ax) * vx + (y - ay) * vy) / (vx * vx + vy * vy)))
                d = min(d, hypot(x - (ax + t * vx), y - (ay + t * vy)))
                j = i
            }
            return d
        }
        for py in 0..<h {
            for px in 0..<w {
                let x = (Double(px) + 0.5) / s, y = (Double(py) + 0.5) / s
                let isInside = inside(x, y), d = edgeDistance(x, y)
                let value: UInt8
                if isInside && d >= 1 { value = 0 }                     // black body
                else if isInside || d < 0.75 { value = 255 }            // white outline
                else { continue }
                let o = (py * w + px) * 4
                pixels[o] = value; pixels[o + 1] = value; pixels[o + 2] = value; pixels[o + 3] = 255
            }
        }
        return CursorSprite(key: 1 << 40, pixelWidth: w, pixelHeight: h, scale: s, hotspotX: 1, hotspotY: 1, pixels: pixels)
    }
}

/// The client's cursor sprite state (§5.4, §6.3): shapes from `CursorShape`, the selection from
/// `CursorSelect`, and hide-while-typing. Written from the realtime and input queues, read by the
/// renderer each tick (a version check, then a copy only when something changed).
///
/// Shape ids restart at 1 with every host session, so a replaced link's late shape could overwrite the
/// new session's (§7.7 D29): messages tagged with a link generation apply only while that link is the
/// one `reset` last named, checked under the lock.
public final class CursorOverlay: Sendable {
    /// At most this many Mac shapes are kept, the host's live window: past it the host resends shapes
    /// under higher ids, so the lowest id is always the one to drop (`CursorShape.maxLive`).
    public static let maxShapes = CursorShape.maxLive

    private struct State {
        var shapes: [UInt32: CursorShape] = [:]
        var selected: UInt32?
        var visible = true
        /// The link whose tagged messages apply (nil: none).
        var link: UInt64?
    }
    private let state = Mutex(State())
    private let versionCounter = Atomic<UInt64>(0)
    private let typingHidden = Atomic<Bool>(false)

    public init() {}

    /// Bumped whenever the sprite or the Mac's visibility changes.
    public var version: UInt64 { versionCounter.load(ordering: .acquiring) }

    /// `CursorShape`/`CursorSelect` from the realtime connection; other messages are ignored. With a
    /// `generation`, only while that link is current (a stale one is dropped).
    public func apply(_ message: Message, generation: UInt64? = nil) {
        let applied: Bool
        switch message {
        case .cursorShape(let shape):
            applied = state.withLock { s in
                guard generation == nil || generation == s.link else { return false }
                if s.shapes.count >= Self.maxShapes, s.shapes[shape.shapeId] == nil, let victim = s.shapes.keys.min() {
                    s.shapes[victim] = nil
                }
                s.shapes[shape.shapeId] = shape
                return true
            }
        case .cursorSelect(let select):
            applied = state.withLock { s in
                guard generation == nil || generation == s.link else { return false }
                s.selected = select.shapeId
                s.visible = select.visible
                return true
            }
        default:
            return
        }
        if applied { versionCounter.add(1, ordering: .releasing) }
    }

    /// A key went down (not a modifier): hide the cursor until the pointer moves (§5.4).
    public func keyDown() { typingHidden.store(true, ordering: .relaxed) }
    public func pointerMoved() { typingHidden.store(false, ordering: .relaxed) }
    public var isHiddenForTyping: Bool { typingHidden.load(ordering: .relaxed) }

    /// New session: back to the built-in arrow until the Mac sends shapes again. Tagged messages apply
    /// only from link `generation` from now on (nil: from none).
    public func reset(generation: UInt64? = nil) {
        state.withLock { $0 = State(link: generation) }
        typingHidden.store(false, ordering: .relaxed)
        versionCounter.add(1, ordering: .releasing)
    }

    /// The sprite to draw (the arrow until a selected shape has arrived) and whether the Mac shows
    /// a cursor at all. Ignores hide-while-typing; see `isHiddenForTyping`.
    public var current: (sprite: CursorSprite, macVisible: Bool) {
        let (shape, visible) = state.withLock { s in (s.selected.flatMap { s.shapes[$0] }, s.visible) }
        return (shape.map(CursorSprite.init) ?? .arrow, visible)
    }
}
