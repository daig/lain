import Darwin
import LainProtocol

/// Turns Siri Remote (2nd–4th gen touch-enabled clickpad, or UIKit indirect touches/presses in the
/// simulator) into remote desktop actions, independent of GameController and UIKit.
///
/// The caller feeds surface touch/position updates, physical button transitions (inner center click,
/// outer-ring cardinal clicks, Play/Pause, Back/Menu), and a display-rate `tick`, and applies the
/// returned actions in order.
///
/// Ergonomics:
/// - **Pointer**: relative movement from thumb travel on the clickpad (no tap-to-click by default, so
///   lifting and clutching the thumb across a 4K screen never causes accidental clicks). Lifting the
///   finger suppresses the `(0, 0)` snap that `GCMicroGamepad.dpad` emits on touch-up (in either
///   event order).
/// - **Click stabilization**: pressing the mechanical center button rolls the thumb slightly before
///   actuation. Small drift over the preceding `stabilizeWindowNs` is rolled back before pressing the
///   left button, followed by a brief `postClickFreezeNs` micro-deadzone so clicks stay pinned to small
///   targets.
/// - **Drag & Drag Lock**: pressing Center + sliding drags normally. Holding Center still for
///   `dragLockHoldNs` latches the left button down so the thumb can lift and clutch across the whole
///   screen; another Center click (or Back) releases it.
/// - **Modeless Scroll**: outer-ring cardinal clicks (`↑ ↓ ← →`) scroll immediately on tap and ramp
///   into smooth continuous scrolling while held (suppressed while dragging). Tracing a circular arc
///   around the outer ring (`jogScrollEnabled`) drives analog vertical scrolling.
/// - **Play/Pause**: short tap right-clicks; holding for `longPressNs` toggles cursor zoom.
/// - **Back (`<`)**: short tap sends Escape (or cancels Drag Lock); holding for `longPressNs` opens
///   lain's overlay panel.
public struct SiriRemoteInput: Sendable {
    public enum Direction: Sendable, Equatable, Hashable {
        case up, down, left, right
    }

    public enum Action: Sendable, Equatable {
        /// Relative pointer delta in remote-pad counts (y up-positive, matching `PointerTracker.move`).
        case moveBy(dx: Double, dy: Double)
        case button(MouseButton, isDown: Bool)
        case scrollBegan
        /// Continuous scroll delta in points (`dy > 0` scrolls up, `dy < 0` scrolls down; `dx > 0` left, `dx < 0` right).
        case scroll(dx: Double, dy: Double)
        case scrollEnded
        case scrollCancelled
        /// A discrete key press + release on the host (e.g., Escape).
        case keyTap(PhysicalKey)
        /// Toggle 2× client viewport zoom about the pointer.
        case toggleZoom
        /// Open lain's tvOS Quick Actions / Control Panel overlay.
        case openPanel
        /// Drag Lock latched (`true`) or released (`false`), for local UI/cursor feedback.
        case dragLockChanged(Bool)
    }

    // MARK: Tuning

