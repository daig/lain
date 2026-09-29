import Darwin
import LainProtocol

/// A macOS-like pointer acceleration curve over GCMouse deltas (§6.3). Tunable; the
/// constants are placeholders until they're tuned side by side with a real Mac trackpad (M2).
public struct AccelerationCurve: Sendable, Equatable {
    /// Points per count at low speed.
    public var sensitivity: Double = 0.75
    /// 0 = linear. Scales how quickly gain rises above `threshold`.
    public var acceleration: Double = 1.0
    /// Speed (counts/s) where acceleration starts.
    public var threshold: Double = 400
    public var exponent: Double = 0.8
    public var maxGain: Double = 5

    public init() {}

    public init(sensitivity: Double, acceleration: Double, threshold: Double = 400, exponent: Double = 0.8,
                maxGain: Double = 5) {
        self.sensitivity = sensitivity
        self.acceleration = acceleration
        self.threshold = threshold
        self.exponent = exponent
        self.maxGain = maxGain
    }

    /// Gain multiplier (≥ 1) for a speed in counts per second.
    public func gain(speed: Double) -> Double {
        guard acceleration > 0, speed > threshold else { return 1 }
        let x = (speed - threshold) / threshold
        return min(maxGain, 1 + acceleration * pow(x, exponent))
    }
}

/// One Mac display in the global desktop space: points, top-left origin, the main display at (0, 0)
/// (`DisplayLayout`, §7.5).
public struct DesktopDisplay: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(width, 0)
        self.height = max(height, 0)
    }

    /// The largest reachable coordinates: the hotspot can sit on the last point column/row.
    public var maxX: Double { x + max(0, width - 1) }
    public var maxY: Double { y + max(0, height - 1) }

    /// Inside the reachable region (the closed rect from the origin to `maxX`/`maxY`).
    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= maxX && py >= y && py <= maxY
    }

    /// The reachable point nearest to (px, py).
    public func clamped(x px: Double, y py: Double) -> (x: Double, y: Double) {
        (min(max(px, x), maxX), min(max(py, y), maxY))
    }
}

/// The client-authoritative cursor (§6.3, invariant 1): applies the curve to raw deltas, moves over
/// the Mac's desktop (every display, global points) and produces `PointerMove`s in global points.
///
/// Edge rules (macOS-like): motion inside a display is free. Leaving a display through an edge
/// segment that touches another display (their edges coincide and the exit point lies on the shared
/// part) continues onto that display with the rest of the motion. Any other edge blocks: the cursor
/// stops on the display's last point row/column and slides along the edge with the remaining motion.
/// Displays separated by a gap, or touching only at a corner, can't be crossed between. A position
/// outside every display (a warp, or a layout change) snaps to the nearest point of the nearest display.
///
/// A tracker built with `init(width:height:)` has one display at (0, 0): the M2 single-display
/// behaviour.
public struct PointerTracker: Sendable {
    public var curve: AccelerationCurve
    /// The desktop, in global points. Never empty.
    public private(set) var displays: [DesktopDisplay]
    /// Index into `displays` of the display the cursor is on.
    public private(set) var displayIndex: Int
    public private(set) var x: Double
    public private(set) var y: Double
    private var lastEventNs: UInt64?

    /// Nominal GCMouse interval (120 Hz), used after idle.
    static let nominalIntervalNs: UInt64 = 8_333_333
    static let minIntervalNs: UInt64 = 4_166_666
    static let maxIntervalNs: UInt64 = 33_333_333
    /// Display edges closer than this (points) coincide.
    static let edgeTolerance = 0.5

    /// One display of `width`×`height` points at (0, 0), cursor in its centre.
    public init(width: Double, height: Double, curve: AccelerationCurve = AccelerationCurve()) {
        self.init(displays: [DesktopDisplay(x: 0, y: 0, width: width, height: height)], curve: curve)
    }

    /// A desktop, cursor in the centre of `displays[startIndex]`. An empty list becomes one 0×0 display.
    public init(displays: [DesktopDisplay], startIndex: Int = 0, curve: AccelerationCurve = AccelerationCurve()) {
        self.curve = curve
        self.displays = displays.isEmpty ? [DesktopDisplay(x: 0, y: 0, width: 0, height: 0)] : displays
        let i = self.displays.indices.contains(startIndex) ? startIndex : 0
        let d = self.displays[i]
        displayIndex = i
        x = d.x + d.width / 2
        y = d.y + d.height / 2
        snap()
    }

