#if os(macOS)
import CoreVideo
import Foundation
import LainMedia
import LainTelemetry
import Synchronization
import Testing

/// The encoder wrapper alone, timed like CodecBench (one frame in flight, 120 Hz pacing, no decoder
/// sharing the media engine), so pipeline numbers can be split into encoder cost and loopback contention.
@Test func encoderAloneMatchesCodecBench() async throws {
    let done = Mutex<[Double]>([])
    let signal = AsyncStream<Void>.makeStream()
    let submit = Mutex<UInt64>(0)
    let encoder = try VideoEncoder(settings: VideoEncoder.Settings(width: VideoPipeline.width, height: VideoPipeline.height)) { out in
        let t = MonotonicClock.now()
        if out != nil { done.withLock { $0.append(Double(t - submit.withLock { $0 }) / 1e6) } }
        signal.continuation.yield()
    }
    var it = signal.stream.makeAsyncIterator()
    let clock = ContinuousClock()
    for i in 0..<60 {
        let start = clock.now
        submit.withLock { $0 = MonotonicClock.now() }
        encoder.encode(pipelineSources[i % pipelineSources.count], frameId: UInt32(i + 1), captureTimeNs: 0)
        _ = await it.next()
        try await clock.sleep(until: start + .microseconds(8333))
    }
    let ms = Array(done.withLock { $0 }.dropFirst(2))
    let p = percentiles(ms)
    print(String(format: "encoder alone (LainMedia wrapper, 4:4:4 xf44, 10-frame cycle): p50 %.2f p95 %.2f ms", p.p50, p.p95))
    #expect(p.p50 < 12)
}
#endif