    /// Counts per normalized pad radius (`1.0`). Full pad diameter (`2.0`) = `2 * padScale` counts.
    public var padScale = 140.0
    /// Lookback window before Center Click whose small pre-click thumb roll is undone.
    public var stabilizeWindowNs: UInt64 = 55_000_000
    /// Maximum pre-click drift (in pad counts) eligible for rollback; fast deliberate flicks aren't undone.
    public var stabilizeMaxTravel = 14.0
    /// Brief freeze after Center Click down during which sub-`clickSlop` movement is absorbed.
    public var postClickFreezeNs: UInt64 = 45_000_000
    /// Movement (pad counts) while Center Click is held that counts as intentional drag rather than stillness.
    public var clickSlop = 8.0
    /// Holding Center Click still this long latches Drag Lock (`0` disables Drag Lock).
    public var dragLockHoldNs: UInt64 = 450_000_000
    /// Long-press threshold for Play/Pause (zoom) and Back/Menu (panel).
    public var longPressNs: UInt64 = 400_000_000
    /// Points scrolled immediately on an outer-ring directional tap.
    public var ringTapScroll = 42.0
    /// Hold delay before an outer-ring press transitions from tap into smooth continuous scrolling.
    public var ringRepeatDelayNs: UInt64 = 180_000_000
    /// Starting continuous scroll speed while holding an outer-ring direction (pt/s).
    public var ringMinSpeed = 320.0
    /// Maximum continuous scroll speed while holding an outer-ring direction (pt/s).
    public var ringMaxSpeed = 1400.0
    /// Time to ramp from `ringMinSpeed` to `ringMaxSpeed` while holding an outer-ring direction.
    public var ringRampNs: UInt64 = 800_000_000
    /// Allow circular jog scrubbing around the outer ring for analog vertical scrolling.
    public var jogScrollEnabled = true
    /// Normalized radius (`0...1`) a touch must land at or beyond to arm circular jog.
    public var jogOuterRadius = 0.62
    /// Moving inward below this radius disarms circular jog for the current touch.
    public var jogKeepRadius = 0.45
    /// Continuous single-direction arc (radians) around the outer ring required to engage jog scrolling.
    public var jogEngageRadians = 0.66
    /// Vertical scroll points per radian of outer-ring rotation once jog is engaged.
    public var jogPointsPerRadian = 110.0

    // MARK: State

    private struct Sample: Sendable {
        var timeNs: UInt64
        var dx: Double
        var dy: Double
    }

    private enum JogState: Sendable, Equatable {
        case disarmed
        case armed(lastAngle: Double, accumulated: Double)
        case active(lastAngle: Double)
    }

    private var surfaceTouched = false
    /// Last accepted absolute pad position (`[-1, 1]`), nil until the first sample after touchdown.
    private var lastSurface: (x: Double, y: Double)?
    private var jogState: JogState = .disarmed

    /// Recent pointer deltas for pre-click jitter stabilization.
    private var recentMoves: [Sample] = []

    /// Left mouse button is logically down on the host (held via Center Click or Drag Lock).
    public private(set) var isLeftDown = false
    /// Physical Center Click is currently pressed.
    private var centerPhysicalDown = false
    /// Drag Lock is latched: left button stays down after Center Click is released.
    public private(set) var isDragLocked = false
    /// This Center Click press was used to release Drag Lock; ignore its release.
    private var centerConsumedForUnlock = false
    /// When Center Click went down, for post-click freeze and Drag Lock hold timing.
    private var centerDownAtNs: UInt64?
    /// Accumulated travel since Center Click went down (counts); breaks stillness / freeze once `> clickSlop`.
    private var centerTravel = 0.0
    private var centerMovedBeyondSlop = false

    /// Active outer-ring scroll state.
    private var heldDirections: [Direction] = []
    private var ringScrollActive = false
    private var ringHeldSinceNs: UInt64 = 0
    private var lastRingTickNs: UInt64 = 0

    /// Play/Pause press state (short = right-click, long = toggle zoom).
    private var playPauseDownAtNs: UInt64?
    private var playPauseTriggeredLong = false

    /// Back/Menu press state (short = Escape or unlock drag, long = open panel).
    private var menuDownAtNs: UInt64?
    private var menuTriggeredLong = false

    public init() {}

    /// Any button, touch, or scroll gesture is currently active.
    public var isActive: Bool {
        surfaceTouched || isLeftDown || centerPhysicalDown || ringScrollActive
            || playPauseDownAtNs != nil || menuDownAtNs != nil
    }

    // MARK: Touchpad Surface (Absolute — GameController)

    /// Touch state transition on the clickpad capacitive surface (or UIKit indirect touch began/ended).
    public mutating func surfaceTouched(_ isTouched: Bool, at timeNs: UInt64) -> [Action] {
        guard isTouched != surfaceTouched else { return [] }
        surfaceTouched = isTouched
        if isTouched {
            lastSurface = nil
            jogState = .disarmed
            return []
        }
        let wasJogging = isJogActive
        lastSurface = nil
        jogState = .disarmed
        return wasJogging ? [.scrollEnded] : []
    }

