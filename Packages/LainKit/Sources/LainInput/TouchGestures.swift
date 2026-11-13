import LainProtocol

/// What the touchscreen does (the panel's "Touch screen" option).
public enum TouchMode: String, Sendable, CaseIterable {
    /// The pointer goes where the finger is: a tap clicks there, a drag drags from there.
    case direct
    /// The screen is a trackpad: a finger moves the pointer from where it is, a tap clicks where it is.
    case trackpad
    /// Touches do nothing (the Magic Keyboard's trackpad only).
    case off
}

/// Turns fingers on the touchscreen into mouse actions, independent of UIKit. The caller feeds every touch
/// (an id, a position in the surface's points with y down, a `CLOCK_UPTIME_RAW` time in ns) and `tick`, and
/// applies the actions it returns in order.
///
/// Both modes: two fingers moving scroll; two fingers tapping right-click; a third finger ends the gesture.
///
/// `direct`: touching moves the pointer there and presses the button, which stays down for as long as the
/// finger does: a tap is a click, and moving drags. The press waits `pressDelayNs` (or for the finger to move
/// or lift, whichever is first) so that a second finger can land and make it a two-finger gesture instead.
/// The pointer stays put until the finger has travelled `slop`, so a tap is a click and not a tiny drag. A
/// tap near the one before lands on the same point, so two taps make a double-click.
///
/// `trackpad`: moving moves the pointer by as much; a short touch that doesn't move clicks where the pointer
/// is. To drag, hold a finger still for `holdToDragNs`: the button goes down where the pointer is and stays
/// down until the finger lifts. A touch soon after a tap that then moves drags too (tap and a half).
public struct TouchGestures: Sendable {
    public enum Action: Sendable, Equatable {
        /// Put the pointer under this point of the surface.
        case moveTo(x: Double, y: Double)
        /// Move the pointer by a finger's travel (points, y down).
        case moveBy(dx: Double, dy: Double)
        case button(MouseButton, isDown: Bool)
        case scrollBegan
        /// The fingers' travel since the last scroll action (points, y down).
        case scroll(dx: Double, dy: Double)
        case scrollEnded
        case scrollCancelled
        /// Two fingers moved apart or together (only with `pinchZooms`): since the last zoom action the view's
        /// zoom changes by `factor`, and the fingers' midpoint, now at (`x`, `y`) of the surface, has moved by
        /// (`dx`, `dy`): what was under it stays under it.
        case zoom(factor: Double, x: Double, y: Double, dx: Double, dy: Double)
    }

    public private(set) var mode = TouchMode.direct
    /// A touch that travels less than this (points) hasn't moved.
    public var slop = 10.0
    /// The longest touch that is still a tap in `trackpad` mode, and the longest two-finger tap in both.
    public var tapMaxNs: UInt64 = 300_000_000
    /// `direct`: how long a touch waits for a second finger before it presses the button.
    public var pressDelayNs: UInt64 = 80_000_000
    /// `trackpad`: a touch held still this long presses the button, to drag.
    public var holdToDragNs: UInt64 = 400_000_000
    /// A touch this soon after a tap continues it: `direct` lands it on the tap's point if within
    /// `doubleTapSlop`; `trackpad` drags if it moves.
    public var afterTapNs: UInt64 = 400_000_000
    public var doubleTapSlop = 44.0
    /// Two fingers whose distance changes by more than `pinchSlop` before their midpoint has moved are a pinch
    /// (`Action.zoom`), not a scroll. Off: two fingers only scroll and right-click.
    public var pinchZooms = false
    public var pinchSlop = 24.0

