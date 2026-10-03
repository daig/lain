#if os(macOS)
import CoreGraphics
import CoreVideo
import Foundation
import LainHostCore
import LainMedia
import LainProtocol
import LainTelemetry
import LainTestSupport
import LainTransport
import Synchronization
import Testing

// M3 host video: the real `HostVideoPipeline` and `VideoEncoder`, with a fake display and a fake frame
// source feeding synthetic frames, into a MemoryStream-backed video channel whose client end acks
// (and decodes). No virtual display, no ScreenCaptureKit, no TCC.

private let testWidth = 1376, testHeight = 1032

/// Synthetic scrolling text with every attachment removed, like an SCK frame without a YCbCr matrix
/// (the pipeline must tag it). Read-only after creation.
private func untagged(_ format: OSType) -> [CVPixelBuffer] {
    let frames = SyntheticFrames.convert(SyntheticFrames.scrollingText(width: testWidth, height: testHeight, count: 6), to: format)
    frames.forEach { CVBufferRemoveAllAttachments($0) }
    return frames
}
nonisolated(unsafe) private let frames444 = untagged(kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
nonisolated(unsafe) private let frames420 = untagged(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

final class FakeStreamedDisplay: StreamedDisplayProvider {
    let display = StreamedDisplay(displayID: 4242, pixelWidth: testWidth, pixelHeight: testHeight,
                                  bounds: CGRect(x: -688, y: 0, width: 688, height: 516), refreshRate: 120)
    let createDelayMs: Int
    private let counts = Mutex((created: 0, destroyed: 0, alive: false))
    init(createDelayMs: Int = 0) { self.createDelayMs = createDelayMs }

    var created: Int { counts.withLock { $0.created } }
    var destroyed: Int { counts.withLock { $0.destroyed } }
    var alive: Bool { counts.withLock { $0.alive } }

    func create() async throws -> StreamedDisplay {
        counts.withLock { $0.created += 1; $0.alive = true }
        if createDelayMs > 0 { try await Task.sleep(for: .milliseconds(createDelayMs)) }
        return display
    }
    func currentBounds() -> CGRect? { alive ? display.bounds : nil }
    func destroy() {
        counts.withLock { c in
            if c.alive { c.destroyed += 1 }
            c.alive = false
        }
    }
}

final class FakeFrameSource: FrameSource {
    let queue = DispatchQueue(label: "test.capture", qos: .userInteractive)
    private struct State {
        var config: FrameSourceConfig?
        var onFrame: (@Sendable (CVPixelBuffer, UInt64) -> Void)?
        /// Kept after stop, to prove the pipeline ignores late frames.
        var everOnFrame: (@Sendable (CVPixelBuffer, UInt64) -> Void)?
        var stops = 0
        var delivered = 0
    }
    private let state = Mutex(State())
    var config: FrameSourceConfig? { state.withLock { $0.config } }
    var stops: Int { state.withLock { $0.stops } }
    var delivered: Int { state.withLock { $0.delivered } }

    func start(_ config: FrameSourceConfig, onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
               onError: @escaping @Sendable (any Error) -> Void) async throws {
        state.withLock { $0.config = config; $0.onFrame = onFrame; $0.everOnFrame = onFrame }
    }

    func stop() async { state.withLock { $0.stops += 1; $0.onFrame = nil } }

    /// Delivers a frame on the capture queue, as SCK would (only while started).
    func emit(_ buffer: CVPixelBuffer, ignoringStop: Bool = false) {
        let handler = state.withLock { s -> (@Sendable (CVPixelBuffer, UInt64) -> Void)? in
            let h = ignoringStop ? s.everOnFrame : s.onFrame
            if h != nil { s.delivered += 1 }
            return h
        }
        guard let handler else { return }
        let box = BufferBox(buffer)
        queue.async { handler(box.buffer, MonotonicClock.now()) }
    }

    /// Emits `count` frames at `hz`, cycling through `buffers`. Returns the time of the last one.
    @discardableResult
    func feed(_ buffers: [CVPixelBuffer], count: Int, hz: Double = 120) async throws -> UInt64 {
        let clock = ContinuousClock()
        let start = clock.now
        var last: UInt64 = 0
        for i in 0..<count {
            emit(buffers[i % buffers.count])
            last = MonotonicClock.now()
            try await clock.sleep(until: start + .nanoseconds(Int64(Double(i + 1) * 1e9 / hz)))
        }
        return last
    }
}

struct BufferBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ b: CVPixelBuffer) { buffer = b }
}

