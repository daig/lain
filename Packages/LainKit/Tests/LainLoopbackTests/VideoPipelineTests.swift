#if os(macOS)
import CoreVideo
import Foundation
import LainMedia
import LainProtocol
import LainTelemetry
import LainTestSupport
import LainTransport
import Synchronization
import Testing

/// Step 6: the Mac side of the M3 video path without screen capture. Synthetic scrolling text →
/// FrameGate (latest-wins, ack-gated) → real HEVC encoder → framing → in-memory link → real decoder,
/// with the client acking each frame as it arrives (§7.3).
final class VideoPipeline: @unchecked Sendable {
    static let width = 2752, height = 2064

    struct Item: Sendable { var id: UInt32; var source: Int; var captureNs: UInt64; var refinement: Bool }

    struct Record {
        var source = 0
        var captureNs: UInt64 = 0
        var submitNs: UInt64 = 0
        var encodeDoneNs: UInt64 = 0
        var sentNs: UInt64 = 0
        var receivedNs: UInt64 = 0
        var decodedNs: UInt64 = 0
        var bytes = 0
        var keyframe = false
        var refinement = false
        var decodeStatus: OSStatus?
        var image: CVPixelBuffer?
    }

    let sources: [CVPixelBuffer]
    let ackDelayMs: Int
    let keepImages: Set<Int>?
    let host: MessageChannel
    let client: MessageChannel
    let encoder: VideoEncoder
    private(set) var gate: FrameGate<Item>!
    let records = Mutex<[UInt32: Record]>([:])
    let decoderBox = Mutex<VideoDecoder?>(nil)
    let configs = Mutex<[VideoConfig]>([])

    init(sources: [CVPixelBuffer], ackDelayMs: Int, keepImages: Set<Int>? = nil) throws {
        self.sources = sources
        self.ackDelayMs = ackDelayMs
        self.keepImages = keepImages
        let (a, b) = MemoryStream.pair()
        host = MessageChannel(stream: a, label: "host.video", version: LainProtocol.newestVersion)
        client = MessageChannel(stream: b, label: "client.video", version: LainProtocol.newestVersion)
        let box = WeakRef<VideoPipeline>()
        encoder = try VideoEncoder(settings: VideoEncoder.Settings(width: Self.width, height: Self.height)) { out in
            box.value?.encoded(out)
        }
        box.value = self
        gate = FrameGate(maxInFlight: 2) { [unowned self] item in
            records.withLock { $0[item.id, default: Record()].submitNs = MonotonicClock.now() }
            encoder.encode(self.sources[item.source], frameId: item.id, captureTimeNs: item.captureNs, refinement: item.refinement)
        }
        host.setHandler { [unowned self] env in
            if case .frameAck(let ack) = env.message { gate.acked(frameId: ack.frameId) }
        }
        client.setHandler { [unowned self] env in received(env) }
        host.start()
        client.start()
    }

    func offer(source: Int, id: UInt32, refinement: Bool = false) {
        let now = MonotonicClock.now()
        records.withLock { $0[id] = Record(source: source, captureNs: now, refinement: refinement) }
        gate.offer(Item(id: id, source: source, captureNs: now, refinement: refinement))
    }

    private func encoded(_ out: VideoEncoder.Output?) {
        guard let out else { gate.encodeFailed(); return }
        if let config = out.config {
            configs.withLock { $0.append(config) }
            host.send(.videoConfig(config))
        }
        var flags: HeaderFlags = out.isKeyframe ? .keyframe : []
        if out.isRefinement { flags.insert(.refinement) }
        host.send(.videoFrame(VideoFrame(frameId: out.frameId, configId: 1, captureTimeNs: out.captureTimeNs,
                                         encodeDoneNs: out.encodeDoneNs, isKeyframe: out.isKeyframe, data: out.data)), flags: flags)
        let sent = MonotonicClock.now()
        records.withLock { r in
            r[out.frameId]?.encodeDoneNs = out.encodeDoneNs
            r[out.frameId]?.sentNs = sent
            r[out.frameId]?.bytes = out.data.count
            r[out.frameId]?.keyframe = out.isKeyframe
        }
        gate.sent(frameId: out.frameId)
    }

