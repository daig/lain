import CoreGraphics
import CoreVideo
import Dispatch
import LainMedia
import LainProtocol
import LainTelemetry
import LainTransport
import Synchronization

/// A snapshot of the host video path for the status menu and HUD (§6.6).
public struct HostVideoStats: Sendable, Equatable {
    public var chroma: ChromaFormat?
    public var pixelWidth = 0
    public var pixelHeight = 0
    /// Complete frames delivered by capture.
    public var captured = 0
    /// Offered to the latest-wins slot: captured frames plus idle refinements and keyframe re-offers.
    public var offered = 0
    /// Submitted to the encoder.
    public var encoded = 0
    /// Replaced in the slot before they could be encoded (invariant 2: drops happen only here).
    public var droppedBeforeEncode = 0
    public var encodeFailures = 0
    /// Frames put on the video connection.
    public var sent = 0
    public var keyframes = 0
    public var refinements = 0
    public var inFlight = 0
    public var peakInFlight = 0
    public var bytesSent = 0
    /// Over the last second.
    public var bytesPerSecond = 0.0
    /// Submit → encoded, over the last 240 frames.
    public var encodeMsP50: Double?
    public var encodeMsP95: Double?
    /// Frame sent → `FrameAck` received, on the host clock.
    public var ackRttMsP50: Double?
    public var ackRttMsP95: Double?
    public init() {}
}

public enum HostVideoError: Error, Equatable, Sendable {
    /// `start` was called twice, or after `stop`.
    case alreadyStarted
    /// `stop()` ran while `start` was still setting up.
    case stopped
}

/// The host video path for one session (§5.1–§5.3, §7.3, invariant 2):
/// streamed display → capture (`FrameSource`) → BT.709/P3 tags → `FrameGate` (latest-wins slot, one
/// frame in the encoder, at most `maxInFlight` unacknowledged) → `VideoEncoder` → `VideoConfig` (when it
/// changes) and `VideoFrame` on the video connection. `FrameAck`s free the gate. Idle refinement
/// re-submits the last frame after 150 ms without a new one; a `KeyframeRequest` forces a keyframe (D22).
/// A `CursorMonitor` sends cursor shapes on the realtime channel.
///
/// Threading: capture callbacks, VideoToolbox callbacks and acks each take one short, uncontended lock
/// and never await; lifecycle (`start`/`stop`) is the only async part.
public final class HostVideoPipeline: Sendable {
    public struct Options: Sendable {
        /// N in §7.3.
        public var maxInFlight = 2
        public var frameRate = 120
        public var averageBitRate = 60_000_000
        public var idleRefinementMs: UInt64 = 150
        public var maxRefinements = 2
        /// How often the idle check runs.
        public var idleCheckMs = 10
        public var cursorHz = 60.0
        public init() {}
    }

    /// A captured (or re-offered) frame. Unchecked: capture never writes a buffer after delivering it,
    /// and the pipeline only reads it.
    struct Item: @unchecked Sendable {
        var buffer: CVPixelBuffer
        var captureNs: UInt64
        var refinement: Bool
        /// Which capture this buffer is (re-offers keep it): the gate turns away a re-offer once a
        /// newer capture exists, so a refinement or keyframe re-offer racing it can't show old content.
        var capture: UInt64
    }

    private enum Phase { case idle, starting, running, stopped }

    private struct State {
        var phase = Phase.idle
        var display: StreamedDisplay?
        var encoder: VideoEncoder?
        var gate: FrameGate<Item>?
        var channel: MessageChannel?
        var cursor: CursorMonitor?
        var timer: DispatchSourceTimer?
        var teardown: Task<Void, Never>?
        var chroma: ChromaFormat?
        var nextFrameId: UInt32 = 1
        var configId: UInt32 = 0
        var lastCaptured: Item?
        var refiner: IdleRefiner
        var acks = FrameAckWindow(maxInFlight: 64)
        var stats = HostVideoStats()
        var encodeMs = RollingPercentiles(capacity: 240)
        var rttMs = RollingPercentiles(capacity: 240)
        var rate = RateMeter()
    }