final class FakeCursor: CursorImageSource {
    let image = CursorImage(pixelWidth: 2, pixelHeight: 2, scale: 2, hotspotX: 0.5, hotspotY: 0.5, pixels: [UInt8](repeating: 255, count: 16))
    func currentCursor() -> CursorImage? { image }
}

/// The iPad end of the video connection: records everything, acks each frame on arrival (optionally
/// late), and decodes.
final class VideoClient: @unchecked Sendable {
    struct Received {
        var envelope: Envelope
        var atNs: UInt64
    }
    let host: MessageChannel
    let channel: MessageChannel
    let ackDelayMs: Int
    let received = Mutex<[Received]>([])
    let decoder = Mutex<VideoDecoder?>(nil)
    let decodeStatuses = Mutex<[OSStatus]>([])

    init(ackDelayMs: Int = 0) {
        let (a, b) = MemoryStream.pair()
        host = MessageChannel(stream: a, label: "test.host.video", version: LainProtocol.newestVersion)
        channel = MessageChannel(stream: b, label: "test.client.video", version: LainProtocol.newestVersion)
        self.ackDelayMs = ackDelayMs
        channel.setHandler { [unowned self] env in handle(env) }
        channel.start()
    }

    private func handle(_ env: Envelope) {
        let now = MonotonicClock.now()
        received.withLock { $0.append(Received(envelope: env, atNs: now)) }
        switch env.message {
        case .videoConfig(let config):
            decoder.withLock { $0 = try? VideoDecoder(config: config) { [weak self] out in
                self?.decodeStatuses.withLock { $0.append(out.status) }
            } }
        case .videoFrame(let frame):
            let ack = Message.frameAck(FrameAck(frameId: frame.frameId, receivedAtNs: now, bytes: UInt32(frame.data.count)))
            if ackDelayMs == 0 { channel.send(ack) } else {
                channel.queue.asyncAfter(deadline: .now() + .milliseconds(ackDelayMs)) { [channel] in channel.send(ack) }
            }
            decoder.withLock { $0 }?.decode(frame)
        default: break
        }
    }

    var all: [Received] { received.withLock { $0 } }
    var configs: [VideoConfig] { all.compactMap { if case .videoConfig(let c) = $0.envelope.message { c } else { nil } } }
    var frames: [(frame: VideoFrame, flags: HeaderFlags, atNs: UInt64)] {
        all.compactMap { if case .videoFrame(let f) = $0.envelope.message { (f, $0.envelope.header.flags, $0.atNs) } else { nil } }
    }

    /// Waits until no message has arrived for `quietMs`.
    func settle(quietMs: Int = 60, timeout: Double = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = -1
        var stableSince = Date()
        while Date() < deadline {
            let n = received.withLock { $0.count }
            if n != lastCount { lastCount = n; stableSince = Date() }
            if Date().timeIntervalSince(stableSince) * 1000 >= Double(quietMs) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        decoder.withLock { $0 }?.finish()
    }
}

func hello(_ caps: DecodeCapabilities) -> Hello {
    Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
          decodeCapabilities: caps, keyboardType: .ansi)
}

/// Options with idle refinement effectively off, for tests that count frames exactly.
func noRefinement() -> HostVideoPipeline.Options {
    var o = HostVideoPipeline.Options()
    o.maxRefinements = 0
    return o
}

/// Awaits `body`, but fails the test instead of hanging if it hasn't finished within `seconds`: a
/// `stop()` whose interrupted start never signals waits for ever, and neither `.timeLimit` nor a task
/// group can end a wait that ignores cancellation. A stuck body is left behind; the run goes on.
@discardableResult
private func finishes(within seconds: Double = 5, sourceLocation: SourceLocation = #_sourceLocation,
                      _ body: @escaping @Sendable () async -> Void) async -> Bool {
    let done = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        let once = Once()
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled, once.claim() { c.resume(returning: false) }
        }
        Task {
            await body()
            if once.claim() { c.resume(returning: true) }
            timer.cancel()
        }
    }
    if !done { Issue.record("did not finish within \(seconds) s", sourceLocation: sourceLocation) }
    return done
}

