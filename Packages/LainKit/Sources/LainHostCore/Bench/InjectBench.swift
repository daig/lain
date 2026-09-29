#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import LainInput
import LainProtocol
import LainTelemetry
import Synchronization

/// `LainHost --bench inject` (S7, first M2 host checks). Needs Accessibility for LainHost.
/// Uses F18 for key tests: it exists on the HID path but types nothing and has no default binding.
/// Watches what macOS actually delivers with a listen-only event tap.
public enum InjectBench {
    static let f18Usage: UInt16 = 0x6D      // HID F18 → kVK_F18 0x4F

    struct Seen: Sendable {
        var type: CGEventType
        var keyCode: Int64
        var autorepeat: Int64
        var location: CGPoint
        var atNs: UInt64
    }

    final class Recorder: @unchecked Sendable {
        let events = Mutex<[Seen]>([])
        var tap: CFMachPort?
        func clear() { events.withLock { $0.removeAll() } }
        var all: [Seen] { events.withLock { $0 } }
    }

    public static func run() async -> Int32 {
        print("""
            Mac input settings (for HelloAck): key repeat delay \(MacInputSettings.keyRepeatDelayMs) ms, \
            interval \(MacInputSettings.keyRepeatIntervalMs) ms, double-click \(MacInputSettings.doubleClickIntervalMs) ms, \
            input source \(MacInputSettings.inputSourceID)
            """)
        guard InputInjector.hasAccess || InputInjector.requestAccess() else {
            print("""
                LainHost can't post events yet. In System Settings › Privacy & Security › Accessibility, turn on LainHost \
                (the prompt may have just opened it), then run this again.
                """)
            return 3
        }
        let recorder = Recorder()
        guard startTap(recorder) else {
            print("""
                Posting is allowed, but the listen-only event tap was refused. Grant LainHost Input Monitoring \
                (System Settings › Privacy & Security › Input Monitoring), then run this again.
                """)
            _ = CGRequestListenEventAccess()
            return 4
        }
        let injector = InputInjector(keyboardType: .ansi)
        try? await Task.sleep(for: .milliseconds(200))

        // 1. Pointer: move 40 pt right/down and back; read the real cursor location; tap latency.
        let start = CGEvent(source: nil)?.location ?? .zero
        let target = CGPoint(x: start.x + 40, y: start.y + 40)
        recorder.clear()
        let t0 = MonotonicClock.now()
        injector.move(PointerMove(x: target.x, y: target.y, dx: 40, dy: 40, buttons: 0))
        try? await Task.sleep(for: .milliseconds(50))
        let landed = CGEvent(source: nil)?.location ?? .zero
        let moveSeen = recorder.all.first { $0.type == .mouseMoved }
        injector.move(PointerMove(x: start.x, y: start.y, dx: -40, dy: -40, buttons: 0))
        print(String(format: "pointer: asked (%.0f, %.0f), cursor now (%.0f, %.0f) → %@; seen by tap %@",
                     target.x, target.y, landed.x, landed.y,
                     abs(landed.x - target.x) < 1 && abs(landed.y - target.y) < 1 ? "OK" : "MISMATCH",
                     moveSeen.map { String(format: "after %.0f µs", Double($0.atNs - t0) / 1000) } ?? "never"))

        // 1b. Injection latency: 50 one-point moves, 10 ms apart; post → seen by the session tap.
        var lat = RollingPercentiles(capacity: 50)
        var latMax = 0.0
        let base = CGEvent(source: nil)?.location ?? .zero
        for i in 0..<50 {
            recorder.clear()
            let posted = MonotonicClock.now()
            let p = CGPoint(x: base.x + Double(i % 2), y: base.y)
            injector.move(PointerMove(x: p.x, y: p.y, dx: 1, dy: 0, buttons: 0))
            try? await Task.sleep(for: .milliseconds(10))
            if let seen = recorder.all.first(where: { $0.type == .mouseMoved }) {
                let us = Double(seen.atNs - posted) / 1000
                lat.record(us)
                latMax = max(latMax, us)
            }
        }
        injector.move(PointerMove(x: base.x, y: base.y, dx: 0, dy: 0, buttons: 0))
        print(String(format: "injection latency (post → session tap, %d of 50 seen): p50 %.0f µs  p95 %.0f µs  max %.0f µs",
                     lat.sampleCount, lat.p50 ?? -1, lat.p95 ?? -1, latMax))

        // 2. S7a: hold F18 for 1.5 s with no repeats posted. Does macOS generate auto-repeat itself?
        recorder.clear()
        injector.key(KeyEvent(usage: f18Usage, isDown: true, modifiers: []))
        try? await Task.sleep(for: .milliseconds(1500))
        injector.key(KeyEvent(usage: f18Usage, isDown: false, modifiers: []))
        try? await Task.sleep(for: .milliseconds(100))
        let held = recorder.all.filter { $0.keyCode == 0x4F }
        let downs = held.filter { $0.type == .keyDown }
        print("S7a (synthetic key held 1.5 s, no repeats posted): \(downs.count) keyDown seen "
              + "(\(downs.filter { $0.autorepeat != 0 }.count) marked autorepeat), \(held.filter { $0.type == .keyUp }.count) keyUp "
              + "→ \(downs.count > 1 ? "macOS auto-repeats synthetic keys" : "no system auto-repeat: the client must generate repeats")")

        // 3. S7b: post our own repeats marked keyboardEventAutorepeat. Is the field preserved?
        recorder.clear()
        injector.key(KeyEvent(usage: f18Usage, isDown: true, modifiers: []))
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(30))
            injector.key(KeyEvent(usage: f18Usage, isDown: true, isRepeat: true, modifiers: []))
        }
        injector.key(KeyEvent(usage: f18Usage, isDown: false, modifiers: []))
        try? await Task.sleep(for: .milliseconds(100))
        let posted = recorder.all.filter { $0.keyCode == 0x4F && $0.type == .keyDown }
        print("S7b (1 down + 10 posted repeats): \(posted.count) keyDown seen, "
              + "\(posted.filter { $0.autorepeat != 0 }.count) with keyboardEventAutorepeat=1 "
              + "→ \(posted.filter { $0.autorepeat != 0 }.count == 10 ? "field preserved" : "field NOT preserved as posted")")

        // 4. ReleaseAll: hold F18 and Shift, release everything.
        recorder.clear()
        injector.key(KeyEvent(usage: 0xE1, isDown: true, modifiers: .shift))
        injector.key(KeyEvent(usage: f18Usage, isDown: true, modifiers: .shift))
        injector.releaseAll()
        try? await Task.sleep(for: .milliseconds(100))
        let ups = recorder.all.filter { $0.type == .keyUp || $0.type == .flagsChanged }
        let flagsAfter = CGEventSource.flagsState(.hidSystemState)
        print("releaseAll: \(ups.count) release events seen; shift still down afterwards: \(flagsAfter.contains(.maskShift))")
        return 0
    }

    /// A listen-only tap on its own run-loop thread.
    static func startTap(_ recorder: Recorder) -> Bool {
        let mask: CGEventMask = [CGEventType.keyDown, .keyUp, .flagsChanged, .mouseMoved]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            let r = Unmanaged<Recorder>.fromOpaque(info!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = r.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else {
                let seen = Seen(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                                autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat),
                                location: event.location, atNs: MonotonicClock.now())
                r.events.withLock { $0.append(seen) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(recorder).toOpaque()) else { return false }
        recorder.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let box = TapBox(tap)
        Thread.detachNewThread {
            let src = CFMachPortCreateRunLoopSource(nil, box.tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: box.tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        ready.wait()
        return true
    }

    final class TapBox: @unchecked Sendable {
        let tap: CFMachPort
        init(_ tap: CFMachPort) { self.tap = tap }
    }
}
#endif