    public let displayProvider: any StreamedDisplayProvider
    public let frameSource: any FrameSource
    public let cursorSource: (any CursorImageSource)?
    public let options: Options
    private let state: Mutex<State>
    /// A `start` that is still creating its display, for a `stop()` that interrupts it to wait on.
    private let starting = StartInProgress()
    /// Serializes "record in flight + send" per encoded frame, so an ack can never overtake the gate's
    /// bookkeeping and `VideoConfig` always precedes the frames that use it.
    private let sendLock = Mutex(())
    /// The newest capture number (bumped before that frame is offered).
    private let newestCapture = Atomic<UInt64>(0)
    private let idleQueue = DispatchQueue(label: "lain.video.idle", qos: .userInitiated)
    private let log = Telemetry.logger("video")

    public init(display: any StreamedDisplayProvider, frameSource: any FrameSource, cursorSource: (any CursorImageSource)?,
                options: Options = Options()) {
        displayProvider = display
        self.frameSource = frameSource
        self.cursorSource = cursorSource
        self.options = options
        state = Mutex(State(refiner: IdleRefiner(idleMs: options.idleRefinementMs, maxRefinements: options.maxRefinements)))
    }

    // MARK: Public surface

    /// The streamed display while the pipeline runs (nil before, and once stopped or failed: its
    /// display is being removed and must not be flagged or targeted).
    public var streamedDisplay: StreamedDisplay? { state.withLock { $0.phase == .running ? $0.display : nil } }
    public var streamedDisplayID: UInt32? { streamedDisplay?.displayID }
    /// Live global point bounds of the streamed display (for `DisplayLayout`); the owner may move it in
    /// System Settings at any time, so this re-reads it.
    public var streamedDisplayBounds: CGRect? {
        guard let d = streamedDisplay else { return nil }
        return displayProvider.currentBounds() ?? d.bounds
    }
    /// The chroma actually streamed (after negotiation and the encoder's own probe).
    public var chroma: ChromaFormat? { state.withLock { $0.chroma } }
    public var isRunning: Bool { state.withLock { $0.phase == .running } }

    /// 4:4:4 only when the client hardware-decodes it (S3c); the encoder may still fall back to 4:2:0.
    public static func requestedChroma(for hello: Hello) -> ChromaFormat {
        hello.decodeCapabilities.contains(.hevcMain44410Hardware) ? .yuv444 : .yuv420
    }

    /// Creates the display, the encoder and the capture, and starts streaming on `videoChannel`
    /// (whose handler it takes over for `FrameAck`s). `sendRealtime` carries cursor messages.
    /// `onError` is called if capture stops on its own (display gone, permission revoked).
    public func start(hello: Hello, videoChannel: MessageChannel, sendRealtime: @escaping @Sendable (Message) -> Void,
                      onError: (@Sendable (any Error) -> Void)? = nil) async throws {
        let claimed = state.withLock { s -> Bool in
            guard s.phase == .idle else { return false }
            s.phase = .starting
            starting.begin()
            return true
        }
        guard claimed else { throw HostVideoError.alreadyStarted }

        let display: StreamedDisplay
        do {
            display = try await displayProvider.create()
        } catch {
            await abandonStart()
            throw error
        }
        guard state.withLock({ $0.phase == .starting }) else {
            await abandonStart()
            throw HostVideoError.stopped
        }

        var settings = VideoEncoder.Settings(width: display.pixelWidth, height: display.pixelHeight)
        settings.chroma = Self.requestedChroma(for: hello)
        settings.frameRate = hello.maxRefreshRate > 0 ? min(options.frameRate, Int(hello.maxRefreshRate)) : options.frameRate
        settings.averageBitRate = options.averageBitRate
        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(settings: settings) { [weak self] out in self?.encoded(out) }
        } catch {
            await abandonStart()
            throw error
        }
        let gate = FrameGate<Item>(maxInFlight: options.maxInFlight, isStale: { [weak self] item in
            self.map { item.capture < $0.newestCapture.load(ordering: .acquiring) } ?? false
        }) { [weak self] item in self?.submit(item) }
        let cursor = cursorSource.map { CursorMonitor(source: $0, send: sendRealtime) }
        let idleCheckMs = options.idleCheckMs