    private struct Point: Sendable, Equatable {
        var x: Double, y: Double
        func distance(to p: Point) -> Double { ((x - p.x) * (x - p.x) + (y - p.y) * (y - p.y)).squareRoot() }
    }
    private enum State: Sendable, Equatable {
        case idle
        /// One finger that hasn't moved. `afterTap`: it landed soon after a tap (`trackpad`).
        case pending(id: Int, start: Point, at: UInt64, afterTap: Bool)
        /// `trackpad`: one finger moving the pointer.
        case moving(id: Int, last: Point)
        /// One finger with the left button held. `anchor`: where it pressed, until it has travelled `slop`
        /// (`direct`: the pointer stays there until then).
        case dragging(id: Int, last: Point, anchor: Point?)
        /// Two fingers; `scrolling` once their midpoint has moved.
        case two(a: Int, b: Int, start: Point, last: Point, at: UInt64, scrolling: Bool, mayTap: Bool)
        /// Two fingers pinching; `last`: their distance at the last zoom action, `mid`: their midpoint then.
        case zooming(a: Int, b: Int, last: Double, mid: Point)
        /// Nothing more from this gesture: wait until every finger is up.
        case spent
    }
    /// The two fingers' distance when the second landed.
    private var pinchStart = 0.0
    private var state = State.idle
    private var touches: [Int: Point] = [:]
    private var lastTap: (point: Point, at: UInt64)?

    public init(mode: TouchMode = .direct) { self.mode = mode }

    /// A gesture is in progress (a finger is down).
    public var isActive: Bool { !touches.isEmpty }

    /// Changes the mode, ending any gesture first (the returned actions release what it held).
    public mutating func setMode(_ new: TouchMode) -> [Action] {
        guard new != mode else { return [] }
        let actions = cancelled()
        mode = new
        lastTap = nil
        return actions
    }

    public mutating func began(id: Int, x: Double, y: Double, at timeNs: UInt64) -> [Action] {
        guard mode != .off else { return [] }
        let p = Point(x: x, y: y)
        touches[id] = p
        switch state {
        case .idle:
            let recent = lastTap.flatMap { timeNs >= $0.at && timeNs - $0.at <= afterTapNs ? $0.point : nil }
            if mode == .direct {
                // A second tap lands on the first one's point, or the host wouldn't count a double-click.
                let target = recent.flatMap { $0.distance(to: p) <= doubleTapSlop ? $0 : nil } ?? p
                state = .pending(id: id, start: target, at: timeNs, afterTap: false)
                return [.moveTo(x: target.x, y: target.y)]
            }
            state = .pending(id: id, start: p, at: timeNs, afterTap: recent != nil)
            return []
        case .pending(let first, _, let at, _):
            guard let a = touches[first] else { state = .spent; return [] }
            let mid = Point(x: (a.x + p.x) / 2, y: (a.y + p.y) / 2)
            pinchStart = a.distance(to: p)
            state = .two(a: first, b: id, start: mid, last: mid, at: at, scrolling: false, mayTap: true)
            return []
        case .moving(let first, _):
            guard let a = touches[first] else { state = .spent; return [] }
            let mid = Point(x: (a.x + p.x) / 2, y: (a.y + p.y) / 2)
            pinchStart = a.distance(to: p)
            state = .two(a: first, b: id, start: mid, last: mid, at: timeNs, scrolling: false, mayTap: false)
            return []
        case .two(_, _, _, _, _, let scrolling, _):
            state = .spent
            return scrolling ? [.scrollEnded] : []
        case .zooming:
            state = .spent
            return []
        case .dragging, .spent:
            return []   // an extra finger doesn't disturb a drag
        }
    }

