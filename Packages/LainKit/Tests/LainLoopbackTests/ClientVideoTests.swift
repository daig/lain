#if os(macOS)
import CoreVideo
import Foundation
import LainClientCore
import LainMedia
import LainProtocol
import LainTelemetry
import LainTestSupport
import LainTransport
import Metal
import Synchronization
import Testing

// MARK: Helpers

/// Records messages sent by the pipeline.
final class Outbox: Sendable {
    private let state = Mutex<[Message]>([])
    func send(_ m: Message) { state.withLock { $0.append(m) } }
    var all: [Message] { state.withLock { $0 } }
    var keyframeRequests: [KeyframeRequest] { all.compactMap { if case .keyframeRequest(let r) = $0 { r } else { nil } } }
    var acks: [UInt32] { all.compactMap { if case .frameAck(let a) = $0 { a.frameId } else { nil } } }
}

/// A decoder that succeeds (with a tiny buffer) or fails on chosen frame ids, synchronously.
final class FakeDecoder: FrameDecoding, @unchecked Sendable {
    let onOutput: @Sendable (VideoDecoder.Output) -> Void
    let failing: Mutex<Set<UInt32>>
    let decoded = Mutex<[UInt32]>([])
    let deferred = Mutex<[VideoDecoder.Output]>([])
    let holdOutputs: Bool
    nonisolated(unsafe) static let image = SyntheticFrames.makeBuffer(16, 16, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)

    init(failing: Set<UInt32>, holdOutputs: Bool, onOutput: @escaping @Sendable (VideoDecoder.Output) -> Void) {
        self.failing = Mutex(failing)
        self.holdOutputs = holdOutputs
        self.onOutput = onOutput
    }

    func decode(_ frame: VideoFrame) {
        decoded.withLock { $0.append(frame.frameId) }
        let fail = failing.withLock { $0.contains(frame.frameId) }
        let out = VideoDecoder.Output(frameId: frame.frameId, image: fail ? nil : Self.image, status: fail ? -12909 : 0,
                                      decodeDoneNs: MonotonicClock.now())
        if holdOutputs { deferred.withLock { $0.append(out) } } else { onOutput(out) }
    }

    /// Delivers held outputs (simulates asynchronous decode completing late).
    func release() {
        for out in deferred.withLock({ d in defer { d.removeAll() }; return d }) { onOutput(out) }
    }

    func finish() {}
}

final class FakeClock: Sendable {
    let ns = Atomic<UInt64>(1_000_000_000)
    func advance(ms: UInt64) { ns.add(ms * 1_000_000, ordering: .relaxed) }
    var now: UInt64 { ns.load(ordering: .relaxed) }
}

let fakeConfig = VideoConfig(configId: 1, codec: .hevc, chroma: .yuv444, bitDepth: 10, width: 16, height: 16, fullRange: true,
                             colorPrimaries: ColorTags.p3D65Primaries, transferFunction: ColorTags.sRGBTransfer,
                             matrix: ColorTags.bt709Matrix, parameterSets: [[1], [2], [3]])

func envelope(_ m: Message, seq: UInt32) -> Envelope {
    Envelope(header: FrameHeader(type: m.type, sequence: seq, timestampNs: 0, payloadLength: 0), message: m)
}

func frame(_ id: UInt32, key: Bool = false) -> Message {
    .videoFrame(VideoFrame(frameId: id, configId: 1, captureTimeNs: 0, encodeDoneNs: 0, isKeyframe: key, data: [0, 0, 0, 1, 0x26]))
}

/// A pipeline over fake decoders, with a sequence counter for the video channel.
final class FakeVideoRig: @unchecked Sendable {
    let clock = FakeClock()
    let out = Outbox()
    let decoders = Mutex<[FakeDecoder]>([])
    let failing: Set<UInt32>
    let holdOutputs: Bool
    var seq: UInt32 = 1
    var pipeline: ClientVideoPipeline!