    /// Client side, on the video connection's queue.
    private func received(_ env: Envelope) {
        switch env.message {
        case .videoConfig(let config):
            decoderBox.withLock { d in
                d = try? VideoDecoder(config: config) { [weak self] out in self?.decoded(out) }
            }
        case .videoFrame(let frame):
            let now = MonotonicClock.now()
            records.withLock { $0[frame.frameId]?.receivedNs = now }
            let ack = Message.frameAck(FrameAck(frameId: frame.frameId, receivedAtNs: now, bytes: UInt32(frame.data.count)))
            if ackDelayMs == 0 { client.send(ack) } else {
                client.queue.asyncAfter(deadline: .now() + .milliseconds(ackDelayMs)) { [client] in client.send(ack) }
            }
            decoderBox.withLock { $0 }?.decode(frame)
        default:
            break
        }
    }

    private func decoded(_ out: VideoDecoder.Output) {
        let now = MonotonicClock.now()
        records.withLock { r in
            r[out.frameId]?.decodedNs = now
            r[out.frameId]?.decodeStatus = out.status
            if keepImages?.contains(Int(out.frameId)) ?? true { r[out.frameId]?.image = out.image }
        }
    }

    /// Waits until every encoded frame has been decoded (or failed).
    func drain(timeout: Double = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let pending = records.withLock { r in r.values.contains { $0.sentNs != 0 && $0.decodeStatus == nil } }
            if !pending && !gate.slotOccupied && gate.inFlight == 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        decoderBox.withLock { $0 }?.finish()
    }

    var decoder: VideoDecoder? { decoderBox.withLock { $0 } }
    var all: [(UInt32, Record)] { records.withLock { $0.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } } }
}

final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

/// Offers frames at `hz` on a fixed schedule, like a display-linked capture callback.
func capture(_ p: VideoPipeline, frames: Int, hz: Double = 120, firstId: UInt32 = 1) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    for i in 0..<frames {
        p.offer(source: i % p.sources.count, id: firstId + UInt32(i))
        try await clock.sleep(until: start + .nanoseconds(Int64(Double(i + 1) * 1e9 / hz)))
    }
}

func ms(_ ns: UInt64) -> Double { Double(ns) / 1e6 }

func percentiles(_ values: [Double]) -> (p50: Double, p95: Double) {
    var r = RollingPercentiles(capacity: max(values.count, 1))
    values.forEach { r.record($0) }
    return (r.p50 ?? 0, r.p95 ?? 0)
}

/// Built once: 10 unique scrolling-text frames in `xf44` (~34 MB each).
/// Read-only after creation; the buffers are never written again.
nonisolated(unsafe) let pipelineSources: [CVPixelBuffer] = SyntheticFrames.convert(
    SyntheticFrames.scrollingText(width: VideoPipeline.width, height: VideoPipeline.height, count: 10),
    to: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)

@Suite(.serialized) struct VideoPipelineTests {
    @Test func fourFourFourEndToEndWithIntegrityAndTiming() async throws {
        let p = try VideoPipeline(sources: pipelineSources, ackDelayMs: 0, keepImages: Set(stride(from: 1, through: 60, by: 6)))
        #expect(p.encoder.chroma == .yuv444)
        try await capture(p, frames: 60)
        await p.drain()

        // 4:4:4 on the wire: the config says so, and the client's rebuilt format description agrees.
        let config = try #require(p.configs.withLock { $0.first })
        #expect(config.chroma == .yuv444 && config.bitDepth == 10)
        #expect(config.parameterSets.count == 3)   // VPS, SPS, PPS
        let decoder = try #require(p.decoder)
        #expect(decoder.chromaFormatIDC == 3)

        let sent = p.all.filter { $0.1.sentNs != 0 }
        #expect(sent.count >= 30)                              // 120 Hz offered; the encoder takes ~8 ms
        #expect(sent.allSatisfy { $0.1.decodeStatus == noErr })
        #expect(sent.first?.1.keyframe == true)
        #expect(sent.dropFirst().allSatisfy { !$0.1.keyframe })

        // Integrity against the source frame each one was encoded from.
        var worst = (luma: 99.0, chroma: 99.0)
        for (_, r) in sent {
            guard let image = r.image else { continue }
            #expect(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
            let q = ImageCompare.psnr444(image, p.sources[r.source], rowStep: 4)
            worst = (min(worst.luma, q.luma), min(worst.chroma, q.chroma))
        }
        #expect(worst.luma > 38 && worst.chroma > 38)

        let gate = p.gate.stats
        #expect(gate.peakInFlight <= 2)
        let encode = percentiles(sent.map { ms($0.1.encodeDoneNs - $0.1.submitNs) })
        let wait = percentiles(sent.map { ms($0.1.submitNs - $0.1.captureNs) })
        let transfer = percentiles(sent.map { ms($0.1.receivedNs - $0.1.sentNs) })
        let decode = percentiles(sent.map { ms($0.1.decodedNs - $0.1.receivedNs) })
        let total = percentiles(sent.map { ms($0.1.decodedNs - $0.1.captureNs) })
        let pBytes = sent.dropFirst().map { $0.1.bytes }
        print(String(format: """
            pipeline 2752×2064 4:4:4 @120 Hz offered, fast client: %d/%d frames encoded, %d dropped before encode, peak in flight %d
              slot wait p50 %.2f p95 %.2f | encode p50 %.2f p95 %.2f | framing+transfer p50 %.2f p95 %.2f | decode p50 %.2f p95 %.2f | capture→decoded p50 %.2f p95 %.2f ms
              keyframe %d KB, P-frames avg %d KB | worst PSNR luma %.1f dB chroma %.1f dB
            """, gate.encoded, gate.offered, gate.droppedBeforeEncode, gate.peakInFlight, wait.p50, wait.p95, encode.p50, encode.p95,
            transfer.p50, transfer.p95, decode.p50, decode.p95, total.p50, total.p95, (sent.first?.1.bytes ?? 0) / 1024,
            pBytes.reduce(0, +) / max(pBytes.count, 1) / 1024, worst.luma, worst.chroma))
    }