    public mutating func moved(id: Int, x: Double, y: Double, at timeNs: UInt64) -> [Action] {
        guard touches[id] != nil else { return [] }
        let p = Point(x: x, y: y)
        touches[id] = p
        switch state {
        case .pending(let first, let start, _, let afterTap) where first == id:
            guard p.distance(to: start) > slop else { return [] }
            if mode == .direct {
                state = .dragging(id: id, last: p, anchor: nil)
                return [.button(.left, isDown: true), .moveTo(x: p.x, y: p.y)]
            }
            let travel = Action.moveBy(dx: p.x - start.x, dy: p.y - start.y)
            if afterTap {
                state = .dragging(id: id, last: p, anchor: nil)
                return [.button(.left, isDown: true), travel]
            }
            state = .moving(id: id, last: p)
            return [travel]
        case .moving(let first, let last) where first == id:
            state = .moving(id: id, last: p)
            return [.moveBy(dx: p.x - last.x, dy: p.y - last.y)]
        case .dragging(let first, let last, let anchor) where first == id:
            if let anchor, p.distance(to: anchor) <= slop { return [] }
            state = .dragging(id: id, last: p, anchor: nil)
            return mode == .direct ? [.moveTo(x: p.x, y: p.y)] : [.moveBy(dx: p.x - last.x, dy: p.y - last.y)]
        case .two(let a, let b, let start, let last, let at, let scrolling, let mayTap):
            guard let pa = touches[a], let pb = touches[b] else { return [] }
            let mid = Point(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
            if scrolling {
                state = .two(a: a, b: b, start: start, last: mid, at: at, scrolling: true, mayTap: false)
                return [.scroll(dx: mid.x - last.x, dy: mid.y - last.y)]
            }
            let apart = pa.distance(to: pb)
            if pinchZooms, pinchStart > 0, abs(apart - pinchStart) > pinchSlop {
                state = .zooming(a: a, b: b, last: apart, mid: mid)
                return [.zoom(factor: apart / pinchStart, x: mid.x, y: mid.y, dx: mid.x - start.x, dy: mid.y - start.y)]
            }
            guard mid.distance(to: start) > slop else { return [] }
            state = .two(a: a, b: b, start: start, last: mid, at: at, scrolling: true, mayTap: false)
            return [.scrollBegan, .scroll(dx: mid.x - start.x, dy: mid.y - start.y)]
        case .zooming(let a, let b, let last, let was):
            guard let pa = touches[a], let pb = touches[b], last > 0 else { return [] }
            let apart = pa.distance(to: pb), mid = Point(x: (pa.x + pb.x) / 2, y: (pa.y + pb.y) / 2)
            guard apart > 0, apart != last || mid != was else { return [] }
            state = .zooming(a: a, b: b, last: apart, mid: mid)
            return [.zoom(factor: apart / last, x: mid.x, y: mid.y, dx: mid.x - was.x, dy: mid.y - was.y)]
        default:
            return []
        }
    }

    public mutating func ended(id: Int, at timeNs: UInt64) -> [Action] {
        guard touches.removeValue(forKey: id) != nil else { return [] }
        defer { if touches.isEmpty { state = .idle } }
        switch state {
        case .pending(let first, let start, let at, _) where first == id:
            guard mode == .direct || (timeNs >= at && timeNs - at <= tapMaxNs) else { return [] }   // a resting finger
            lastTap = (start, timeNs)
            return [.button(.left, isDown: true), .button(.left, isDown: false)]
        case .dragging(let first, _, let anchor) where first == id:
            lastTap = mode == .direct ? anchor.map { ($0, timeNs) } : nil   // it never moved: a tap
            state = .spent
            return [.button(.left, isDown: false)]
        case .moving(let first, _) where first == id:
            lastTap = nil
            state = .spent
            return []
        case .zooming(let a, let b, _, _) where id == a || id == b:
            state = .spent
            lastTap = nil
            return []
        case .two(let a, let b, _, _, let at, let scrolling, let mayTap) where id == a || id == b:
            state = .spent
            lastTap = nil
            if scrolling { return [.scrollEnded] }
            guard mayTap, timeNs >= at, timeNs - at <= tapMaxNs else { return [] }
            return [.button(.right, isDown: true), .button(.right, isDown: false)]
        default:
            return []
        }
    }

    /// The system took the touches away (or the mode changed): release what the gesture held.
    public mutating func cancelled() -> [Action] {
        defer { state = .idle; touches.removeAll() }
        switch state {
        case .dragging: return [.button(.left, isDown: false)]
        case .two(_, _, _, _, _, true, _): return [.scrollCancelled]
        default: return []
        }
    }

    /// Call regularly (the display rate): the press of a finger that has stayed still (`direct`: once no
    /// second finger has come; `trackpad`: held to drag).
    public mutating func tick(at timeNs: UInt64) -> [Action] {
        guard mode != .off, case .pending(let id, let start, let at, _) = state, timeNs >= at,
              timeNs - at >= (mode == .direct ? pressDelayNs : holdToDragNs) else { return [] }
        state = .dragging(id: id, last: start, anchor: start)
        return [.button(.left, isDown: true)]
    }

    /// Forgets everything without actions (the pipeline has already released every button).
    public mutating func reset() {
        state = .idle
        touches.removeAll()
        lastTap = nil
    }
}