        // The idle timer exists only once installed: libdispatch traps on releasing a source that was
        // never activated, which a start abandoned here would do.
        let installed = state.withLock { s -> DispatchSourceTimer? in
            guard s.phase == .starting else { return nil }
            let timer = DispatchSource.makeTimerSource(queue: idleQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(idleCheckMs), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.idleTick() }
            s.phase = .running
            s.display = display
            s.encoder = encoder
            s.gate = gate
            s.channel = videoChannel
            s.cursor = cursor
            s.timer = timer
            s.chroma = encoder.chroma
            s.stats.chroma = encoder.chroma
            s.stats.pixelWidth = display.pixelWidth
            s.stats.pixelHeight = display.pixelHeight
            return timer
        }
        guard let timer = installed else {
            await abandonStart()
            throw HostVideoError.stopped
        }
        // Running: the display is the pipeline's now, and `stop()` removes it.
        starting.end()
        log.notice("video: display \(display.displayID) \(display.pixelWidth)×\(display.pixelHeight), \(encoder.chroma == .yuv444 ? "4:4:4 10-bit" : "4:2:0") (client \(hello.decodeCapabilities.contains(.hevcMain44410Hardware) ? "decodes" : "lacks") hardware 4:4:4)")
        videoChannel.setHandler { [weak self] env in self?.handleVideo(env) }
        videoChannel.start()
        timer.resume()   // a `stop()` since has cancelled it: activating a cancelled source is fine
        cursor?.start(hz: options.cursorHz)