    /// The display the cursor is on.
    public var display: DesktopDisplay { displays[displayIndex] }
    /// The current display's size in points.
    public var width: Double { display.width }
    public var height: Double { display.height }
    /// The current display's largest reachable coordinates (global).
    public var maxX: Double { display.maxX }
    public var maxY: Double { display.maxY }

    /// Single-display compatibility: the desktop becomes one display of this size at (0, 0).
    public mutating func resize(width: Double, height: Double) {
        setDesktop([DesktopDisplay(x: 0, y: 0, width: width, height: height)])
    }

    /// A new arrangement (`DisplayLayout`). The cursor keeps its global position if that is still on a
    /// display, else it snaps to the nearest point of the nearest display.
    public mutating func setDesktop(_ newDisplays: [DesktopDisplay]) {
        displays = newDisplays.isEmpty ? [DesktopDisplay(x: 0, y: 0, width: 0, height: 0)] : newDisplays
        displayIndex = 0
        snap()
    }

    /// Puts the cursor in the centre of `displays[index]` (a new session's first layout).
    public mutating func center(on index: Int) {
        guard displays.indices.contains(index) else { return }
        let d = displays[index]
        displayIndex = index
        x = d.x + d.width / 2
        y = d.y + d.height / 2
        snap()
    }

    /// `CursorWarp` from the Mac overwrites the position (global points; any display).
    public mutating func warp(x: Double, y: Double) {
        self.x = x
        self.y = y
        snap()
    }

    /// Applies one GCMouse delta (y up-positive). Deltas were integers on iPadOS 26.7 and are
    /// fractional on 27 (§13). Returns nil for zero deltas, which iPadOS sends while fingers rest.
    public mutating func move(dx: Double, dy: Double, at timeNs: UInt64, buttons: UInt8) -> PointerMove? {
        guard dx != 0 || dy != 0 else { return nil }
        // GCMouse reports every ~8.3 ms while moving, so after a pause the first delta covers about one
        // frame of motion, not the whole pause.
        var interval = Self.nominalIntervalNs
        if let last = lastEventNs, timeNs > last, timeNs - last <= Self.maxIntervalNs {
            interval = max(timeNs - last, Self.minIntervalNs)
        }
        lastEventNs = timeNs
        let counts = (dx * dx + dy * dy).squareRoot()
        let speed = counts / (Double(interval) / 1e9)
        let scale = curve.sensitivity * curve.gain(speed: speed)
        let mx = dx * scale
        let my = -dy * scale   // GCMouse y is up-positive; the Mac's is down-positive
        travel(mx, my)
        return PointerMove(x: x, y: y, dx: Float(mx), dy: Float(my), buttons: buttons)
    }

    // MARK: Desktop geometry

    private enum Edge { case left, right, top, bottom }

    /// Walks (mx, my) from the current position across display edges (see the type's edge rules).
    private mutating func travel(_ mx: Double, _ my: Double) {
        var rx = mx, ry = my
        // Each step crosses or blocks at one edge; a few suffice for any real layout.
        for _ in 0..<16 {
            let d = displays[displayIndex]
            let tx = x + rx, ty = y + ry
            if d.contains(x: tx, y: ty) {
                x = tx
                y = ty
                return
            }
            // Where the segment first leaves the display's reachable region.
            var t = Double.infinity
            var edge = Edge.right
            if rx > 0, tx > d.maxX { let tt = (d.maxX - x) / rx; if tt < t { t = tt; edge = .right } }
            if rx < 0, tx < d.x { let tt = (d.x - x) / rx; if tt < t { t = tt; edge = .left } }
            if ry > 0, ty > d.maxY { let tt = (d.maxY - y) / ry; if tt < t { t = tt; edge = .bottom } }
            if ry < 0, ty < d.y { let tt = (d.y - y) / ry; if tt < t { t = tt; edge = .top } }
            guard t.isFinite else { break }
            t = min(max(t, 0), 1)
            let (ex, ey) = d.clamped(x: x + rx * t, y: y + ry * t)
            if let n = neighbor(of: displayIndex, across: edge, x: ex, y: ey) {
                // Continue on the neighbour from its facing edge, still heading for the same global
                // target (the remaining motion keeps its direction across the edge).
                let nd = displays[n]
                displayIndex = n
                switch edge {
                case .right: (x, y) = (nd.x, ey); rx = max(tx - x, 0); ry = ty - y
                case .left: (x, y) = (nd.maxX, ey); rx = min(tx - x, 0); ry = ty - y
                case .bottom: (x, y) = (ex, nd.y); rx = tx - x; ry = max(ty - y, 0)
                case .top: (x, y) = (ex, nd.maxY); rx = tx - x; ry = min(ty - y, 0)
                }
            } else {
                // Blocked: stop on the edge and slide along it with the rest of the motion.
                (x, y) = (ex, ey)
                switch edge {
                case .left, .right: rx = 0; ry = ty - y
                case .top, .bottom: rx = tx - x; ry = 0
                }
            }
        }
        (x, y) = displays[displayIndex].clamped(x: x + rx, y: y + ry)
    }

