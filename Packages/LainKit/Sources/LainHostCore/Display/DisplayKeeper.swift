import Foundation
import LainTelemetry
import Synchronization

/// A display the keeper can hold between sessions.
public protocol KeepableDisplay: AnyObject, Sendable {
    /// Still on the desktop, so a new session can stream it.
    var isUsable: Bool { get }
    /// Removes it, and waits (bounded) until the window server no longer lists it.
    func remove() async
    /// Synchronous teardown for app quit / emergency host restore: unmirrors and drops the display immediately.
    func releaseNow()
}

public extension KeepableDisplay {
    func releaseNow() {}
}

/// The display keep-alive (rust/HOST-PARITY.md §1; Linux `lain-host`'s `DisplayKeeper`): lain's display
/// outlives a session that ended because its link went away (the iPad's app left the screen, the cable came
/// out, a USB takeover from Wi-Fi), for `keepFor`, so the next session of the same kind (`key`) takes it back
/// instead of rebuilding it. The desktop isn't re-laid out twice: windows stay where they are, and a headless
/// Mac keeps a screen.
///
/// Only a pipeline that was stopped hands its display here; one whose capture failed removes it, and so
/// does everything once the host stops (`close`). Nothing captures or encodes a kept display, and input and
/// power were already released by the session's end. At most one display exists: a kept one is taken back or
/// removed (and waited out) before another is created.
public final class DisplayKeeper: Sendable {
    private struct Kept {
        var display: any KeepableDisplay
        var key: String
        var generation: UInt64
        var expiry: Task<Void, Never>
    }
    private struct State {
        var keepFor: Duration
        var kept: Kept?
        var closed = false
        var generation: UInt64 = 0
        /// Removals in progress, chained: a new display waits for them (they share one identity).
        var removing: Task<Void, Never>?
    }
    private let state: Mutex<State>
    /// Held while a display is kept so a clamshell MacBook stays awake during brief iPhone app-switches,
    /// and released immediately when the display is taken, expires, or is cleared/closed.
    private let power: (any PowerAssertions)?
    private let log = Telemetry.logger("vdisplay")

    public init(keepFor: Duration, power: (any PowerAssertions)? = nil) {
        state = Mutex(State(keepFor: max(keepFor, .zero)))
        self.power = power
    }

    deinit {
        let hadKept = state.withLock { s -> Bool in
            guard let k = s.kept else { return false }
            k.expiry.cancel()
            s.kept = nil
            return true
        }
        if hadKept { power?.endPreventingDisplaySleep() }
    }

    /// For the next display kept (one kept now keeps its time).
    public var keepFor: Duration {
        get { state.withLock { $0.keepFor } }
        set { state.withLock { $0.keepFor = max(newValue, .zero) } }
    }

    /// Whether a display is kept now.
    public var isHolding: Bool { state.withLock { $0.kept != nil } }

    /// Keeps `display` for the next session asking for `key`. false: not kept (keep-alive off, or the host
    /// is stopping), and the caller removes it.
    public func keep(_ display: any KeepableDisplay, key: String) -> Bool {
        let (kept, previous, tookPower) = state.withLock { s -> (Bool, (any KeepableDisplay)?, Bool) in
            guard !s.closed, s.keepFor > .zero else { return (false, nil, false) }
            // Not expected (one display at a time), but never lose track of one.
            let previous = s.kept.map { k in k.expiry.cancel(); return k.display }
            s.generation &+= 1
            let generation = s.generation, keepFor = s.keepFor
            let expiry = Task { [weak self] in
                try? await Task.sleep(for: keepFor)
                guard !Task.isCancelled else { return }
                await self?.expire(generation)
            }
            s.kept = Kept(display: display, key: key, generation: generation, expiry: expiry)
            return (true, previous, previous == nil)
        }
        if tookPower { power?.beginPreventingDisplaySleep() }
        if let previous { _ = startRemoval(previous) }
        if kept { log.notice("keeping lain's display for \(self.keepFor, privacy: .public) for the iPad's return") }
        return kept
    }

    /// The kept display if it was made for `key` and is still usable; any other kept display is removed
    /// first (awaited), so the caller may create one.
    public func take(key: String) async -> (any KeepableDisplay)? {
        guard let kept = state.withLock({ s -> Kept? in defer { s.kept = nil }; return s.kept }) else {
            await waitForRemovals()   // an expiry may be removing the last one
            return nil
        }
        power?.endPreventingDisplaySleep()
        kept.expiry.cancel()
        let closed = state.withLock { $0.closed }
        if kept.key == key, !closed, kept.display.isUsable {
            log.notice("reusing the kept display")
            return kept.display
        }
        log.notice("removing the kept display: \(kept.key == key ? "no longer usable" : "the new session wants another", privacy: .public)")
        await startRemoval(kept.display).value
        return nil
    }

    /// Waits until no removal is in progress (an expiry, say): call before creating a display.
    public func waitForRemovals() async {
        await state.withLock { $0.removing }?.value
    }

    /// The host is stopping: nothing is kept from now on, and a kept display is removed (awaited).
    public func close() async {
        let kept = state.withLock { s -> Kept? in
            s.closed = true
            defer { s.kept = nil }
            return s.kept
        }
        if let kept {
            power?.endPreventingDisplaySleep()
            kept.expiry.cancel()
            _ = startRemoval(kept.display)
        }
        await waitForRemovals()
    }

    /// Synchronous close for app termination: refuses further keeps and immediately releases any kept display.
    public func closeSync() {
        let kept = state.withLock { s -> Kept? in
            s.closed = true
            defer { s.kept = nil }
            return s.kept
        }
        if let kept {
            power?.endPreventingDisplaySleep()
            kept.expiry.cancel()
            kept.display.releaseNow()
        }
    }

    /// Synchronous clear for emergency host restore: immediately releases any kept display while keeping goes on.
    public func clearSync() {
        let kept = state.withLock { s -> Kept? in defer { s.kept = nil }; return s.kept }
        if let kept {
            power?.endPreventingDisplaySleep()
            kept.expiry.cancel()
            kept.display.releaseNow()
        }
    }

    /// Removes a kept display now, if any (awaited); keeping goes on.
    public func clear() async {
        let kept = state.withLock { s -> Kept? in defer { s.kept = nil }; return s.kept }
        if let kept {
            power?.endPreventingDisplaySleep()
            kept.expiry.cancel()
            _ = startRemoval(kept.display)
        }
        await waitForRemovals()
    }

    private func expire(_ generation: UInt64) async {
        let kept = state.withLock { s -> Kept? in
            guard let k = s.kept, k.generation == generation else { return nil }
            s.kept = nil
            return k
        }
        guard let kept else { return }
        power?.endPreventingDisplaySleep()
        log.notice("the iPad didn't come back in time; removing lain's display")
        await startRemoval(kept.display).value
    }

    /// Removes `display` after any removal already under way.
    private func startRemoval(_ display: any KeepableDisplay) -> Task<Void, Never> {
        state.withLock { s in
            let previous = s.removing
            let task = Task {
                await previous?.value
                await display.remove()
            }
            s.removing = task
            return task
        }
    }
}
