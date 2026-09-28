import Testing
@testable import LainTelemetry

/// Simulates one exchange with a remote clock `offset` ns ahead, given leg delays and hold time.
func exchange(_ e: inout ClockOffsetEstimator, at t0: UInt64, offset: Int64, up: UInt64, hold: UInt64, down: UInt64)
    -> ClockOffsetEstimator.Sample? {
    let t1 = UInt64(Int64(t0 + up) + offset)
    let t2 = t1 + hold
    let t3 = t0 + up + hold + down
    return e.add(t0: t0, t1: t1, t2: t2, t3: t3)
}

@Suite struct ClockOffset {
    @Test(arguments: [Int64(0), 5_000_000_000, -3_000_000_123])
    func symmetricDelaysAreExact(offset: Int64) throws {
        var e = ClockOffsetEstimator()
        let s = try #require(exchange(&e, at: 10_000_000_000, offset: offset, up: 400_000, hold: 50_000, down: 400_000))
        #expect(s.offsetNs == offset)
        #expect(s.rttNs == 800_000)
        #expect(e.offsetNs == offset)
    }

    @Test func asymmetricSamplesLoseToTheMinimumRTT() throws {
        var e = ClockOffsetEstimator(windowSize: 16)
        let offset: Int64 = 1_234_567
        // Slow, asymmetric exchanges (upload queued behind video) bias the estimate by (up − down)/2.
        for i in 0..<10 {
            let s = try #require(exchange(&e, at: UInt64(i) * 1_000_000_000 + 1, offset: offset,
                                          up: 3_000_000, hold: 10_000, down: 300_000))
            #expect(s.offsetNs == offset + 1_350_000)
        }
        // One quick, nearly symmetric exchange wins.
        _ = exchange(&e, at: 20_000_000_000, offset: offset, up: 200_000, hold: 10_000, down: 180_000)
        #expect(e.best?.rttNs == 380_000)
        #expect(e.offsetNs == offset + 10_000)
        #expect(abs(e.offsetNs! - offset) <= e.best!.rttNs / 2)
    }

    @Test func windowForgetsOldSamples() {
        var e = ClockOffsetEstimator(windowSize: 4)
        _ = exchange(&e, at: 1, offset: 0, up: 10, hold: 0, down: 10)          // best, then ages out
        for i in 1...4 { _ = exchange(&e, at: UInt64(i) * 1000, offset: 500, up: 100, hold: 0, down: 100) }
        #expect(e.sampleCount == 4)
        #expect(e.offsetNs == 500)
    }

    @Test func inconsistentTimestampsAreIgnored() {
        var e = ClockOffsetEstimator()
        #expect(e.add(t0: 100, t1: 50, t2: 40, t3: 200) == nil)     // remote sent before it received
        #expect(e.add(t0: 100, t1: 0, t2: 500, t3: 200) == nil)     // hold longer than the round trip
        #expect(e.offsetNs == nil)
    }

    @Test func convertsRemoteTimestamps() throws {
        var e = ClockOffsetEstimator()
        _ = exchange(&e, at: 1_000_000, offset: 250_000, up: 1000, hold: 0, down: 1000)
        #expect(e.toLocal(remoteNs: 5_250_000) == 5_000_000)
    }
}

@Suite struct Percentiles {
    @Test func nearestRank() {
        var p = RollingPercentiles(capacity: 100)
        for v in (1...100).reversed() { p.record(Double(v)) }
        #expect(p.p50 == 50)
        #expect(p.p95 == 95)
        #expect(p.percentile(0) == 1)
        #expect(p.percentile(1) == 100)
    }

    @Test func windowRollsOver() {
        var p = RollingPercentiles(capacity: 10)
        for _ in 0..<10 { p.record(1000) }
        for v in 1...10 { p.record(Double(v)) }
        #expect(p.sampleCount == 10)
        #expect(p.p50 == 5)
        #expect(p.p95 == 10)
    }

    @Test func emptyAndReset() {
        var p = RollingPercentiles(capacity: 4)
        #expect(p.p50 == nil)
        p.record(3)
        #expect(p.p95 == 3)
        p.reset()
        #expect(p.p50 == nil)
    }
}

@Test func signpostsDoNotCrash() {
    let state = Telemetry.pipeline.begin(.encode, frame: 1)
    Telemetry.pipeline.end(.encode, state)
    Telemetry.logger("test").debug("telemetry ok")
}