    /// The display sharing `edge` of `displays[index]` at the exit point (ex, ey), if any.
    private func neighbor(of index: Int, across edge: Edge, x ex: Double, y ey: Double) -> Int? {
        let d = displays[index]
        let tol = Self.edgeTolerance
        for (i, n) in displays.enumerated() where i != index && n.width > 0 && n.height > 0 {
            let adjacent = switch edge {
            case .right: abs(n.x - (d.x + d.width)) < tol && ey >= n.y && ey <= n.maxY
            case .left: abs(n.x + n.width - d.x) < tol && ey >= n.y && ey <= n.maxY
            case .bottom: abs(n.y - (d.y + d.height)) < tol && ex >= n.x && ex <= n.maxX
            case .top: abs(n.y + n.height - d.y) < tol && ex >= n.x && ex <= n.maxX
            }
            if adjacent { return i }
        }
        return nil
    }

    /// Keeps the cursor on a display: the containing one (current first), else the nearest point of the
    /// nearest display.
    private mutating func snap() {
        if displays[displayIndex].contains(x: x, y: y) { return }
        if let i = displays.firstIndex(where: { $0.contains(x: x, y: y) }) {
            displayIndex = i
            return
        }
        var best = (index: 0, distance: Double.infinity, x: x, y: y)
        for (i, d) in displays.enumerated() {
            let c = d.clamped(x: x, y: y)
            let dist = (c.x - x) * (c.x - x) + (c.y - y) * (c.y - y)
            if dist < best.distance { best = (i, dist, c.x, c.y) }
        }
        displayIndex = best.index
        x = best.x
        y = best.y
    }
}

/// Click counting with the Mac's double-click interval (§5.5): a press continues the sequence if it
/// is the same button, within the interval of the previous press, and within `maxDistance` points.
public struct ClickCounter: Sendable {
    public var intervalNs: UInt64
    public var maxDistance: Double
    private var last: (button: MouseButton, timeNs: UInt64, x: Double, y: Double, count: UInt8)?

    public init(intervalMs: UInt32 = 500, maxDistance: Double = 4) {
        intervalNs = UInt64(intervalMs) * 1_000_000
        self.maxDistance = maxDistance
    }

    /// The click count for a button-down.
    public mutating func down(_ button: MouseButton, x: Double, y: Double, at timeNs: UInt64) -> UInt8 {
        var count: UInt8 = 1
        if let l = last, l.button == button, timeNs >= l.timeNs, timeNs - l.timeNs <= intervalNs,
           ((x - l.x) * (x - l.x) + (y - l.y) * (y - l.y)).squareRoot() <= maxDistance {
            count = l.count == .max ? l.count : l.count + 1
        }
        last = (button, timeNs, x, y, count)
        return count
    }

    /// The count to report on the matching button-up.
    public func upCount(_ button: MouseButton) -> UInt8 {
        guard let l = last, l.button == button else { return 1 }
        return l.count
    }

    public mutating func reset() { last = nil }
}

/// Buttons held on the Mac, for `ReleaseAll` (invariant 4) and `PointerMove.buttons`.
public struct HeldButtons: Sendable, Equatable {
    public private(set) var mask: UInt8 = 0

    public init() {}

    /// Returns false for a duplicate down or an orphan up (drop the event).
    public mutating func set(_ button: MouseButton, down: Bool) -> Bool {
        let bit: UInt8 = 1 << button.rawValue
        if down {
            guard mask & bit == 0 else { return false }
            mask |= bit
        } else {
            guard mask & bit != 0 else { return false }
            mask &= ~bit
        }
        return true
    }

    /// Button-ups for everything held, at the given position.
    public mutating func releaseAll(x: Double, y: Double, modifiers: ModifierFlags = []) -> [PointerButton] {
        let ups = MouseButton.allCases.filter { mask & (1 << $0.rawValue) != 0 }.map {
            PointerButton(button: $0, isDown: false, clickCount: 1, x: x, y: y, modifiers: modifiers)
        }
        mask = 0
        return ups
    }
}
