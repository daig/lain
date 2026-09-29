import Synchronization

/// A latest-wins single slot (§4): the producer overwrites, the consumer takes the newest. Nothing
/// ever queues behind it. The lock is held only for a pointer swap.
public final class LatestSlot<Value: Sendable>: Sendable {
    private let state = Mutex<Value?>(nil)
    private let replacedCount = Atomic<Int>(0)

    public init() {}

    /// Stores `value`; returns true when it replaced one the consumer never took.
    @discardableResult
    public func put(_ value: Value) -> Bool {
        let old = state.withLock { s -> Value? in
            defer { s = value }
            return s
        }
        if old != nil { replacedCount.add(1, ordering: .relaxed) }
        return old != nil
    }

    /// The newest value, emptying the slot (nil when nothing new arrived).
    public func take() -> Value? { state.withLock { s in defer { s = nil }; return s } }

    public var isEmpty: Bool { state.withLock { $0 == nil } }

    public func clear() { state.withLock { $0 = nil } }

    /// Values overwritten before the consumer took them.
    public var replaced: Int { replacedCount.load(ordering: .relaxed) }
}