    init(failing: Set<UInt32> = [], holdOutputs: Bool = false) {
        self.failing = failing
        self.holdOutputs = holdOutputs
        let clock = clock
        pipeline = ClientVideoPipeline(clock: { clock.now }) { [unowned self] _, _, onOutput in
            let d = FakeDecoder(failing: self.failing, holdOutputs: self.holdOutputs, onOutput: onOutput)
            decoders.withLock { $0.append(d) }
            return d
        }
        let out = out
        pipeline.connect(control: { out.send($0) }, video: { out.send($0) })
    }

    var decoder: FakeDecoder? { decoders.withLock { $0.last } }
    var decodedIds: [UInt32] { decoder?.decoded.withLock { $0 } ?? [] }

    func send(_ m: Message, skip: UInt32 = 0) {
        seq += skip
        pipeline.handleVideo(envelope(m, seq: seq))
        seq += 1
    }
}

// MARK: Pipeline

@Suite struct ClientVideoPipelineTests {
    @Test func configThenFramesDecodeAndAckOnReceipt() {
        let rig = FakeVideoRig()
        rig.send(.videoConfig(fakeConfig))
        rig.send(frame(1, key: true))
        rig.send(frame(2))
        rig.send(frame(3))
        #expect(rig.decodedIds == [1, 2, 3])
        #expect(rig.out.acks == [1, 2, 3])
        #expect(rig.out.keyframeRequests.isEmpty)
        #expect(rig.pipeline.latest.take()?.frameId == 3)
        #expect(rig.pipeline.hasVideo)
        let stats = rig.pipeline.stats()
        #expect(stats.framesReceived == 3 && stats.framesDecoded == 3 && stats.framesDropped == 0)
        #expect(stats.chroma == .yuv444 && stats.width == 16)
    }

    @Test func framesBeforeTheFirstKeyframeAreDroppedButAcked() {
        let rig = FakeVideoRig()
        rig.send(frame(1))                          // no config yet
        rig.send(.videoConfig(fakeConfig))
        rig.send(frame(2))                          // not a keyframe
        rig.send(frame(3, key: true))
        #expect(rig.decodedIds == [3])
        #expect(rig.out.acks == [1, 2, 3])          // backpressure never stalls on dropped frames
        #expect(rig.pipeline.stats().framesDropped == 2)
        #expect(rig.out.keyframeRequests.first?.reason == .startup)
    }

    @Test func sequenceGapRequestsKeyframeAndDropsUntilOne() {
        let rig = FakeVideoRig()
        rig.send(.videoConfig(fakeConfig))
        rig.send(frame(1, key: true))
        rig.send(frame(2))
        rig.send(frame(4), skip: 1)                 // message 3 never arrived
        rig.send(frame(5))
        rig.send(frame(6))
        #expect(rig.out.keyframeRequests == [KeyframeRequest(reason: .sequenceGap, lastGoodFrameId: 2)])
        #expect(rig.decodedIds == [1, 2])
        #expect(rig.out.acks == [1, 2, 4, 5, 6])
        rig.send(frame(7, key: true))
        rig.send(frame(8))
        #expect(rig.decodedIds == [1, 2, 7, 8])
        let stats = rig.pipeline.stats()
        #expect(stats.sequenceGaps == 1 && stats.framesDropped == 3 && !stats.awaitingKeyframe)
    }

    @Test func decodeErrorRequestsKeyframeAndDropsUntilOne() {
        let rig = FakeVideoRig(failing: [3])
        rig.send(.videoConfig(fakeConfig))
        rig.send(frame(1, key: true))
        rig.send(frame(2))
        rig.send(frame(3))                          // fails to decode
        rig.send(frame(4))
        #expect(rig.out.keyframeRequests == [KeyframeRequest(reason: .decodeError, lastGoodFrameId: 2)])
        #expect(rig.decodedIds == [1, 2, 3])
        rig.send(frame(5, key: true))
        #expect(rig.decodedIds == [1, 2, 3, 5])
        #expect(rig.pipeline.stats().decodeErrors == 1)
    }

