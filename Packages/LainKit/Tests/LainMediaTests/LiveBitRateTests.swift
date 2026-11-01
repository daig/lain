import CoreVideo
import Foundation
import LainProtocol
import LainTestSupport
import Synchronization
import Testing
@testable import LainMedia

/// Adaptive bitrate relies on VideoToolbox taking a new rate mid-stream: the same scrolling text, at the
/// ceiling and then at a low target with its cap, must come out much smaller, without slowing the encoder.
@Suite(.serialized) struct LiveBitRateTests {
    func encode(_ encoder: VideoEncoder, _ frames: ArraySlice<CVPixelBuffer>, from id: Int,
                out: borrowing Mutex<[(bytes: Int, key: Bool, ms: Double)]>) async throws {
        for (i, f) in frames.enumerated() {
            let before = out.withLock { $0.count }
            encoder.encode(f, frameId: UInt32(id + i), captureTimeNs: UInt64(id + i) * 8_333_333)
            let deadline = Date().addingTimeInterval(2)
            while out.withLock({ $0.count }) == before, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        }
    }

    @Test func aLowerRateMidStreamShrinksTheFrames() async throws {
        let w = 2752, h = 2064, n = 60
        let bgra = SyntheticFrames.scrollingText(width: w, height: h, count: 2 * n, scroll: 8)
        let out = Mutex<[(bytes: Int, key: Bool, ms: Double)]>([])
        let encoder = try VideoEncoder(settings: VideoEncoder.Settings(width: w, height: h)) { o in
            guard let o else { return }
            out.withLock { $0.append((o.data.count, o.isKeyframe, Double(o.encodeDoneNs &- o.submitNs) / 1e6)) }
        }
        let frames = SyntheticFrames.convert(bgra, to: encoder.inputPixelFormat)
        try await encode(encoder, frames[0..<n], from: 1, out: out)
        encoder.setBitRate(average: 8_000_000, bytesPerSecondLimit: 8_000_000 / 8 * 3 / 2)
        try await encode(encoder, frames[n..<(2 * n)], from: n + 1, out: out)
        let all = out.withLock { $0 }
        #expect(all.count == 2 * n)
        let high = all[1..<n].map(\.bytes), low = all[(n + 10)...].map(\.bytes)   // the low rate settles first
        let highMean = high.reduce(0, +) / high.count, lowMean = low.reduce(0, +) / low.count
        let p95 = { (xs: [Int]) in xs.sorted()[xs.count * 95 / 100] }
        let ms = all[(n + 10)...].map(\.ms).sorted()[(n - 10) / 2]
        print("LIVE-RATE high mean \(highMean / 1024) KB p95 \(p95(high) / 1024) KB → low mean \(lowMean / 1024) KB p95 \(p95(low) / 1024) KB · encode p50 at the low rate \(String(format: "%.1f", ms)) ms")
        #expect(p95(low) * 2 < p95(high), "the big frames at least halve")
        #expect(ms < 16, "the encoder isn't slowed down")
    }
}