    @Test func slowClientNeverGrowsAQueue() async throws {
        // The client acks 40 ms after each frame arrives: far slower than 120 Hz.
        let p = try VideoPipeline(sources: pipelineSources, ackDelayMs: 40, keepImages: [])
        try await capture(p, frames: 120)
        await p.drain()
        let gate = p.gate.stats
        let sent = p.all.filter { $0.1.sentNs != 0 }
        #expect(gate.peakInFlight <= 2)
        #expect(gate.droppedBeforeEncode > 60)          // frames dropped before encoding, never after
        #expect(sent.count == gate.encoded)
        #expect(sent.allSatisfy { $0.1.receivedNs != 0 && $0.1.decodeStatus == noErr })
        // Latency doesn't creep up over the run: the last third is no worse than the first third.
        let third = sent.count / 3
        let early = percentiles(sent.prefix(third).map { ms($0.1.receivedNs - $0.1.captureNs) })
        let late = percentiles(sent.suffix(third).map { ms($0.1.receivedNs - $0.1.captureNs) })
        #expect(late.p50 <= early.p50 + 10)
        print(String(format: "pipeline, slow client (ack +40 ms): %d/%d encoded, %d dropped before encode, peak in flight %d; "
                     + "capture→received p50 first third %.1f ms, last third %.1f ms",
                     gate.encoded, gate.offered, gate.droppedBeforeEncode, gate.peakInFlight, early.p50, late.p50))
    }

    @Test func idleRefinementSharpensStaticContent() async throws {
        let p = try VideoPipeline(sources: pipelineSources, ackDelayMs: 0)
        // Motion first, so the static frame starts as a P-frame after a scroll (the realistic case).
        try await capture(p, frames: 10)
        await p.drain()
        var refiner = IdleRefiner()
        let still = 3
        p.offer(source: still, id: 100)
        refiner.newFrame(at: MonotonicClock.now())
        var id: UInt32 = 101
        let deadline = MonotonicClock.now() + 500_000_000
        while MonotonicClock.now() < deadline {
            if refiner.shouldRefine(at: MonotonicClock.now()) {
                p.offer(source: still, id: id, refinement: true)
                id += 1
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        await p.drain()
        let frames = p.all.filter { $0.0 >= 100 && $0.1.image != nil }
        #expect(frames.count == 3)                                  // the frame plus two refinements
        let q = frames.map { ImageCompare.psnr444($0.1.image!, p.sources[still], rowStep: 4) }
        #expect(q.count == 3 && q[2].luma >= q[0].luma - 0.1)
        print(String(format: "idle refinement: luma PSNR %@ dB; sizes %@ KB", q.map { String(format: "%.2f", $0.luma) }.joined(separator: " → "),
                     frames.map { "\($0.1.bytes / 1024)" }.joined(separator: " → ")))
    }
}
#endif
