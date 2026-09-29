import Dispatch
import LainInput
import LainProtocol
import LainTelemetry
import Synchronization

/// Where the client cursor is, in Mac display points, for drawing it locally (§6.3).
public struct CursorSnapshot: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var displayPointWidth: Double
    public var displayPointHeight: Double

    public init(x: Double, y: Double, displayPointWidth: Double, displayPointHeight: Double) {
        self.x = x
        self.y = y
        self.displayPointWidth = displayPointWidth
        self.displayPointHeight = displayPointHeight
    }
}

/// The `Sendable` front of `ClientInputPipeline` (§6.4): one serial `.userInteractive` queue owns the
/// pipeline and every entry point runs there. Each call is stamped with `CLOCK_UPTIME_RAW` when it is
/// made. Calls made on `queue` itself (GCMouse and GCKeyboard handlers, whose `handlerQueue` is
/// `queue`) run inline with no hop; calls from elsewhere are enqueued. No locks and no awaits: the
/// cursor snapshot for the UI is published through relaxed atomics.
public final class ClientInput: @unchecked Sendable {
    public let queue: DispatchQueue
    /// Touched only on `queue`.
    private let pipeline: ClientInputPipeline
    private let onQueueKey = DispatchSpecificKey<UInt8>()
    private let cursorX = Atomic<UInt64>(0)
    private let cursorY = Atomic<UInt64>(0)
    private let displayW = Atomic<UInt64>(0)
    private let displayH = Atomic<UInt64>(0)

    public init(pipeline: ClientInputPipeline = ClientInputPipeline(), label: String = "lain.client.input") {
        queue = DispatchQueue(label: label, qos: .userInteractive)
        queue.setSpecific(key: onQueueKey, value: 1)
        self.pipeline = pipeline
        publishCursor()
    }

    // MARK: Session

    /// A session is up and configured: input now goes to `send`.
    public func connect(send: @escaping @Sendable (Message) -> Void) {
        perform { self.pipeline.send = send }
    }

    /// The link is gone (invariant 4): forget everything held without sending, then drop output.
    public func disconnect() {
        perform {
            self.pipeline.releaseAll(.disconnect, notify: false)
            self.pipeline.send = { _ in }
        }
    }

    public func configure(_ ack: HelloAck) {
        perform {
            self.pipeline.configure(ack)
            self.publishCursor()
        }
    }

    public func warp(x: Double, y: Double) {
        perform {
            self.pipeline.warp(x: x, y: y)
            self.publishCursor()
        }
    }

    // MARK: Settings

    /// D19: the capture layer ties this to the pointer lock.
    public func setPointerEnabled(_ enabled: Bool) { perform { self.pipeline.pointerEnabled = enabled } }
    public func setInvertScroll(_ invert: Bool) { perform { self.pipeline.invertScroll = invert } }
    public func setCurve(_ curve: AccelerationCurve) { perform { self.pipeline.curve = curve } }
    public func setRemapTable(_ table: RemapTable) { perform { self.pipeline.remapTable = table } }

    // MARK: Events

    public func keyChanged(_ key: PhysicalKey, isDown: Bool) {
        let t = MonotonicClock.now()
        perform { self.pipeline.keyChanged(key, isDown: isDown, at: t) }
    }

    /// GCKeyboardDidDisconnect: lift the keys it held (no key-ups will come).
    public func keyboardDisconnected() { perform { self.pipeline.keyboardDisconnected() } }

    /// GCMouseDidDisconnect: lift the buttons held (no button-ups will come).
    public func mouseDisconnected() { perform { self.pipeline.mouseDisconnected() } }

    public func learnCharacter(_ key: PhysicalKey, _ characters: String) {
        perform { self.pipeline.learnCharacter(key, characters) }
    }

    public func mouseMoved(dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        let t = MonotonicClock.now()
        perform {
            self.pipeline.mouseMoved(dx: dx, dy: dy, at: t)
            self.publishCursor()
        }
    }

    public func mouseButton(_ button: MouseButton, isDown: Bool) {
        let t = MonotonicClock.now()
        perform { self.pipeline.mouseButton(button, isDown: isDown, at: t) }
    }

    public func scrollBegan() {
        let t = MonotonicClock.now()
        perform { self.pipeline.scrollBegan(at: t) }
    }

    public func scrollChanged(dx: Double, dy: Double) {
        let t = MonotonicClock.now()
        perform { self.pipeline.scrollChanged(dx: dx, dy: dy, at: t) }
    }

    public func scrollWheel(dx: Double, dy: Double) {
        let t = MonotonicClock.now()
        perform { self.pipeline.scrollWheel(dx: dx, dy: dy, at: t) }
    }

    public func scrollEnded() {
        let t = MonotonicClock.now()
        perform { self.pipeline.scrollEnded(at: t) }
    }

    public func scrollCancelled() {
        let t = MonotonicClock.now()
        perform { self.pipeline.scrollCancelled(at: t) }
    }

    public func gesture(_ kind: Gesture.Kind, phase: GesturePhase, value: Float) {
        let t = MonotonicClock.now()
        perform { self.pipeline.gesture(kind, phase: phase, value: value, at: t) }
    }

    /// Call at the display rate (~120 Hz).
    public func tick() {
        let t = MonotonicClock.now()
        perform { self.pipeline.tick(at: t) }
    }

    /// Invariant 4: sends `ReleaseAll` (if connected) and forgets everything held.
    public func releaseAll(_ reason: ReleaseAll.Reason) {
        perform { self.pipeline.releaseAll(reason) }
    }

    // MARK: Reading

    /// The latest cursor position and display size. Lock-free; safe from any thread.
    public var cursor: CursorSnapshot {
        CursorSnapshot(x: Double(bitPattern: cursorX.load(ordering: .relaxed)),
                       y: Double(bitPattern: cursorY.load(ordering: .relaxed)),
                       displayPointWidth: Double(bitPattern: displayW.load(ordering: .relaxed)),
                       displayPointHeight: Double(bitPattern: displayH.load(ordering: .relaxed)))
    }

    /// Runs `body` on the queue and waits (tests and diagnostics only; never from `queue`).
    public func sync<T>(_ body: (ClientInputPipeline) -> T) -> T {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync { body(pipeline) }
    }

    // MARK: Private

    private func perform(_ work: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: onQueueKey) != nil {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    /// On `queue`.
    private func publishCursor() {
        cursorX.store(pipeline.pointer.x.bitPattern, ordering: .relaxed)
        cursorY.store(pipeline.pointer.y.bitPattern, ordering: .relaxed)
        displayW.store(pipeline.pointer.width.bitPattern, ordering: .relaxed)
        displayH.store(pipeline.pointer.height.bitPattern, ordering: .relaxed)
    }
}