    @Test func keyframeRequestsAreRateLimitedWhileWaiting() {
        let rig = FakeVideoRig()
        rig.send(.videoConfig(fakeConfig))
        rig.send(frame(1, key: true))
        rig.send(frame(3), skip: 1)
        rig.clock.advance(ms: 100)
        rig.send(frame(4))
        rig.send(frame(6), skip: 1)                 // another gap within 250 ms: no second request
        #expect(rig.out.keyframeRequests.count == 1)
        rig.clock.advance(ms: 200)                  // 300 ms since the request, still no keyframe
        rig.send(frame(7))
        #expect(rig.out.keyframeRequests.count == 2)
        // Scene became active: always sent at once.
        rig.pipeline.requestKeyframe(.resumed)
        #expect(rig.out.keyframeRequests.last?.reason == .resumed)
        #expect(rig.out.keyframeRequests.count == 3)
    }

    @Test func lateErrorsFromBeforeTheRecoveryKeyframeAreIgnored() {
        let rig = FakeVideoRig(failing: [2, 3], holdOutputs: true)
        rig.send(.videoConfig(fakeConfig))
        rig.send(frame(1, key: true))
        rig.send(frame(2))
        rig.decoder?.release()                      // 1 ok, 2 fails → request
        rig.send(frame(3, key: false))              // dropped
        rig.send(frame(4, key: true))               // recovery keyframe submitted
        #expect(rig.out.keyframeRequests.count == 1)
        rig.clock.advance(ms: 1000)
        // Frame 3 was dropped, but suppose a late error for an older frame arrives now: ignored.
        rig.decoder?.onOutput(VideoDecoder.Output(frameId: 2, image: nil, status: -12909, decodeDoneNs: 0))
        rig.decoder?.release()                      // keyframe 4 decodes
        #expect(rig.out.keyframeRequests.count == 1)
        #expect(rig.pipeline.latest.take()?.frameId == 4)
        #expect(!rig.pipeline.stats().awaitingKeyframe)
    }

    @Test func newConfigRecreatesTheDecoderAndStaleOutputIsIgnored() {
        let rig = FakeVideoRig(holdOutputs: true)
        rig.send(.videoConfig(fakeConfig))
        rig.send(frame(1, key: true))
        let first = rig.decoder
        var changed = fakeConfig
        changed.configId = 2
        changed.parameterSets = [[9], [9], [9]]
        rig.send(.videoConfig(changed))
        #expect(rig.decoders.withLock { $0.count } == 2)
        first?.release()                            // the old decoder's output arrives late
        #expect(rig.pipeline.latest.take() == nil)
        // Same parameter sets again: the decoder is kept.
        rig.send(.videoConfig(changed))
        #expect(rig.decoders.withLock { $0.count } == 2)
    }

    @Test func disconnectForgetsTheStream() {
        let rig = FakeVideoRig()
        rig.send(.videoConfig(fakeConfig))
        rig.send(frame(1, key: true))
        let generation = rig.pipeline.sessionGeneration
        rig.pipeline.disconnect()
        #expect(rig.pipeline.latest.take() == nil)
        #expect(!rig.pipeline.hasVideo)
        #expect(rig.pipeline.sessionGeneration != generation)
    }

    @Test func latestSlotKeepsOnlyTheNewest() {
        let slot = LatestSlot<Int>()
        #expect(slot.take() == nil)
        slot.put(1)
        slot.put(2)
        #expect(slot.put(3))
        #expect(slot.take() == 3)
        #expect(slot.take() == nil)
        #expect(slot.replaced == 2)
    }
}

// MARK: Cursor overlay