        let config = FrameSourceConfig(displayID: display.displayID, pixelWidth: display.pixelWidth,
                                       pixelHeight: display.pixelHeight, pixelFormat: encoder.inputPixelFormat,
                                       frameRate: settings.frameRate)
        do {
            try await frameSource.start(config, onFrame: { [weak self] buffer, t in self?.captured(buffer, t) },
                                        onError: { [weak self] error in
                                            self?.log.error("capture failed: \(error)")
                                            onError?(error)
                                        })
        } catch {
            stop()
            throw error
        }
        // stop() may have raced the capture start; make sure capture ends.
        if !isRunning { await frameSource.stop() }
    }

    /// Stops capture, releases the encoder and gate, stops the cursor monitor and removes the display.
    /// Idempotent and synchronous: nothing is sent on the video connection after it returns (except by
    /// a VideoToolbox callback already past its check); the capture stop and display removal finish in
    /// the background (`waitUntilStopped`). A stop while `start` is still creating the display lets the
    /// start remove it, and the background part waits for that too.
    public func stop() {
        struct Taken {
            var timer: DispatchSourceTimer?
            var cursor: CursorMonitor?
            var encoder: VideoEncoder?
            var gate: FrameGate<Item>?
        }
        let source = frameSource, provider = displayProvider, starting = starting
        let taken = state.withLock { s -> Taken? in
            guard s.phase != .stopped else { return nil }
            // A start still creating the display removes it itself when it sees `.stopped`.
            let removeDisplay = s.display != nil && s.phase != .starting
            s.phase = .stopped
            defer {
                s.timer = nil; s.cursor = nil; s.encoder = nil; s.gate = nil; s.channel = nil; s.lastCaptured = nil
            }
            // Set with the phase, so a `waitUntilStopped` can never see a stopped pipeline without it.
            s.teardown = Task.detached {
                await source.stop()
                // An interrupted start removes the display it created itself (§7.7 D29): until it has, a
                // display from this pipeline may still exist.
                await starting.wait()
                if removeDisplay {
                    provider.destroy()
                    await provider.waitUntilRemoved()
                }
            }
            return Taken(timer: s.timer, cursor: s.cursor, encoder: s.encoder, gate: s.gate)
        }
        guard let taken else { return }
        taken.timer?.cancel()
        taken.cursor?.stop()
        // The encoder is invalidated when its last reference (an in-flight callback, at most) goes.
        withExtendedLifetime(taken.encoder) {}
        log.notice("video stopped")
    }

    /// Waits for the background part of `stop()` (capture stopped, display removed and gone from the
    /// active display list): afterwards no display from this pipeline exists, even if `stop()`
    /// interrupted `start`.
    public func waitUntilStopped() async {
        await state.withLock { $0.teardown }?.value
    }

    /// Client `KeyframeRequest` (realtime channel; D22: recovery is a keyframe). The last frame is
    /// re-offered so the keyframe goes out even when the display is idle and capture delivers nothing.
    /// On `.resumed`/`.startup` the client may have dropped frames without acking them, so the ack
    /// window restarts.
    public func requestKeyframe(reason: KeyframeRequest.Reason) {
        let now = MonotonicClock.now()
        let (encoder, gate, last) = state.withLock { s -> (VideoEncoder?, FrameGate<Item>?, Item?) in
            guard s.phase == .running else { return (nil, nil, nil) }
            if reason == .resumed || reason == .startup { s.acks.reset() }
            if s.lastCaptured != nil { s.refiner.newFrame(at: now) }
            return (s.encoder, s.gate, s.lastCaptured)
        }
        guard let encoder, let gate else { return }
        log.notice("keyframe requested (\(String(describing: reason)))")
        encoder.requestKeyframe()
        if reason == .resumed || reason == .startup { gate.reset() }
        if let last, !gate.slotOccupied {
            offer(Item(buffer: last.buffer, captureNs: now, refinement: false, capture: last.capture), gate: gate)
        }
    }

    /// Inbound on the video connection (installed by `start`; public so a session can route to it).
    public func handleVideo(_ env: Envelope) {
        switch env.message {
        case .frameAck(let ack): acked(ack)
        case .keyframeRequest(let r): requestKeyframe(reason: r.reason)
        default: break
        }
    }

    public var stats: HostVideoStats {
        let now = MonotonicClock.now()
        let (snapshot, gate) = state.withLock { s -> (HostVideoStats, FrameGate<Item>?) in
            var out = s.stats
            out.encodeMsP50 = s.encodeMs.p50
            out.encodeMsP95 = s.encodeMs.p95
            out.ackRttMsP50 = s.rttMs.p50
            out.ackRttMsP95 = s.rttMs.p95
            out.bytesPerSecond = s.rate.bytesPerSecond(now: now)
            return (out, s.gate)
        }
        var out = snapshot
        if let g = gate?.stats {
            out.offered = g.offered
            out.encoded = g.encoded
            out.droppedBeforeEncode = g.droppedBeforeEncode
            out.peakInFlight = g.peakInFlight
        }
        out.inFlight = gate?.inFlight ?? 0
        return out
    }

    // MARK: Capture queue

    private func captured(_ buffer: CVPixelBuffer, _ captureNs: UInt64) {
        // SCK frames carry no YCbCr matrix (S2): tag them to match the stream's explicit BT.709 matrix.
        ColorTags.tag(buffer)
        let now = MonotonicClock.now()
        let (gate, item) = state.withLock { s -> (FrameGate<Item>?, Item?) in
            guard s.phase == .running, let g = s.gate else { return (nil, nil) }
            let item = Item(buffer: buffer, captureNs: captureNs, refinement: false,
                            capture: newestCapture.add(1, ordering: .acquiringAndReleasing).newValue)
            s.stats.captured += 1
            s.lastCaptured = item
            s.refiner.newFrame(at: now)
            return (g, item)
        }
        if let gate, let item { offer(item, gate: gate) }
    }

    private func offer(_ item: Item, gate: FrameGate<Item>) {
        gate.offer(item)
    }

    // MARK: Encoder

    /// Called by the gate (outside its lock) when a frame may enter the encoder.
    private func submit(_ item: Item) {
        let next = state.withLock { s -> (VideoEncoder, UInt32)? in
            guard s.phase == .running, let e = s.encoder else { return nil }
            let id = s.nextFrameId
            s.nextFrameId &+= 1
            return (e, id)
        }
        guard let (encoder, frameId) = next else { return }
        // Frame ids are encode ids: monotonically increasing, so the PTS (frame ticks) is too (D25).
        encoder.encode(item.buffer, frameId: frameId, captureTimeNs: item.captureNs, refinement: item.refinement)
    }

    /// VideoToolbox's callback thread (or the submitting thread when submission itself failed).
    private func encoded(_ out: VideoEncoder.Output?) {
        guard let out else {
            let gate = state.withLock { s -> FrameGate<Item>? in
                guard s.phase == .running else { return nil }
                s.stats.encodeFailures += 1
                return s.gate
            }
            gate?.encodeFailed()
            return
        }
        sendLock.withLock { _ in
            let now = MonotonicClock.now()
            let target = state.withLock { s -> (MessageChannel, FrameGate<Item>, UInt32)? in
                guard s.phase == .running, let channel = s.channel, let gate = s.gate else { return nil }
                if let config = out.config { s.configId = config.configId }
                if out.encodeDoneNs >= out.submitNs { s.encodeMs.record(Double(out.encodeDoneNs - out.submitNs) / 1e6) }
                s.acks.sent(frameId: out.frameId, bytes: out.data.count, at: now)
                s.rate.record(bytes: out.data.count, at: now)
                s.stats.sent += 1
                s.stats.bytesSent += out.data.count
                if out.isKeyframe { s.stats.keyframes += 1 }
                if out.isRefinement { s.stats.refinements += 1 }
                return (channel, gate, s.configId)
            }
            guard let (channel, gate, configId) = target else { return }
            // In flight before it is on the wire, so its ack can't arrive first.
            gate.sent(frameId: out.frameId)
            if let config = out.config { channel.send(.videoConfig(config)) }
            var flags: HeaderFlags = out.isKeyframe ? .keyframe : []
            if out.isRefinement { flags.insert(.refinement) }
            channel.send(.videoFrame(VideoFrame(frameId: out.frameId, configId: configId, captureTimeNs: out.captureTimeNs,
                                                encodeDoneNs: out.encodeDoneNs, isKeyframe: out.isKeyframe, data: out.data)),
                         flags: flags)
        }
    }

    // MARK: Acks (video connection queue)

    private func acked(_ ack: FrameAck) {
        let now = MonotonicClock.now()
        let gate = state.withLock { s -> FrameGate<Item>? in
            guard s.phase == .running else { return nil }
            if let a = s.acks.acked(frameId: ack.frameId, at: now) { s.rttMs.record(Double(a.roundTripNs) / 1e6) }
            return s.gate
        }
        gate?.acked(frameId: ack.frameId)
    }

    // MARK: Idle refinement (idle queue)

    private func idleTick() {
        guard let gate = state.withLock({ $0.phase == .running ? $0.gate : nil }), !gate.slotOccupied else { return }
        let now = MonotonicClock.now()
        let item = state.withLock { s -> Item? in
            guard s.phase == .running, let last = s.lastCaptured, s.refiner.shouldRefine(at: now) else { return nil }
            return Item(buffer: last.buffer, captureNs: now, refinement: true, capture: last.capture)
        }
        if let item { offer(item, gate: gate) }
    }

    /// A start that won't run (failed, or stopped meanwhile): removes the display it may have created
    /// (`destroy` is idempotent), waits until that has left the active display list, goes back to idle
    /// unless stopped, and lets a waiting `stop()` finish.
    private func abandonStart() async {
        displayProvider.destroy()
        await displayProvider.waitUntilRemoved()
        state.withLock { s in if s.phase == .starting { s.phase = .idle } }
        starting.end()
    }
}

