import LainProtocol
import Testing
@testable import LainInput

private let frame: UInt64 = 8_333_333

/// Feeds a pan of `frames` changed samples at 120 Hz, each moving `dy` points; returns the end time.
private func pan(_ m: inout MomentumSynthesizer, dy: Double, frames: Int, start: UInt64 = 0) -> UInt64 {
    _ = m.touchBegan(at: start)
    var t = start
    for _ in 0..<frames {
        t += frame
        m.changed(dx: 0, dy: dy, at: t)
    }
    return t
}

@Suite struct Momentum {
    @Test func velocityComesFromRecentChangedSamples() throws {
        var m = MomentumSynthesizer()
        var t = pan(&m, dy: 1, frames: 30)            // slow start…
        for _ in 0..<10 { t += frame; m.changed(dx: 0, dy: 20, at: t) }   // …fast last 83 ms: 2400 pt/s
        let vResult = m.ended(at: t + 1_000_000)   // .ended itself carries no velocity
        let v = try #require(vResult)
        #expect(abs(v.y - 2400) < 1)
        #expect(v.x == 0)
    }

    @Test func pausingBeforeLiftMeansNoMomentum() {
        var m = MomentumSynthesizer()
        let t = pan(&m, dy: 20, frames: 10)
        let r1 = m.ended(at: t + 200_000_000)
        #expect(r1 == nil)
        #expect(!m.isActive)
    }

    @Test func slowPansDoNotFling() {
        var m = MomentumSynthesizer()
        let t = pan(&m, dy: 1, frames: 20)            // 120 pt/s
        let r2 = m.ended(at: t)
        #expect(r2 == nil)
    }

    @Test func emitsBeganChangedEndedWithDecay() throws {
        var m = MomentumSynthesizer()
        let t = pan(&m, dy: 20, frames: 10)
        let r3 = m.ended(at: t)
        #expect(r3 != nil)
        var events: [Scroll] = []
        var now = t
        while m.isActive, events.count < 1000 {
            now += frame
            if let e = m.tick(at: now) { events.append(e) }
        }
        #expect(events.first?.momentumPhase == .began)
        #expect(events.last?.momentumPhase == .ended)
        #expect(events.dropFirst().dropLast().allSatisfy { $0.momentumPhase == .changed })
        #expect(events.allSatisfy { $0.phase == GesturePhase.none })
        let deltas = events.dropLast().map { Double($0.dy) }
        #expect(zip(deltas, deltas.dropFirst()).allSatisfy { $0 > $1 })   // strictly decaying
        // Total glide ≈ v·τ(1 − e^(−T/τ)) ≈ 2400 · 0.5 minus the tail below the stop speed.
        let total = deltas.reduce(0, +)
        #expect(total > 1100 && total < 1200)
        let seconds = Double(now - t) / 1e9
        #expect(seconds > 2 && seconds < 3)            // τ·ln(2400/12) ≈ 2.65 s
    }

    @Test func translationCarriedByBeganCountsAsOneFrame() throws {
        // A short flick: `.began` already carries 8 pt (sent right after touchBegan), then two 8 pt
        // frames, lift. Real speed 8 pt per frame = 960 pt/s, not 24 pt / (1 + 2 frames) ms ≈ 1360.
        var m = MomentumSynthesizer()
        _ = m.touchBegan(at: 0)
        m.changed(dx: 0, dy: 8, at: 10_000)
        m.changed(dx: 0, dy: 8, at: 10_000 + frame)
        m.changed(dx: 0, dy: 8, at: 10_000 + 2 * frame)
        let result = m.ended(at: 10_000 + 2 * frame + 100_000)
        let v = try #require(result)
        #expect(abs(v.y - 960) < 1)
    }

    @Test func newTouchCancels() throws {
        var m = MomentumSynthesizer()
        let t = pan(&m, dy: 20, frames: 10)
        let r4 = m.ended(at: t)
        #expect(r4 != nil)
        _ = m.tick(at: t + frame)
        let cancelResult = m.touchBegan(at: t + 2 * frame)
        let cancel = try #require(cancelResult)
        #expect(cancel.momentumPhase == .ended)
        #expect(!m.isActive)
        let r5 = m.tick(at: t + 3 * frame)
        #expect(r5 == nil)
        let r6 = m.cancel()
        #expect(r6 == nil)
    }
}

@Suite struct KeyRepeat {
    let ms: UInt64 = 1_000_000
    let keyA = KeyEvent(usage: 0x04, isDown: true, modifiers: [])

    @Test func delayThenInterval() throws {
        var r = KeyRepeatGenerator(delayMs: 225, intervalMs: 30)
        r.observe(keyA, at: 0)
        let r7 = r.tick(at: 224 * ms)
        #expect(r7 == nil)
        let firstResult = r.tick(at: 225 * ms)
        let first = try #require(firstResult)
        #expect(first.isRepeat && first.isDown && first.usage == 0x04)
        let r8 = r.tick(at: 250 * ms)
        #expect(r8 == nil)
        let r9 = r.tick(at: 255 * ms)
        #expect(r9 != nil)
        let r10 = r.tick(at: 285 * ms)
        #expect(r10 != nil)
    }

    @Test func lateTicksNeverBurst() {
        var r = KeyRepeatGenerator(delayMs: 225, intervalMs: 30)
        r.observe(keyA, at: 0)
        let r11 = r.tick(at: 1000 * ms)
        #expect(r11 != nil)
        let r12 = r.tick(at: 1000 * ms)
        #expect(r12 == nil)
        let r13 = r.tick(at: 1029 * ms)
        #expect(r13 == nil)
        let r14 = r.tick(at: 1030 * ms)
        #expect(r14 != nil)
    }

    @Test func keyUpStopsAndOnlyLatestKeyRepeats() {
        var r = KeyRepeatGenerator()
        r.observe(keyA, at: 0)
        r.observe(KeyEvent(usage: 0x05, isDown: true, modifiers: []), at: 10 * ms)
        r.observe(KeyEvent(usage: 0x04, isDown: false, modifiers: []), at: 20 * ms)   // A up: B keeps going
        let r15 = r.tick(at: 500 * ms)
        #expect(r15?.usage == 0x05)
        r.observe(KeyEvent(usage: 0x05, isDown: false, modifiers: []), at: 600 * ms)
        #expect(!r.isRepeating)
    }

    @Test func modifiersNeverRepeatButUpdateTheRepeatingKey() {
        var r = KeyRepeatGenerator()
        r.observe(KeyEvent(usage: 0xE1, isDown: true, modifiers: .shift), at: 0)
        #expect(!r.isRepeating)
        r.observe(keyA, at: 0)
        r.observe(KeyEvent(usage: 0xE1, isDown: true, modifiers: .shift), at: 1)
        let r16 = r.tick(at: 300 * ms)
        #expect(r16?.modifiers == .shift)
        r.cancel()
        let r17 = r.tick(at: 900 * ms)
        #expect(r17 == nil)
    }
}