@Suite struct CursorOverlayTests {
    @Test func arrowUntilAShapeIsSelectedThenTheMacShape() {
        let overlay = CursorOverlay()
        #expect(overlay.current.sprite == .arrow && overlay.current.macVisible)
        let v0 = overlay.version
        let shape = CursorShape(shapeId: 7, pixelWidth: 2, pixelHeight: 2, scale: 2, hotspotX: 0.5, hotspotY: 0.5,
                                pixels: [UInt8](repeating: 255, count: 16))
        overlay.apply(.cursorShape(shape))
        #expect(overlay.current.sprite == .arrow)   // not selected yet
        overlay.apply(.cursorSelect(CursorSelect(shapeId: 7, visible: true)))
        #expect(overlay.version > v0)
        #expect(overlay.current.sprite.key == 7 && overlay.current.sprite.hotspotX == 0.5)
        overlay.apply(.cursorSelect(CursorSelect(shapeId: 7, visible: false)))
        #expect(!overlay.current.macVisible)
        overlay.reset()
        #expect(overlay.current.sprite == .arrow && overlay.current.macVisible)
    }

    @Test func typingHidesUntilThePointerMoves() {
        let overlay = CursorOverlay()
        #expect(!overlay.isHiddenForTyping)
        overlay.keyDown()
        #expect(overlay.isHiddenForTyping)
        overlay.pointerMoved()
        #expect(!overlay.isHiddenForTyping)
    }

    @Test func builtInArrowHasABlackBodyAndWhiteOutline() {
        let a = CursorSprite.arrow
        func px(_ x: Int, _ y: Int) -> [UInt8] { let o = (y * a.pixelWidth + x) * 4; return Array(a.pixels[o..<o + 4]) }
        #expect(px(4, 12) == [0, 0, 0, 255])        // inside, near the left edge's interior
        #expect(px(2, 2)[3] == 255)                 // at the tip: outline
        #expect(px(a.pixelWidth - 1, 0)[3] == 0)    // top right: transparent
    }
}

// MARK: Renderer

@Suite(.serialized) struct VideoRendererTests {
    @Test func contentRectIsOneToOneOrAspectFit() {
        let exact = VideoRenderer.contentRect(content: [2752, 2064], target: [2752, 2064])
        #expect(exact.origin == [0, 0] && exact.size == [2752, 2064])
        let fit = VideoRenderer.contentRect(content: [100, 50], target: [200, 200])
        #expect(fit.origin == [0, 50] && fit.size == [200, 100])
    }

