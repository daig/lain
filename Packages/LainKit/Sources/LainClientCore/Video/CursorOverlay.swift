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
public final class CursorOverlay: Sendable {
    /// At most this many Mac shapes are kept (the Mac has a few dozen; ids are stable per shape).
    public static let maxShapes = 64

    private struct State {
        var shapes: [UInt32: CursorShape] = [:]
        var selected: UInt32?
        var visible = true
    }
    private let state = Mutex(State())
    private let versionCounter = Atomic<UInt64>(0)
    private let typingHidden = Atomic<Bool>(false)

    public init() {}

    /// Bumped whenever the sprite or the Mac's visibility changes.
    public var version: UInt64 { versionCounter.load(ordering: .acquiring) }

    /// `CursorShape`/`CursorSelect` from the realtime connection; other messages are ignored.
    public func apply(_ message: Message) {
        switch message {
        case .cursorShape(let shape):
            state.withLock { s in
                if s.shapes.count >= Self.maxShapes, s.shapes[shape.shapeId] == nil,
                   let victim = s.shapes.keys.first(where: { $0 != s.selected }) {
                    s.shapes[victim] = nil
                }
                s.shapes[shape.shapeId] = shape
            }
        case .cursorSelect(let select):
            state.withLock { s in
                s.selected = select.shapeId
                s.visible = select.visible
            }
        default:
            return
        }
        versionCounter.add(1, ordering: .releasing)
    }

    /// A key went down (not a modifier): hide the cursor until the pointer moves (§5.4).
    public func keyDown() { typingHidden.store(true, ordering: .relaxed) }
    public func pointerMoved() { typingHidden.store(false, ordering: .relaxed) }
    public var isHiddenForTyping: Bool { typingHidden.load(ordering: .relaxed) }

    /// New session: back to the built-in arrow until the Mac sends shapes again.
    public func reset() {
        state.withLock { $0 = State() }
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