    /// Absolute normalized position (`x, y ∈ [-1, 1]`, y up-positive) from `GCDirectionalGamepad.dpad`.
    public mutating func surfaceMoved(x: Double, y: Double, at timeNs: UInt64) -> [Action] {
        guard x.isFinite, y.isFinite else { return [] }
        // Exact (0, 0) on `GCMicroGamepad.dpad` is the hardware finger-lift signal. On Siri Remotes
        // whose touch-surface button does not fire capacitive `touchedChangedHandler(false)`, this is
        // the only lift event we receive — reset `surfaceTouched` and `lastSurface` so lifting and
        // re-touching on another part of the pad never snaps the cursor backwards.
        if x == 0 && y == 0 {
            let wasJogging = isJogActive
            surfaceTouched = false
            lastSurface = nil
            jogState = .disarmed
            return wasJogging ? [.scrollEnded] : []
        }
        if !surfaceTouched {
            surfaceTouched = true
            lastSurface = (x, y)
            armJogIfOuterRing(x: x, y: y)
            return []
        }
        guard let prev = lastSurface else {
            lastSurface = (x, y)
            armJogIfOuterRing(x: x, y: y)
            return []
        }
        lastSurface = (x, y)

        if let jogActions = processJog(x: x, y: y) {
            return jogActions
        }

        let dx = (x - prev.x) * padScale
        let dy = (y - prev.y) * padScale
        return emitPointerDelta(dx: dx, dy: dy, at: timeNs)
    }

    // MARK: Touchpad Surface (Relative — UIKit Indirect Fallback / Simulator)