    @Test func cursorSpriteDrawnAtItsPixelAndHiddenOffDisplay() throws {
        let renderer = try VideoRenderer(pixelFormat: .bgra8Unorm)
        // 2×2 pt red sprite at 2× (4×4 px), hotspot at its top-left.
        let red = CursorSprite(key: 99, pixelWidth: 4, pixelHeight: 4, scale: 2, hotspotX: 0, hotspotY: 0,
                               pixels: (0..<16).flatMap { _ in [0, 0, 255, 255] as [UInt8] })
        var scene = VideoRenderer.Scene(displayPointSize: [100, 75], cursorPoint: [10, 20], cursorSprite: red)
        let drawn = VideoRenderer.readBGRA8(try #require(renderer.renderOffscreen(scene, width: 200, height: 150)))
        func px(_ b: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { let o = (y * 200 + x) * 4; return Array(b[o..<o + 4]) }
        for y in 40..<44 { for x in 20..<24 { #expect(px(drawn, x, y) == [0, 0, 255, 255]) } }
        #expect(px(drawn, 19, 40) == [0, 0, 0, 255])
        #expect(px(drawn, 24, 41) == [0, 0, 0, 255])
        #expect(px(drawn, 21, 44) == [0, 0, 0, 255])

        scene.cursorPoint = nil                     // on another display
        let hidden = VideoRenderer.readBGRA8(try #require(renderer.renderOffscreen(scene, width: 200, height: 150)))
        #expect(stride(from: 0, to: hidden.count, by: 4).allSatisfy { hidden[$0 + 2] == 0 })
    }

    /// The colour path end to end: a Display P3 BGRA frame → `xf44` (BT.709 full range, as SCK
    /// delivers with lain's explicit colorMatrix) → real HEVC 4:4:4 encode → the client pipeline's real
    /// decoder → Metal YCbCr→RGB → compared with the ORIGINAL BGRA. A wrong matrix, range or transfer
    /// conversion would cost far more than the 35 dB threshold.
    @Test(arguments: [ChromaFormat.yuv444, .yuv420])
    func encodeDecodeRenderMatchesTheOriginal(chroma: ChromaFormat) async throws {
        let w = 640, h = 480
        let original = SyntheticFrames.scrollingText(width: w, height: h, count: 1)[0]
        let source = SyntheticFrames.convert([original], to: chroma.pixelFormat)[0]
        let encoded = Mutex<[VideoEncoder.Output]>([])
        var settings = VideoEncoder.Settings(width: w, height: h)
        settings.chroma = chroma
        let encoder = try VideoEncoder(settings: settings) { out in if let out { encoded.withLock { $0.append(out) } } }
        #expect(encoder.chroma == chroma)
        encoder.encode(source, frameId: 1, captureTimeNs: MonotonicClock.now())
        let out = try #require(await poll { encoded.withLock { $0.first } })
        let config = try #require(out.config)

        let sent = Outbox()
        let pipeline = ClientVideoPipeline()
        pipeline.connect(control: { sent.send($0) }, video: { sent.send($0) })
        pipeline.handleVideo(envelope(.videoConfig(config), seq: 1))
        pipeline.handleVideo(envelope(.videoFrame(VideoFrame(frameId: out.frameId, configId: config.configId,
                                                             captureTimeNs: out.captureTimeNs, encodeDoneNs: out.encodeDoneNs,
                                                             isKeyframe: out.isKeyframe, data: out.data)), seq: 2))
        let decoded = try #require(await poll { pipeline.latest.take() })
        #expect(sent.acks == [1] && sent.keyframeRequests.isEmpty)
        #expect(CVPixelBufferGetPixelFormatType(decoded.image) == chroma.pixelFormat)

        let renderer = try VideoRenderer(pixelFormat: .bgra8Unorm)
        let rendered = VideoRenderer.readBGRA8(try #require(renderer.renderOffscreen(VideoRenderer.Scene(frame: decoded),
                                                                                     width: w, height: h)))
        let psnr = bgraPSNR(rendered, original)
        print(String(format: "render %@ vs original BGRA: PSNR B %.1f G %.1f R %.1f dB", chroma == .yuv444 ? "4:4:4" : "4:2:0",
                     psnr[0], psnr[1], psnr[2]))
        let threshold = chroma == .yuv444 ? 35.0 : 25.0   // 4:2:0 loses chroma detail on coloured text by design
        #expect(psnr.allSatisfy { $0 >= threshold })
    }

    @Test func wrongMatrixIsCaught() async throws {
        // Guards the test above: rendering the same frame as BT.601 must fall well below the threshold.
        let w = 320, h = 240
        let original = SyntheticFrames.scrollingText(width: w, height: h, count: 1)[0]
        let source = SyntheticFrames.convert([original], to: ChromaFormat.yuv444.pixelFormat)[0]
        var frame = DecodedFrame(frameId: 1, image: source, format: FrameFormat(chroma: .yuv444, bitDepth: 10, fullRange: true,
                                                                                matrix: ColorTags.bt709Matrix))
        let renderer = try VideoRenderer(pixelFormat: .bgra8Unorm)
        let right = bgraPSNR(VideoRenderer.readBGRA8(try #require(renderer.renderOffscreen(.init(frame: frame), width: w, height: h))),
                             original)
        frame.format.matrix = 6
        let wrong = bgraPSNR(VideoRenderer.readBGRA8(try #require(renderer.renderOffscreen(.init(frame: frame), width: w, height: h))),
                             original)
        print(String(format: "no codec: BT.709 min %.1f dB, BT.601 min %.1f dB", right.min()!, wrong.min()!))
        #expect(right.allSatisfy { $0 >= 40 })
        #expect(wrong.min()! < right.min()! - 10)
    }
}

// MARK: Session

@Suite(.serialized) struct ClientSessionVideoTests {
    @Test func sessionDecodesFramesRoutesCursorShapesAndAcks() async throws {
        let video = ClientVideoPipeline()
        let session = try ClientSession(port: 0, secrets: InMemorySecretStore(), hello: videoHello, video: video) { _ in }
        defer { session.stop() }
        let (link, _, _) = try await HostLink.open(dialer: LoopbackDialer(port: session.port), secrets: InMemorySecretStore(),
                                                   peerID: "IPAD", allowPairing: true)
        defer { link.close() }
        let hostVideo = Outbox()
        link.video.setHandler { hostVideo.send($0.message) }

        let w = 256, h = 192
        let source = SyntheticFrames.convert(SyntheticFrames.scrollingText(width: w, height: h, count: 1),
                                             to: ChromaFormat.yuv444.pixelFormat)[0]
        let encoded = Mutex<[VideoEncoder.Output]>([])
        let encoder = try VideoEncoder(settings: VideoEncoder.Settings(width: w, height: h)) { out in
            if let out { encoded.withLock { $0.append(out) } }
        }
        encoder.encode(source, frameId: 1, captureTimeNs: MonotonicClock.now())
        let out = try #require(await poll { encoded.withLock { $0.first } })
        link.video.send(.videoConfig(try #require(out.config)))
        link.video.send(.videoFrame(VideoFrame(frameId: 1, configId: 1, captureTimeNs: out.captureTimeNs, encodeDoneNs: out.encodeDoneNs,
                                               isKeyframe: true, data: out.data)), flags: .keyframe)
        let frame = try #require(await poll { video.latest.take() })
        #expect(frame.frameId == 1 && frame.format.chroma == .yuv444)
        #expect(await poll { hostVideo.acks.first } == 1)

        link.realtime.send(.cursorShape(CursorShape(shapeId: 42, pixelWidth: 1, pixelHeight: 1, scale: 1, hotspotX: 0, hotspotY: 0,
                                                    pixels: [0, 0, 0, 255])))
        link.realtime.send(.cursorSelect(CursorSelect(shapeId: 42, visible: true)))
        #expect(await poll { video.cursor.current.sprite.key == 42 ? true : nil } == true)
    }
}

let videoHello = Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                       decodeCapabilities: [.hevcMain, .hevcMain44410Hardware], keyboardType: .ansi)

/// Polls `body` every 5 ms until it returns a value (nil after `seconds`).
func poll<T>(within seconds: Double = 5, _ body: () -> T?) async -> T? {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if let v = body() { return v }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return body()
}

/// Per-channel PSNR (B, G, R) between tightly packed BGRA bytes and a BGRA pixel buffer.
func bgraPSNR(_ rendered: [UInt8], _ original: CVPixelBuffer) -> [Double] {
    CVPixelBufferLockBaseAddress(original, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(original, .readOnly) }
    let w = CVPixelBufferGetWidth(original), h = CVPixelBufferGetHeight(original)
    let base = CVPixelBufferGetBaseAddress(original)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(original)
    var sse = [0.0, 0.0, 0.0]
    for y in 0..<h {
        for x in 0..<w {
            for c in 0..<3 {
                let d = Double(rendered[(y * w + x) * 4 + c]) - Double(base[y * stride + x * 4 + c])
                sse[c] += d * d
            }
        }
    }
    return sse.map { $0 == 0 ? 99 : 10 * log10(255 * 255 / ($0 / Double(w * h))) }
}

#endif
