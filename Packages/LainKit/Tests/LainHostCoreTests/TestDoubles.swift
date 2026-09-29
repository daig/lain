import CoreGraphics
import Dispatch
import LainProtocol
import Synchronization
@testable import LainHostCore

/// Records every sink call in order.
final class RecordingSink: InputSink {
    enum Call: Equatable, Sendable {
        case key(KeyEvent), move(PointerMove), button(PointerButton), scroll(Scroll), releaseAll
        case keyboardType(KeyboardType)
    }

    private let log = Mutex<[Call]>([])
    var calls: [Call] { log.withLock { $0 } }
    /// Only the input calls (keys, pointer, scroll, releaseAll).
    var inputCalls: [Call] {
        calls.filter {
            switch $0 {
            case .keyboardType: false
            default: true
            }
        }
    }
    func clear() { log.withLock { $0.removeAll() } }

    func key(_ event: KeyEvent) { log.withLock { $0.append(.key(event)) } }
    func move(_ move: PointerMove) { log.withLock { $0.append(.move(move)) } }
    func button(_ button: PointerButton) { log.withLock { $0.append(.button(button)) } }
    func scroll(_ scroll: Scroll) { log.withLock { $0.append(.scroll(scroll)) } }
    func releaseAll() { log.withLock { $0.append(.releaseAll) } }
    func setKeyboardType(_ type: KeyboardType) { log.withLock { $0.append(.keyboardType(type)) } }
}

final class RecordingPower: PowerAssertions {
    private struct State { var holding = false; var begins = 0; var ends = 0; var activity = 0 }
    private let state = Mutex(State())
    var holding: Bool { state.withLock { $0.holding } }
    var begins: Int { state.withLock { $0.begins } }
    var ends: Int { state.withLock { $0.ends } }
    var activityCount: Int { state.withLock { $0.activity } }

    func beginPreventingDisplaySleep() { state.withLock { $0.holding = true; $0.begins += 1 } }
    func endPreventingDisplaySleep() { state.withLock { $0.holding = false; $0.ends += 1 } }
    func declareUserActivity() { state.withLock { $0.activity += 1 } }
}

final class FakeDisplay: DisplayProvider {
    /// The target display; tests change it to simulate a resolution or arrangement change.
    let display: Mutex<HostDisplay>
    /// Global cursor location, or nil for "unknown" (no warps).
    let cursor: Mutex<CGPoint?>
    /// The desktop; nil: the target display alone (the protocol's default).
    let layout: Mutex<DisplayLayout?>

    init(display: HostDisplay, cursor: CGPoint?, layout: DisplayLayout? = nil) {
        self.display = Mutex(display)
        self.cursor = Mutex(cursor)
        self.layout = Mutex(layout)
    }

    func targetDisplay() -> HostDisplay { display.withLock { $0 } }
    func desktopLayout() -> DisplayLayout {
        if let l = layout.withLock({ $0 }) { return l }
        let d = targetDisplay()
        return DisplayLayout(displays: [.init(displayID: d.displayID, x: d.origin.x, y: d.origin.y,
                                              width: d.pointSize.width, height: d.pointSize.height, isStreamed: true)])
    }
    func cursorLocation() -> CGPoint? { cursor.withLock { $0 } }
}

/// Collects values from callbacks and lets tests await them.
final class Inbox<T: Sendable>: Sendable {
    private let state = Mutex<(items: [T], waiters: [(id: Int, c: CheckedContinuation<T?, Never>)], nextID: Int)>(([], [], 0))

    func put(_ v: T) {
        let waiter = state.withLock { s -> CheckedContinuation<T?, Never>? in
            if s.waiters.isEmpty { s.items.append(v); return nil }
            return s.waiters.removeFirst().c
        }
        waiter?.resume(returning: v)
    }

    /// The next value, or nil after `seconds`.
    func next(within seconds: Double = 5) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let (ready, id) = state.withLock { s -> (T?, Int) in
                if !s.items.isEmpty { return (s.items.removeFirst(), -1) }
                s.nextID += 1
                s.waiters.append((s.nextID, c))
                return (nil, s.nextID)
            }
            if let ready { c.resume(returning: ready); return }
            // Times out only this wait: a timer outliving an answered wait must not end a later one.
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                let timedOut = state.withLock { s -> CheckedContinuation<T?, Never>? in
                    guard let i = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return s.waiters.remove(at: i).c
                }
                timedOut?.resume(returning: nil)
            }
        }
    }

    /// Skips values until one matches, or nil on timeout.
    func first(within seconds: Double = 5, where match: (T) -> Bool) async -> T? {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            guard let v = await next(within: max(Double(deadline - now) / 1e9, 0.01)) else { return nil }
            if match(v) { return v }
        }
    }

    /// Waiters not yet answered or timed out (tests of this Inbox).
    var waiting: Int { state.withLock { $0.waiters.count } }
}

/// Polls `condition` until it holds or `seconds` pass.
func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
