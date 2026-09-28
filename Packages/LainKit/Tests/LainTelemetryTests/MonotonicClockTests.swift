import Testing
@testable import LainTelemetry

@Test func clockIsMonotonic() {
    var last = MonotonicClock.now()
    for _ in 0..<10_000 {
        let t = MonotonicClock.now()
        #expect(t >= last)
        last = t
    }
    #expect(last > 0)
}