/// Whether a `start` is between claiming `.starting` and being done with its display: running (the
/// display is then the pipeline's, removed by `stop()`), or abandoned with the display removed.
private final class StartInProgress: Sendable {
    private let state = Mutex<(active: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func begin() { state.withLock { $0.active = true } }

    func end() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            defer { s = (false, []) }
            return s.waiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Returns at once when no start is under way.
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { s -> Bool in
                if s.active { s.waiters.append(c) }
                return !s.active
            }
            if idle { c.resume() }
        }
    }
}

/// Bytes per second over a sliding window, from a fixed ring (no allocation after init).
struct RateMeter: Sendable {
    private var times: [UInt64]
    private var bytes: [Int]
    private var next = 0
    private var count = 0

    init(capacity: Int = 512) {
        times = Array(repeating: 0, count: capacity)
        bytes = Array(repeating: 0, count: capacity)
    }

    mutating func record(bytes n: Int, at t: UInt64) {
        times[next] = t
        bytes[next] = n
        next = (next + 1) % times.count
        count = min(count + 1, times.count)
    }

    func bytesPerSecond(now: UInt64, windowNs: UInt64 = 1_000_000_000) -> Double {
        var sum = 0
        for i in 0..<count {
            let j = (next - 1 - i + times.count) % times.count
            guard now >= times[j], now - times[j] <= windowNs else { break }
            sum += bytes[j]
        }
        return Double(sum) * 1e9 / Double(windowNs)
    }
}

#if os(macOS)
extension HostVideoPipeline {
    /// The production wiring: the iPad-geometry virtual display (Extend mode, origin left to macOS),
    /// ScreenCaptureKit, and `NSCursor.currentSystem`. Needs Screen Recording; creating it touches nothing.
    public static func live(options: Options = Options()) -> HostVideoPipeline {
        HostVideoPipeline(display: VirtualStreamedDisplayProvider(refreshRate: options.frameRate),
                          frameSource: ScreenCaptureFrameSource(), cursorSource: SystemCursorSource(), options: options)
    }
}
#endif