/// True for the first caller only.
private final class Once: Sendable {
    private let taken = Atomic<Bool>(false)
    func claim() -> Bool { !taken.exchange(true, ordering: .acquiringAndReleasing) }
}

/// A value handed over from another task.
private final class Box<T: Sendable>: Sendable {
    private let value = Mutex<T?>(nil)
    func set(_ v: T) { value.withLock { $0 = v } }
    var get: T? { value.withLock { $0 } }
}

@Suite(.serialized) struct HostVideoPipelineTests {
    @Test func fourFourFourStreamWithConfigFirstKeyframeFirstAndAcks() async throws {
        let display = FakeStreamedDisplay(), source = FakeFrameSource(), client = VideoClient()
        let realtime = Mutex<[Message]>([])
        // Refinement off: a scheduler stall in the feed would rightly refine mid-stream (its own test).
        let pipeline = HostVideoPipeline(display: display, frameSource: source, cursorSource: FakeCursor(), options: noRefinement())
        try await pipeline.start(hello: hello([.hevcMain, .hevcMain44410Hardware]), videoChannel: client.host,
                                 sendRealtime: { m in realtime.withLock { $0.append(m) } })

        #expect(pipeline.chroma == .yuv444)
        #expect(source.config == FrameSourceConfig(displayID: 4242, pixelWidth: testWidth, pixelHeight: testHeight,
                                                   pixelFormat: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, frameRate: 120))
        #expect(pipeline.streamedDisplayID == 4242)
        #expect(pipeline.streamedDisplayBounds == display.display.bounds)

        let lastFeed = try await source.feed(frames444, count: 60)
        let midStats = pipeline.stats
        await client.settle()

        // VideoConfig strictly before the first VideoFrame; the first frame is a keyframe, flagged.
        let kinds = client.all.map(\.envelope.header.type)
        let firstConfig = try #require(kinds.firstIndex(of: .videoConfig))
        let firstFrame = try #require(kinds.firstIndex(of: .videoFrame))
        #expect(firstConfig < firstFrame)
        let config = try #require(client.configs.first)
        #expect(config.chroma == .yuv444 && config.bitDepth == 10 && config.width == UInt32(testWidth))
        #expect(config.matrix == ColorTags.bt709Matrix && config.colorPrimaries == ColorTags.p3D65Primaries)

        let frames = client.frames
        #expect(frames.count >= 20)
        #expect(frames.first?.frame.isKeyframe == true)
        #expect(frames.first?.flags.contains(.keyframe) == true)
        let flowing = frames.filter { $0.atNs <= lastFeed }
        #expect(flowing.dropFirst().allSatisfy { !$0.frame.isKeyframe && $0.flags.isEmpty })   // no refinement while flowing
        #expect(frames.allSatisfy { $0.frame.configId == config.configId })
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.frame.frameId < $1.frame.frameId })
        #expect(frames.allSatisfy { $0.flags.contains(.keyframe) == $0.frame.isKeyframe })

        // The client decodes real 4:4:4.
        #expect(client.decoder.withLock { $0?.chromaFormatIDC } == 3)
        #expect(client.decodeStatuses.withLock { $0 }.allSatisfy { $0 == noErr })

        // Capture buffers were tagged BT.709 / P3 before encoding (SCK doesn't tag the matrix).
        let matrix = CVBufferCopyAttachment(frames444[0], kCVImageBufferYCbCrMatrixKey, nil)
        #expect((matrix as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String))

        // Stats.
        let s = pipeline.stats
        #expect(s.captured == 60)
        #expect(s.peakInFlight <= 2)
        #expect(s.sent == frames.count)
        #expect(s.offered == s.captured + s.refinements)
        #expect(s.encodeMsP50 != nil && s.ackRttMsP50 != nil)
        #expect(s.bytesSent > 0 && midStats.bytesPerSecond > 0)
        #expect(s.keyframes == 1)

        // Cursor: one shape, then its select, on the realtime closure.
        let cursor = realtime.withLock { $0 }
        #expect(cursor.count == 2)
        if case .cursorShape(let shape)? = cursor.first, case .cursorSelect(let sel)? = cursor.last {
            #expect(sel.shapeId == shape.shapeId && sel.visible)
        } else {
            Issue.record("expected CursorShape then CursorSelect, got \(cursor)")
        }

        pipeline.stop()
        await finishes { await pipeline.waitUntilStopped() }
        print(String(format: "host video, fast client: %d captured, %d encoded, %d dropped before encode, peak in flight %d; "
                     + "encode p50 %.2f ms, ack RTT p50 %.2f ms, %.1f Mbps", s.captured, s.encoded, s.droppedBeforeEncode,
                     s.peakInFlight, s.encodeMsP50 ?? 0, s.ackRttMsP50 ?? 0, midStats.bytesPerSecond * 8 / 1e6))
    }

    @Test func slowClientDropsBeforeEncodeNeverAfter() async throws {
        let display = FakeStreamedDisplay(), source = FakeFrameSource(), client = VideoClient(ackDelayMs: 40)
        let pipeline = HostVideoPipeline(display: display, frameSource: source, cursorSource: nil, options: noRefinement())
        try await pipeline.start(hello: hello([.hevcMain, .hevcMain44410Hardware]), videoChannel: client.host, sendRealtime: { _ in })
        try await source.feed(frames444, count: 120)
        await client.settle(quietMs: 150)
        let s = pipeline.stats
        #expect(s.peakInFlight <= 2)
        #expect(s.droppedBeforeEncode > 40)
        #expect(s.offered == 120)
        #expect(s.encoded + s.droppedBeforeEncode == s.offered)       // every frame encoded or dropped in the slot
        #expect(s.sent == s.encoded - s.encodeFailures)
        #expect(client.frames.count == s.sent)                        // nothing dropped after encoding
        #expect(s.inFlight == 0)
        #expect(s.ackRttMsP50 ?? 0 >= 40)
        pipeline.stop()
        await finishes { await pipeline.waitUntilStopped() }
        print("host video, slow client (ack +40 ms): \(s.encoded)/\(s.offered) encoded, \(s.droppedBeforeEncode) dropped before encode, peak in flight \(s.peakInFlight)")
    }

    @Test func idleRefinementSendsAtMostTwoAfter150ms() async throws {
        let display = FakeStreamedDisplay(), source = FakeFrameSource(), client = VideoClient()
        let pipeline = HostVideoPipeline(display: display, frameSource: source, cursorSource: nil)
        try await pipeline.start(hello: hello([.hevcMain, .hevcMain44410Hardware]), videoChannel: client.host, sendRealtime: { _ in })
        let lastFeed = try await source.feed(frames444, count: 40)
        try await Task.sleep(for: .milliseconds(700))
        await client.settle()

        let frames = client.frames
        let refinements = frames.filter { $0.flags.contains(.refinement) }
        #expect(refinements.allSatisfy { !$0.frame.isKeyframe })
        // Each refinement comes 150 ms (the second 300 ms) after the capture it refines, at most two per
        // capture. Measured from that capture, not the feed loop, so a stall in the feed (which rightly
        // refines mid-stream) can't fail the test.
        var sinceCapture: [(capture: UInt64, count: Int)] = []
        for f in frames {
            if !f.flags.contains(.refinement) { sinceCapture.append((f.frame.captureTimeNs, 0)); continue }
            guard let last = sinceCapture.last else { Issue.record("refinement before any capture"); continue }
            sinceCapture[sinceCapture.count - 1].count += 1
            let n = UInt64(sinceCapture[sinceCapture.count - 1].count)
            #expect(f.frame.captureTimeNs >= last.capture + n * 150_000_000 - 10_000_000)
        }
        #expect(sinceCapture.allSatisfy { $0.count <= 2 })
        #expect(sinceCapture.last?.count == 2)                        // the idle tail got both
        #expect(frames.last.map { $0.atNs >= lastFeed } == true)
        #expect(pipeline.stats.refinements == refinements.count)
        pipeline.stop()
        await finishes { await pipeline.waitUntilStopped() }
    }

    @Test func keyframeRequestYieldsKeyframeEvenWhenIdle() async throws {
        let display = FakeStreamedDisplay(), source = FakeFrameSource(), client = VideoClient()
        let pipeline = HostVideoPipeline(display: display, frameSource: source, cursorSource: nil, options: noRefinement())
        try await pipeline.start(hello: hello([.hevcMain, .hevcMain44410Hardware]), videoChannel: client.host, sendRealtime: { _ in })
        try await source.feed(frames444, count: 20)
        await client.settle()
        let before = client.frames.count
        #expect(client.frames.filter(\.frame.isKeyframe).count == 1)

        // Display idle (capture delivers nothing): the request alone must produce a keyframe.
        pipeline.requestKeyframe(reason: .decodeError)
        await client.settle()
        let after = client.frames
        #expect(after.count == before + 1)
        #expect(after.last?.frame.isKeyframe == true && after.last?.flags.contains(.keyframe) == true)

        // While flowing, the next encoded frame is a keyframe (resumed also restarts the ack window).
        pipeline.requestKeyframe(reason: .resumed)
        try await source.feed(frames444, count: 10)
        await client.settle()
        #expect(client.frames.filter(\.frame.isKeyframe).count == 3)
        #expect(client.decodeStatuses.withLock { $0 }.allSatisfy { $0 == noErr })
        pipeline.stop()
        await finishes { await pipeline.waitUntilStopped() }
    }

    @Test func fourTwoZeroWhenClientLacksHardware444() async throws {
        let display = FakeStreamedDisplay(), source = FakeFrameSource(), client = VideoClient()
        let pipeline = HostVideoPipeline(display: display, frameSource: source, cursorSource: nil, options: noRefinement())
        try await pipeline.start(hello: hello([.hevcMain]), videoChannel: client.host, sendRealtime: { _ in })
        #expect(pipeline.chroma == .yuv420)
        #expect(source.config?.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        try await source.feed(frames420, count: 20)
        await client.settle()
        let config = try #require(client.configs.first)
        #expect(config.chroma == .yuv420 && config.bitDepth == 8)
        #expect(client.decoder.withLock { $0?.chromaFormatIDC } == 1)
        #expect(client.frames.count >= 5)
        #expect(client.decodeStatuses.withLock { $0 }.allSatisfy { $0 == noErr })
        pipeline.stop()
        await finishes { await pipeline.waitUntilStopped() }
    }

    @Test func stopIsIdempotentAndSilencesEverything() async throws {
        let display = FakeStreamedDisplay(), source = FakeFrameSource(), client = VideoClient()
        let realtime = Mutex(0)
        let pipeline = HostVideoPipeline(display: display, frameSource: source, cursorSource: FakeCursor())
        try await pipeline.start(hello: hello([.hevcMain, .hevcMain44410Hardware]), videoChannel: client.host,
                                 sendRealtime: { _ in realtime.withLock { $0 += 1 } })
        try await source.feed(frames444, count: 10)
        await client.settle()
        #expect(client.frames.count > 0)

        pipeline.stop()
        pipeline.stop()
        await finishes { await pipeline.waitUntilStopped() }
        #expect(!pipeline.isRunning)
        #expect(source.stops == 1)
        #expect(display.created == 1 && display.destroyed == 1 && !display.alive)
        // A stopped pipeline flags no display (its display is being removed).
        #expect(pipeline.streamedDisplayID == nil && pipeline.streamedDisplayBounds == nil)

        let messages = client.all.count, cursorMessages = realtime.withLock { $0 }
        // Late capture callbacks, keyframe requests, acks and the idle timer do nothing now.
        for i in 0..<5 { source.emit(frames444[i], ignoringStop: true) }
        pipeline.requestKeyframe(reason: .decodeError)
        try await Task.sleep(for: .milliseconds(400))
        #expect(client.all.count == messages)
        #expect(realtime.withLock { $0 } == cursorMessages)

        await #expect(throws: HostVideoError.alreadyStarted) {
            try await pipeline.start(hello: hello([.hevcMain]), videoChannel: client.host, sendRealtime: { _ in })
        }
        pipeline.stop()
        await finishes { await pipeline.waitUntilStopped() }
        #expect(display.destroyed == 1 && source.stops == 1)
    }

    @Test func stopDuringStartRemovesTheDisplay() async throws {
        let display = FakeStreamedDisplay(createDelayMs: 150), source = FakeFrameSource(), client = VideoClient()
        let pipeline = HostVideoPipeline(display: display, frameSource: source, cursorSource: nil)
        let start = Task {
            try await pipeline.start(hello: hello([.hevcMain]), videoChannel: client.host, sendRealtime: { _ in })
        }
        try await Task.sleep(for: .milliseconds(40))
        pipeline.stop()
        let outcome = Box<Result<Void, any Error>>()
        await finishes { outcome.set(await start.result) }
        #expect(throws: HostVideoError.stopped) { try outcome.get?.get() }
        await finishes { await pipeline.waitUntilStopped() }
        #expect(display.created == 1 && !display.alive)
        #expect(source.config == nil)
        #expect(client.all.isEmpty)
    }

    /// A stop may land anywhere in `start` (a USB takeover finishing a Wi-Fi session that is just starting
    /// its video, §7.7 D29): wherever it lands, the start ends (`stopped`, or running and then stopped),
    /// nothing traps (releasing a timer source that was never activated would) and no display is left.
    @Test func aStopAnywhereInStartLeavesNothingBehind() async throws {
        for i in 0..<48 {
            let display = FakeStreamedDisplay(), source = FakeFrameSource(), client = VideoClient()
            let pipeline = HostVideoPipeline(display: display, frameSource: source, cursorSource: FakeCursor(),
                                             options: noRefinement())
            let start = Task {
                try await pipeline.start(hello: hello([.hevcMain]), videoChannel: client.host, sendRealtime: { _ in })
            }
            // From another thread, at staggered moments: during create, the encoder's setup, the install,
            // or once it runs.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .microseconds(250 * (i % 24))) {
                    pipeline.stop()
                    c.resume()
                }
            }
            let outcome = Box<Result<Void, any Error>>()
            guard await finishes({ outcome.set(await start.result) }) else { return }
            var createdExpected = 1
            do {
                try outcome.get?.get()
            } catch HostVideoError.stopped {
                // stopped before it ran
            } catch HostVideoError.alreadyStarted {
                createdExpected = 0   // stopped before it even began
            }
            guard await finishes({ await pipeline.waitUntilStopped() }) else { return }
            #expect(!pipeline.isRunning && !display.alive && display.created == createdExpected, "stop \(i)")
        }
    }

    /// A display whose `create()` waits until the test lets it finish (the window server bringing a new
    /// display up), and which leaves the active list a while after `destroy()`.
    final class SuspendingDisplay: StreamedDisplayProvider {
        let display = StreamedDisplay(displayID: 4343, pixelWidth: testWidth, pixelHeight: testHeight,
                                      bounds: CGRect(x: 0, y: 0, width: 688, height: 516), refreshRate: 120)
        struct Counts: Equatable { var created = 0, destroyed = 0, removed = 0, alive = false }
        private struct State {
            var counts = Counts()
            var creating: CheckedContinuation<Void, Never>?
            var released = false
            var removing = false
        }
        private let state = Mutex(State())
        var counts: Counts { state.withLock { $0.counts } }
        var isCreating: Bool { state.withLock { $0.creating != nil } }

        func create() async throws -> StreamedDisplay {
            state.withLock { $0.counts.created += 1; $0.counts.alive = true }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let go = state.withLock { s -> Bool in
                    if !s.released { s.creating = c }
                    return s.released
                }
                if go { c.resume() }
            }
            return display
        }

        /// Lets a suspended `create()` return.
        func finishCreating() {
            let c = state.withLock { s -> CheckedContinuation<Void, Never>? in
                s.released = true
                defer { s.creating = nil }
                return s.creating
            }
            c?.resume()
        }

        func currentBounds() -> CGRect? { counts.alive ? display.bounds : nil }

        func destroy() {
            state.withLock { s in
                guard s.counts.alive else { return }
                s.counts.alive = false
                s.counts.destroyed += 1
                s.removing = true
            }
        }

        func waitUntilRemoved() async {
            guard state.withLock({ $0.removing }) else { return }
            // As the real wait: its course is run even on a cancelled task.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) { c.resume() }
            }
            state.withLock { s in
                if s.removing { s.counts.removed += 1 }
                s.removing = false
            }
        }
    }

    /// A stop while `create()` is still bringing the display up (§7.7 D29: USB taking over from a Wi-Fi
    /// session that is just starting): `waitUntilStopped` returns only once that display has been
    /// destroyed and has left the active list, so the next session never sees two lain displays.
    @Test func stopDuringStartWaitsForTheDisplayItCreated() async throws {
        let display = SuspendingDisplay(), source = FakeFrameSource(), client = VideoClient()
        let pipeline = HostVideoPipeline(display: display, frameSource: source, cursorSource: nil)
        let start = Task {
            try await pipeline.start(hello: hello([.hevcMain]), videoChannel: client.host, sendRealtime: { _ in })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !display.isCreating, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(display.isCreating)

        pipeline.stop()
        let stopped = Mutex<SuspendingDisplay.Counts?>(nil)
        let waiter = Task {
            await pipeline.waitUntilStopped()
            stopped.withLock { $0 = display.counts }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(stopped.withLock { $0 } == nil)   // the display the start is creating still exists

        display.finishCreating()
        let outcome = Box<Result<Void, any Error>>()
        await finishes { outcome.set(await start.result) }
        #expect(throws: HostVideoError.stopped) { try outcome.get?.get() }
        await finishes { await waiter.value }
        #expect(stopped.withLock { $0 } == SuspendingDisplay.Counts(created: 1, destroyed: 1, removed: 1, alive: false))
        #expect(source.config == nil && client.all.isEmpty)
    }

    /// A display whose `create()` waits, cancellably, for the window server to bring it up (as the real
    /// one polls for its mode), and which leaves the active list `removalMs` after `destroy()`. Its
    /// removal wait is the real one, `VirtualDisplay.waitUntilGone`, with this display standing in for
    /// the window server: it counts the polls, and notes whether the task waiting was cancelled.
    final class CancellableDisplay: StreamedDisplayProvider {
        let display = StreamedDisplay(displayID: 4444, pixelWidth: testWidth, pixelHeight: testHeight,
                                      bounds: CGRect(x: 0, y: 0, width: 688, height: 516), refreshRate: 120)
        struct Removal { var polls = 0, onCancelledTask = false }
        private struct State {
            var creating = false
            var alive = false
            var listedUntil: ContinuousClock.Instant?
            var removal = Removal()
        }
        let removalMs: Int
        private let state = Mutex(State())
        init(removalMs: Int) { self.removalMs = removalMs }
        var isCreating: Bool { state.withLock { $0.creating } }
        var removal: Removal { state.withLock { $0.removal } }
        var isListed: Bool { state.withLock { s in s.alive || s.listedUntil.map { ContinuousClock.now < $0 } ?? false } }

        func create() async throws -> StreamedDisplay {
            state.withLock { $0.creating = true; $0.alive = true }
            do {
                try await Task.sleep(for: .seconds(30))   // cancelled long before
            } catch {
                destroy()
                throw error
            }
            return display
        }

        func currentBounds() -> CGRect? { state.withLock { $0.alive } ? display.bounds : nil }

        func destroy() {
            state.withLock { s in
                guard s.alive else { return }
                s.alive = false
                s.listedUntil = .now + .milliseconds(removalMs)
            }
        }

        func waitUntilRemoved() async {
            await VirtualDisplay.waitUntilGone(display.displayID) { _ in
                let cancelled = Task.isCancelled
                return state.withLock { s in
                    s.removal.polls += 1
                    if cancelled { s.removal.onCancelledTask = true }
                    return s.listedUntil.map { ContinuousClock.now < $0 } ?? false
                }
            }
        }
    }

    /// The session's task is cancelled while `create()` waits (the cable pulled during video start): the
    /// start gives up and removes its display, and waits for it on that cancelled task at the usual 20 ms
    /// pace, neither spinning on the window server nor returning before the display is gone (the next
    /// session's display shares its identity).
    @Test func aCancelledStartWaitsOutItsDisplayAtItsPace() async throws {
        let display = CancellableDisplay(removalMs: 200), source = FakeFrameSource(), client = VideoClient()
        let pipeline = HostVideoPipeline(display: display, frameSource: source, cursorSource: nil)
        let start = Task {
            try await pipeline.start(hello: hello([.hevcMain]), videoChannel: client.host, sendRealtime: { _ in })
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !display.isCreating, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(display.isCreating)

        let cancelled = ContinuousClock.now
        start.cancel()
        let outcome = Box<Result<Void, any Error>>()
        await finishes { outcome.set(await start.result) }
        #expect(throws: CancellationError.self) { try outcome.get?.get() }
        #expect(ContinuousClock.now - cancelled >= .milliseconds(200))
        #expect(!display.isListed)
        let removal = display.removal
        #expect(removal.onCancelledTask)
        #expect(removal.polls >= 2 && removal.polls <= 40, "\(removal.polls) polls in 200 ms")
        #expect(!pipeline.isRunning && source.config == nil && client.all.isEmpty)
    }
}
#endif