    /// Relative delta in normalized pad units (y up-positive), for UIKit indirect touches.
    public mutating func indirectMoved(dx: Double, dy: Double, at timeNs: UInt64) -> [Action] {
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return [] }
        return emitPointerDelta(dx: dx * padScale, dy: dy * padScale, at: timeNs)
    }

    // MARK: Physical Buttons

    /// Inner clickpad center button (`GCInputDirectionalCenterButton` / `UIPressType.select`).
    public mutating func centerButton(isDown: Bool, at timeNs: UInt64) -> [Action] {
        guard isDown != centerPhysicalDown else { return [] }
        centerPhysicalDown = isDown

        if isDown {
            var actions: [Action] = []
            // Stop any active ring or jog scroll on click.
            actions += endActiveScroll()

            if isDragLocked {
                // Second click cleanly drops Drag Lock without sending a fresh click.
                isDragLocked = false
                centerConsumedForUnlock = true
                centerDownAtNs = nil
                if isLeftDown {
                    isLeftDown = false
                    actions.append(.button(.left, isDown: false))
                }
                actions.append(.dragLockChanged(false))
                return actions
            }

            // Pre-click stabilization: undo tiny thumb-roll drift from the last ~55 ms.
            if let rollback = preClickRollback(at: timeNs) {
                actions.append(.moveBy(dx: rollback.dx, dy: rollback.dy))
            }
            recentMoves.removeAll(keepingCapacity: true)

            centerConsumedForUnlock = false
            centerDownAtNs = timeNs
            centerTravel = 0
            centerMovedBeyondSlop = false
            isLeftDown = true
            actions.append(.button(.left, isDown: true))
            return actions
        } else {
            centerDownAtNs = nil
            centerTravel = 0
            centerMovedBeyondSlop = false
            if centerConsumedForUnlock {
                centerConsumedForUnlock = false
                return []
            }
            if isDragLocked {
                // Left button remains latched on the host until unlocked.
                return []
            }
            guard isLeftDown else { return [] }
            isLeftDown = false
            return [.button(.left, isDown: false)]
        }
    }

    /// Outer-ring cardinal direction click (`GCInputDirectionalCardinalDpad` / `UIPressType.*Arrow`).
    public mutating func ringDirection(_ direction: Direction, isDown: Bool, at timeNs: UInt64) -> [Action] {
        if isDown {
            // Don't scroll while dragging or drag-locked (thumb sliding near edge during drag).
            guard !isLeftDown else { return [] }
            guard !heldDirections.contains(direction) else { return [] }
            heldDirections.append(direction)

            var actions: [Action] = []
            // If circular jog was scrolling, hand off cleanly.
            if isJogActive {
                jogState = .disarmed
                actions.append(.scrollEnded)
            }
            if !ringScrollActive {
                ringScrollActive = true
                actions.append(.scrollBegan)
            }
            ringHeldSinceNs = timeNs
            lastRingTickNs = timeNs
            let step = Self.scrollVector(for: direction, magnitude: ringTapScroll)
            actions.append(.scroll(dx: step.dx, dy: step.dy))
            return actions
        } else {
            heldDirections.removeAll { $0 == direction }
            guard ringScrollActive else { return [] }
            if heldDirections.isEmpty {
                ringScrollActive = false
                return [.scrollEnded]
            }
            // Another ring direction is still held: reset ramp gently from now.
            ringHeldSinceNs = timeNs
            lastRingTickNs = timeNs
            return []
        }
    }

    /// Play/Pause (`buttonX` / `UIPressType.playPause`): tap = Right Click, hold (`longPressNs`) = Toggle 2× Zoom.
    public mutating func playPause(isDown: Bool, at timeNs: UInt64) -> [Action] {
        if isDown {
            guard playPauseDownAtNs == nil else { return [] }
            playPauseDownAtNs = timeNs
            playPauseTriggeredLong = false
            return []
        } else {
            guard playPauseDownAtNs != nil else { return [] }
            playPauseDownAtNs = nil
            if playPauseTriggeredLong {
                playPauseTriggeredLong = false
                return []
            }
            var actions = endActiveScroll()
            actions.append(.button(.right, isDown: true))
            actions.append(.button(.right, isDown: false))
            return actions
        }
    }

    /// Back / Menu (`buttonMenu` / `UIPressType.menu`): tap = Escape (or cancels Drag Lock),
    /// hold (`longPressNs`) = Open Lain Overlay Panel.
    public mutating func menu(isDown: Bool, at timeNs: UInt64) -> [Action] {
        if isDown {
            guard menuDownAtNs == nil else { return [] }
            if isDragLocked {
                // Immediate tactile cancel of Drag Lock on Back press.
                isDragLocked = false
                var actions: [Action] = []
                if isLeftDown {
                    isLeftDown = false
                    actions.append(.button(.left, isDown: false))
                }
                actions.append(.dragLockChanged(false))
                menuDownAtNs = timeNs
                menuTriggeredLong = true   // don't also send Escape on release
                return actions
            }
            menuDownAtNs = timeNs
            menuTriggeredLong = false
            return []
        } else {
            guard menuDownAtNs != nil else { return [] }
            menuDownAtNs = nil
            if menuTriggeredLong {
                menuTriggeredLong = false
                return []
            }
            return [.keyTap(.escape)]
        }
    }

    /// Programmatically latches or releases Drag Lock (e.g., from the tvOS Quick Actions overlay).
    public mutating func setDragLocked(_ locked: Bool) -> [Action] {
        guard locked != isDragLocked else { return [] }
        isDragLocked = locked
        var actions: [Action] = []
        if locked {
            if !isLeftDown {
                isLeftDown = true
                actions.append(.button(.left, isDown: true))
            }
            actions.append(.dragLockChanged(true))
        } else {
            if isLeftDown {
                isLeftDown = false
                actions.append(.button(.left, isDown: false))
            }
            actions.append(.dragLockChanged(false))
        }
        return actions
    }

    // MARK: Time

    /// Call at the display rate: drives continuous outer-ring scrolling, Drag Lock hold, and long-presses.
    public mutating func tick(at timeNs: UInt64) -> [Action] {
        var actions: [Action] = []

        // 1. Center-click hold-still → Drag Lock.
        if dragLockHoldNs > 0, centerPhysicalDown, !isDragLocked, !centerMovedBeyondSlop,
           let downAt = centerDownAtNs, timeNs >= downAt, timeNs - downAt >= dragLockHoldNs {
            isDragLocked = true
            actions.append(.dragLockChanged(true))
        }

        // 2. Play/Pause long-press → Toggle 2× Zoom.
        if let downAt = playPauseDownAtNs, !playPauseTriggeredLong,
           timeNs >= downAt, timeNs - downAt >= longPressNs {
            playPauseTriggeredLong = true
            actions.append(.toggleZoom)
        }

        // 3. Back/Menu long-press → Open Lain Panel.
        if let downAt = menuDownAtNs, !menuTriggeredLong,
           timeNs >= downAt, timeNs - downAt >= longPressNs {
            menuTriggeredLong = true
            actions += cancelForOverlay()
            actions.append(.openPanel)
            return actions
        }

        // 4. Continuous outer-ring scroll while held.
        if ringScrollActive, let dir = heldDirections.last, timeNs >= ringHeldSinceNs {
            let heldNs = timeNs - ringHeldSinceNs
            if heldNs >= ringRepeatDelayNs {
                let dtNs = timeNs > lastRingTickNs ? min(timeNs - lastRingTickNs, 50_000_000) : 0
                lastRingTickNs = timeNs
                if dtNs > 0 {
                    let rampProgress = ringRampNs > 0
                        ? min(Double(heldNs - ringRepeatDelayNs) / Double(ringRampNs), 1.0)
                        : 1.0
                    let speed = ringMinSpeed + (ringMaxSpeed - ringMinSpeed) * rampProgress
                    let dist = speed * (Double(dtNs) / 1e9)
                    let v = Self.scrollVector(for: dir, magnitude: dist)
                    actions.append(.scroll(dx: v.dx, dy: v.dy))
                }
            } else {
                lastRingTickNs = timeNs
            }
        }

        return actions
    }

    // MARK: Cancellation / Reset (Invariant 4)

    /// Releases everything held (e.g., panel opened, app resigned active, controller disconnected).
    public mutating func cancelled() -> [Action] {
        let actions = cancelForOverlay()
        playPauseDownAtNs = nil
        playPauseTriggeredLong = false
        menuDownAtNs = nil
        menuTriggeredLong = false
        return actions
    }

    /// Forgets all local state without emitting actions (link already gone).
    public mutating func reset() {
        surfaceTouched = false
        lastSurface = nil
        jogState = .disarmed
        recentMoves.removeAll()
        isLeftDown = false
        centerPhysicalDown = false
        isDragLocked = false
        centerConsumedForUnlock = false
        centerDownAtNs = nil
        centerTravel = 0
        centerMovedBeyondSlop = false
        heldDirections.removeAll()
        ringScrollActive = false
        ringHeldSinceNs = 0
        lastRingTickNs = 0
        playPauseDownAtNs = nil
        playPauseTriggeredLong = false
        menuDownAtNs = nil
        menuTriggeredLong = false
    }

    // MARK: Private Helpers

    private var isJogActive: Bool {
        if case .active = jogState { return true }
        return false
    }

    private mutating func emitPointerDelta(dx: Double, dy: Double, at timeNs: UInt64) -> [Action] {
        guard dx != 0 || dy != 0 else { return [] }
        let dist = hypot(dx, dy)

        if centerPhysicalDown && !isDragLocked {
            centerTravel += dist
            if centerTravel > clickSlop {
                centerMovedBeyondSlop = true
            }
            // During the brief post-click freeze window, absorb sub-slop mechanical settle jitter.
            if !centerMovedBeyondSlop, let downAt = centerDownAtNs,
               timeNs >= downAt, timeNs - downAt < postClickFreezeNs {
                return []
            }
        }

        // Track recent moves for pre-click stabilization.
        recentMoves.append(Sample(timeNs: timeNs, dx: dx, dy: dy))
        pruneRecentMoves(at: timeNs)
        return [.moveBy(dx: dx, dy: dy)]
    }

    private mutating func pruneRecentMoves(at timeNs: UInt64) {
        let cutoff = timeNs > stabilizeWindowNs ? timeNs - stabilizeWindowNs : 0
        recentMoves.removeAll { $0.timeNs < cutoff }
    }

    private mutating func preClickRollback(at timeNs: UInt64) -> (dx: Double, dy: Double)? {
        pruneRecentMoves(at: timeNs)
        guard !recentMoves.isEmpty else { return nil }
        var sumX = 0.0, sumY = 0.0
        for s in recentMoves {
            sumX += s.dx
            sumY += s.dy
        }
        let travel = hypot(sumX, sumY)
        guard travel > 0, travel <= stabilizeMaxTravel else { return nil }
        return (-sumX, -sumY)
    }

    private mutating func armJogIfOuterRing(x: Double, y: Double) {
        guard jogScrollEnabled, !isLeftDown, !ringScrollActive else {
            jogState = .disarmed
            return
        }
        let r = hypot(x, y)
        if r >= jogOuterRadius {
            jogState = .armed(lastAngle: atan2(y, x), accumulated: 0)
        } else {
            jogState = .disarmed
        }
    }

    /// Returns scroll actions if the touch is actively jog-scrolling, or `nil` to fall through to pointer movement.
    private mutating func processJog(x: Double, y: Double) -> [Action]? {
        guard jogScrollEnabled, !isLeftDown, !ringScrollActive else {
            if isJogActive {
                jogState = .disarmed
                return [.scrollEnded]
            }
            jogState = .disarmed
            return nil
        }

        let r = hypot(x, y)
        switch jogState {
        case .disarmed:
            return nil

        case .armed(let lastAngle, var accumulated):
            if r < jogKeepRadius {
                jogState = .disarmed
                return nil
            }
            let angle = atan2(y, x)
            let dTheta = Self.wrappedAngleDelta(from: lastAngle, to: angle)
            // Direction reversal resets arc accumulation so back-and-forth pointer micro-moves never trigger jog.
            if (accumulated > 0 && dTheta < -0.05) || (accumulated < 0 && dTheta > 0.05) {
                accumulated = dTheta
            } else {
                accumulated += dTheta
            }
            if abs(accumulated) >= jogEngageRadians {
                jogState = .active(lastAngle: angle)
                // Standard atan2: clockwise is negative dTheta → scroll DOWN (dy < 0); CCW is positive → scroll UP (dy > 0).
                return [.scrollBegan, .scroll(dx: 0, dy: dTheta * jogPointsPerRadian)]
            }
            jogState = .armed(lastAngle: angle, accumulated: accumulated)
            return nil

        case .active(let lastAngle):
            if r < jogKeepRadius * 0.7 {
                jogState = .disarmed
                return [.scrollEnded]
            }
            let angle = atan2(y, x)
            let dTheta = Self.wrappedAngleDelta(from: lastAngle, to: angle)
            jogState = .active(lastAngle: angle)
            guard dTheta != 0 else { return [] }
            return [.scroll(dx: 0, dy: dTheta * jogPointsPerRadian)]
        }
    }

    private mutating func endActiveScroll() -> [Action] {
        var actions: [Action] = []
        if ringScrollActive {
            ringScrollActive = false
            heldDirections.removeAll()
            actions.append(.scrollEnded)
        }
        if isJogActive {
            jogState = .disarmed
            actions.append(.scrollEnded)
        }
        return actions
    }

    private mutating func cancelForOverlay() -> [Action] {
        var actions: [Action] = []
        if isLeftDown {
            isLeftDown = false
            actions.append(.button(.left, isDown: false))
        }
        if isDragLocked {
            isDragLocked = false
            actions.append(.dragLockChanged(false))
        }
        if ringScrollActive {
            ringScrollActive = false
            heldDirections.removeAll()
            actions.append(.scrollCancelled)
        }
        if isJogActive {
            jogState = .disarmed
            actions.append(.scrollCancelled)
        }
        surfaceTouched = false
        lastSurface = nil
        centerPhysicalDown = false
        centerConsumedForUnlock = false
        centerDownAtNs = nil
        centerTravel = 0
        centerMovedBeyondSlop = false
        recentMoves.removeAll()
        return actions
    }

    /// Shortest signed angular delta in `(-π, π]`.
    private static func wrappedAngleDelta(from a: Double, to b: Double) -> Double {
        var d = b - a
        while d > .pi { d -= 2 * .pi }
        while d <= -.pi { d += 2 * .pi }
        return d
    }

    /// Continuous scroll vector in Lain's scroll convention (`dy > 0` up, `dy < 0` down, `dx > 0` left, `dx < 0` right).
    private static func scrollVector(for direction: Direction, magnitude: Double) -> (dx: Double, dy: Double) {
        switch direction {
        case .up: (0, magnitude)
        case .down: (0, -magnitude)
        case .left: (magnitude, 0)
        case .right: (-magnitude, 0)
        }
    }
}
