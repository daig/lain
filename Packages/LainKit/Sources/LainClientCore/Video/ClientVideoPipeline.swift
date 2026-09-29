import CoreVideo
import LainMedia
import LainProtocol
import LainTelemetry
import Synchronization

/// Anything that decodes `VideoFrame`s for the pipeline: `VideoDecoder` in the app, fakes in tests.
public protocol FrameDecoding: AnyObject, Sendable {
    func decode(_ frame: VideoFrame)
    /// Waits for submitted frames (teardown).
    func finish()
}

extension VideoDecoder: FrameDecoding {}

/// The colorimetry and layout the renderer needs to turn a decoded buffer into RGB (§6.2).
public struct FrameFormat: Sendable, Equatable {
    public var chroma: ChromaFormat
    public var bitDepth: UInt8
    public var fullRange: Bool
    /// ITU-T H.273 matrix code point (1 = BT.709, 6 = BT.601, 9 = BT.2020).
    public var matrix: UInt8

    public init(chroma: ChromaFormat, bitDepth: UInt8, fullRange: Bool, matrix: UInt8) {
        self.chroma = chroma
        self.bitDepth = bitDepth
        self.fullRange = fullRange
        self.matrix = matrix
    }

    public init(_ config: VideoConfig) {
        self.init(chroma: config.chroma, bitDepth: config.bitDepth, fullRange: config.fullRange, matrix: config.matrix)
    }
}

/// One decoded frame, ready for the renderer. Unchecked: the buffer is never written after decode.
public struct DecodedFrame: @unchecked Sendable {
    public var frameId: UInt32
    public var image: CVPixelBuffer
    public var format: FrameFormat
    public var captureTimeNs: UInt64
    public var receivedNs: UInt64
    public var decodeDoneNs: UInt64

    public init(frameId: UInt32, image: CVPixelBuffer, format: FrameFormat, captureTimeNs: UInt64 = 0,
                receivedNs: UInt64 = 0, decodeDoneNs: UInt64 = 0) {
        self.frameId = frameId
        self.image = image
        self.format = format
        self.captureTimeNs = captureTimeNs
        self.receivedNs = receivedNs
        self.decodeDoneNs = decodeDoneNs
    }
}

/// What the HUD shows (§6.6). Rates are since the previous `stats()` call.
public struct VideoStats: Sendable, Equatable {
    public var framesReceived = 0
    public var framesDecoded = 0
    /// Dropped before decode while waiting for a keyframe (D22), or with no decoder.
    public var framesDropped = 0
    /// Decoded but replaced in the latest-wins slot before the renderer took them.
    public var framesSkipped = 0
    public var framesPresented = 0
    public var decodeErrors = 0
    public var sequenceGaps = 0
    public var keyframeRequests = 0
    public var decodeP50Ms: Double?
    public var decodeP95Ms: Double?
    /// Frame fully received → its drawable's target presentation time.
    public var receiveToPresentP50Ms: Double?
    public var receiveToPresentP95Ms: Double?
    public var presentedFps: Double = 0
    public var receivedFps: Double = 0
    public var bitrateMbps: Double = 0
    public var width: UInt32 = 0
    public var height: UInt32 = 0
    public var chroma: ChromaFormat?
    public var awaitingKeyframe = true

    public init() {}

    /// Two short lines for the HUD overlay.
    public var hudText: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
        let mode = chroma.map { $0 == .yuv444 ? "4:4:4" : "4:2:0" } ?? "no video"
        return String(format: "%@ %u×%u · %.0f fps shown / %.0f in · %.1f Mbps\n", mode, width, height, presentedFps, receivedFps,
                      bitrateMbps)
            + "decode \(f(decodeP50Ms))/\(f(decodeP95Ms)) ms · recv→present \(f(receiveToPresentP50Ms))/\(f(receiveToPresentP95Ms)) ms"
            + " · dropped \(framesDropped) skipped \(framesSkipped) errors \(decodeErrors) kf-req \(keyframeRequests)"
    }
}

/// The client's video path (§6.1, §6.2, D22): `VideoConfig` (re)creates the decoder, each
/// `VideoFrame` is acked on receipt and decoded immediately (never queued), and decoded frames go
/// into a latest-wins slot the renderer takes from. Loss (a gap in the video channel's header
/// sequence, or a decode error) sends a rate-limited `KeyframeRequest` and drops frames until a
/// keyframe arrives.
///
/// Threads: `handleVideo` runs on the video connection's queue, decoder output on VideoToolbox's
/// thread, `presented`/`latest` on the render thread. They share one briefly held lock; the renderer
/// only touches the slot's.
///
/// Links: `connect` names the session's link generation (§7.7 D29), and envelopes tagged with another
/// one are dropped under the lock: a replaced link's late frames are neither decoded nor acked on the
/// new link, and don't disturb its sequence tracking (frame ids restart at 1 per host session).
public final class ClientVideoPipeline: Sendable {
    public typealias DecoderFactory = @Sendable (_ config: VideoConfig, _ requireHardware: Bool,
                                                 _ onOutput: @escaping @Sendable (VideoDecoder.Output) -> Void) throws -> any FrameDecoding

    public static let defaultDecoderFactory: DecoderFactory = { config, hardware, onOutput in
        try VideoDecoder(config: config, requireHardware: hardware, onOutput: onOutput)
    }

    /// Minimum spacing of `KeyframeRequest`s while waiting for a keyframe.
    public let keyframeRequestIntervalNs: UInt64
    /// Require a hardware decoder for 4:4:4 streams (the host only sends 4:4:4 when `Hello` said so).
    public let requireHardware444: Bool
    public let cursor = CursorOverlay()
    /// The newest decoded frame; the renderer `take()`s it.
    public let latest = LatestSlot<DecodedFrame>()

    private let makeDecoder: DecoderFactory
    private let clock: @Sendable () -> UInt64
    private let log = Telemetry.logger("video")

    private static let timingSlots = 32
    /// kVTInvalidSessionErr, kVTVideoDecoderMalfunctionErr.
    private static let invalidSessionStatus: Int32 = -12903
    private static let decoderMalfunctionStatus: Int32 = -12911

    private struct Timing {
        var frameId: UInt32 = 0
        var captureNs: UInt64 = 0
        var receivedNs: UInt64 = 0
    }

    private struct State {
        var sendControl: (@Sendable (Message) -> Void)?
        var sendVideo: (@Sendable (Message) -> Void)?
        var decoder: (any FrameDecoding)?
        var decoderGeneration: UInt64 = 0
        var config: VideoConfig?
        var format: FrameFormat?
        var lastSequence: UInt32?
        var awaitingKeyframe = true
        var lastRequestNs: UInt64?
        var lastGoodFrameId: UInt32 = 0
        /// The keyframe that ended the last recovery: errors from frames before it are stale.
        var lastKeyframeId: UInt32?
        /// The decoder looks dead (its session was invalidated, e.g. while backgrounded, or even a
        /// keyframe failed): rebuild it from `config` before the next keyframe.
        var rebuildDecoder = false
        var timings = [Timing](repeating: Timing(), count: ClientVideoPipeline.timingSlots)
        var stats = VideoStats()
        var decode = RollingPercentiles(capacity: 240)
        var present = RollingPercentiles(capacity: 240)
        var bytes = 0
        var lastPresentedId: UInt32?
        var rate = (ns: UInt64(0), presented: 0, received: 0, bytes: 0)
        /// The connected link's generation: tagged envelopes from any other are dropped (nil: none).
        var link: UInt64?

        /// Generations only grow, so a replaced decoder's late output is always recognized as stale.
        init(generation: UInt64 = 0, link: UInt64? = nil) {
            decoderGeneration = generation
            self.link = link
        }

        /// An untagged envelope, or one from the connected link.
        func accepts(_ generation: UInt64?) -> Bool { generation == nil || generation == link }
    }
    private let state: Mutex<State>
    private let session = Atomic<UInt64>(0)

    public init(requireHardware444: Bool = true, keyframeRequestIntervalMs: UInt64 = 250,
                clock: @escaping @Sendable () -> UInt64 = { MonotonicClock.now() },
                makeDecoder: @escaping DecoderFactory = ClientVideoPipeline.defaultDecoderFactory) {
        self.requireHardware444 = requireHardware444
        keyframeRequestIntervalNs = keyframeRequestIntervalMs * 1_000_000
        self.clock = clock
        self.makeDecoder = makeDecoder
        state = Mutex(State())
    }

    // MARK: Session

    /// A new link: `control` carries `KeyframeRequest`s (realtime), `video` carries `FrameAck`s. From now
    /// on envelopes (and cursor messages) tagged with another `generation` than this link's are dropped.
    public func connect(generation: UInt64? = nil, control: @escaping @Sendable (Message) -> Void,
                        video: @escaping @Sendable (Message) -> Void) {
        let old = state.withLock { s -> (any FrameDecoding)? in
            let old = s.decoder
            s = State(generation: s.decoderGeneration &+ 1, link: generation)
            s.sendControl = control
            s.sendVideo = video
            return old
        }
        old?.finish()
        latest.clear()
        session.add(1, ordering: .releasing)
        cursor.reset(generation: generation)
    }

    /// The link is gone: forget the stream (the screen goes back to the connect status). Tagged
    /// envelopes are dropped until the next `connect`.
    public func disconnect() {
        let old = state.withLock { s -> (any FrameDecoding)? in
            let old = s.decoder
            s = State(generation: s.decoderGeneration &+ 1, link: nil)
            return old
        }
        old?.finish()
        latest.clear()
        session.add(1, ordering: .releasing)
    }

    /// Scene became active again (§6.1): ask for a keyframe right away (not rate-limited).
    public func requestKeyframe(_ reason: KeyframeRequest.Reason) {
        let send = state.withLock { s in makeRequest(&s, reason, force: true) }
        send?()
    }

    // MARK: Video connection (its serial queue)

    /// Handles `VideoConfig` and `VideoFrame`; returns false for anything else (the caller routes it).
    /// Every envelope on the video connection should pass through here so sequence gaps are seen. With
    /// a `generation` other than the connected link's, the envelope is stale: dropped, and true.
    @discardableResult
    public func handleVideo(_ env: Envelope, generation: UInt64? = nil) -> Bool {
        let now = clock()
        switch env.message {
        case .videoConfig(let config):
            let (old, request) = state.withLock { s -> ((any FrameDecoding)?, (@Sendable () -> Void)?) in
                guard s.accepts(generation) else { return (nil, nil) }
                _ = checkSequence(&s, env.header.sequence)
                return applyConfig(&s, config)
            }
            old?.finish()
            request?()
            return true
        case .videoFrame(let frame):
            var toDecode: (any FrameDecoding)?
            var replaced: (any FrameDecoding)?
            let (ack, request) = state.withLock { s -> ((@Sendable (Message) -> Void)?, (@Sendable () -> Void)?) in
                guard s.accepts(generation) else { return (nil, nil) }   // a replaced link's: never acked here
                s.stats.framesReceived += 1
                s.bytes += frame.data.count
                var request: (@Sendable () -> Void)?
                if checkSequence(&s, env.header.sequence) {
                    s.stats.sequenceGaps += 1
                    s.awaitingKeyframe = true
                    request = makeRequest(&s, .sequenceGap, force: false)
                }
                if frame.isKeyframe, s.rebuildDecoder, let config = s.config {
                    replaced = replaceDecoder(&s, config)
                    s.rebuildDecoder = s.decoder == nil     // creation failed: try again at the next keyframe
                }
                if s.decoder == nil {
                    s.stats.framesDropped += 1
                    s.awaitingKeyframe = true
                    request = request ?? makeRequest(&s, .startup, force: false)
                } else if s.awaitingKeyframe && !frame.isKeyframe {
                    s.stats.framesDropped += 1
                    request = request ?? makeRequest(&s, s.stats.decodeErrors > 0 ? .decodeError : .sequenceGap, force: false)
                } else {
                    if frame.isKeyframe {
                        s.awaitingKeyframe = false
                        s.lastKeyframeId = frame.frameId
                    }
                    s.timings[Int(frame.frameId) % Self.timingSlots] = Timing(frameId: frame.frameId, captureNs: frame.captureTimeNs,
                                                                             receivedNs: now)
                    toDecode = s.decoder
                }
                return (s.sendVideo, request)
            }
            // Backpressure (§7.3): ack on receipt, whether or not the frame is decoded.
            ack?(.frameAck(FrameAck(frameId: frame.frameId, receivedAtNs: now, bytes: UInt32(frame.data.count))))
            request?()
            replaced?.finish()
            toDecode?.decode(frame)
            return true
        default:
            return state.withLock { s in
                guard s.accepts(generation) else { return true }
                _ = checkSequence(&s, env.header.sequence)
                return false
            }
        }
    }

    // MARK: Render thread

    /// The renderer drew `frame` into a drawable that presents at `presentNs` (CLOCK_UPTIME_RAW ns).
    public func presented(_ frameId: UInt32, receivedNs: UInt64, at presentNs: UInt64) {
        state.withLock { s in
            guard s.lastPresentedId != frameId else { return }
            s.lastPresentedId = frameId
            s.stats.framesPresented += 1
            if presentNs > receivedNs, receivedNs != 0 { s.present.record(Double(presentNs - receivedNs) / 1e6) }
        }
    }

    /// Changes on every connect and disconnect: the renderer drops the frame it holds.
    public var sessionGeneration: UInt64 { session.load(ordering: .acquiring) }

    /// Whether a frame has been decoded since the link came up (the UI hides the connect status).
    public var hasVideo: Bool { state.withLock { $0.stats.framesDecoded > 0 } }

    /// HUD numbers; rates cover the time since the previous call. Control plane only (sorts).
    public func stats() -> VideoStats {
        let now = clock()
        return state.withLock { s in
            var out = s.stats
            out.framesSkipped = latest.replaced
            out.decodeP50Ms = s.decode.p50
            out.decodeP95Ms = s.decode.p95
            out.receiveToPresentP50Ms = s.present.p50
            out.receiveToPresentP95Ms = s.present.p95
            out.awaitingKeyframe = s.awaitingKeyframe
            if let c = s.config {
                out.width = c.width
                out.height = c.height
                out.chroma = c.chroma
            }
            if s.rate.ns != 0, now > s.rate.ns {
                let dt = Double(now - s.rate.ns) / 1e9
                out.presentedFps = Double(s.stats.framesPresented - s.rate.presented) / dt
                out.receivedFps = Double(s.stats.framesReceived - s.rate.received) / dt
                out.bitrateMbps = Double(s.bytes - s.rate.bytes) * 8 / dt / 1e6
            }
            s.rate = (now, s.stats.framesPresented, s.stats.framesReceived, s.bytes)
            return out
        }
    }

    // MARK: Private (under the lock)

    /// Records the header sequence; true when one or more messages were skipped.
    private func checkSequence(_ s: inout State, _ sequence: UInt32) -> Bool {
        defer { s.lastSequence = sequence }
        guard let last = s.lastSequence else { return false }
        return sequence != last &+ 1
    }

    private func applyConfig(_ s: inout State, _ config: VideoConfig) -> ((any FrameDecoding)?, (@Sendable () -> Void)?) {
        if let current = s.config, s.decoder != nil, current.parameterSets == config.parameterSets,
           current.chroma == config.chroma, current.width == config.width, current.height == config.height {
            s.config = config
            s.format = FrameFormat(config)
            return (nil, nil)
        }
        s.config = config
        s.format = FrameFormat(config)
        s.awaitingKeyframe = true
        s.rebuildDecoder = false
        return (replaceDecoder(&s, config), nil)
    }

    /// A new decoder for `config` under a new generation; returns the old one to finish outside the lock.
    private func replaceDecoder(_ s: inout State, _ config: VideoConfig) -> (any FrameDecoding)? {
        let old = s.decoder
        s.decoderGeneration &+= 1
        let generation = s.decoderGeneration
        let format = FrameFormat(config)
        do {
            s.decoder = try makeDecoder(config, requireHardware444 && config.chroma == .yuv444) { [weak self] out in
                self?.decoded(out, generation: generation, format: format)
            }
            log.notice("decoder for config \(config.configId): \(config.width)×\(config.height) \(config.chroma == .yuv444 ? "4:4:4" : "4:2:0") \(config.bitDepth)-bit")
        } catch {
            s.decoder = nil
            log.error("decoder creation failed: \(String(describing: error), privacy: .public)")
        }
        return old
    }

    /// A `KeyframeRequest` to send outside the lock, or nil when rate-limited or not connected.
    private func makeRequest(_ s: inout State, _ reason: KeyframeRequest.Reason, force: Bool) -> (@Sendable () -> Void)? {
        guard let send = s.sendControl else { return nil }
        let now = clock()
        if !force, let last = s.lastRequestNs, now &- last < keyframeRequestIntervalNs { return nil }
        s.lastRequestNs = now
        s.stats.keyframeRequests += 1
        let message = Message.keyframeRequest(KeyframeRequest(reason: reason, lastGoodFrameId: s.lastGoodFrameId))
        return { send(message) }
    }

    /// VideoToolbox's thread.
    private func decoded(_ out: VideoDecoder.Output, generation: UInt64, format: FrameFormat) {
        let (frame, request) = state.withLock { s -> (DecodedFrame?, (@Sendable () -> Void)?) in
            guard generation == s.decoderGeneration else { return (nil, nil) }
            guard let image = out.image, out.status == 0 else {
                // A frame submitted before the recovery keyframe failing is expected; ignore it.
                if let k = s.lastKeyframeId, Int32(bitPattern: out.frameId &- k) < 0 { return (nil, nil) }
                // A dead session (invalidated while backgrounded, or a malfunction) or a failing
                // keyframe won't recover with another keyframe: rebuild the decoder when one arrives.
                if out.status == Self.invalidSessionStatus || out.status == Self.decoderMalfunctionStatus
                    || out.frameId == s.lastKeyframeId {
                    s.rebuildDecoder = true
                }
                s.stats.decodeErrors += 1
                s.awaitingKeyframe = true
                s.lastKeyframeId = nil
                return (nil, makeRequest(&s, .decodeError, force: false))
            }
            s.stats.framesDecoded += 1
            s.lastGoodFrameId = out.frameId
            let t = s.timings[Int(out.frameId) % Self.timingSlots]
            let timing = t.frameId == out.frameId ? t : Timing()
            if timing.receivedNs != 0, out.decodeDoneNs > timing.receivedNs {
                s.decode.record(Double(out.decodeDoneNs - timing.receivedNs) / 1e6)
            }
            return (DecodedFrame(frameId: out.frameId, image: image, format: format, captureTimeNs: timing.captureNs,
                                 receivedNs: timing.receivedNs, decodeDoneNs: out.decodeDoneNs), nil)
        }
        if let frame { latest.put(frame) }
        request?()
    }
}

extension ClientVideoPipeline {
    /// `Hello.decodeCapabilities` for this device: HEVC Main always, plus Main 4:4:4 10 when the
    /// embedded 4:4:4 keyframe decodes with a hardware decoder required (S3c, `DecodeProbe`).
    /// Takes a few milliseconds; call once at startup.
    public static func probeDecodeCapabilities() -> DecodeCapabilities {
        let result = DecodeProbe.run()
        Telemetry.logger("video").notice(
            "4:4:4 hardware decode probe: \(result.hardware444 ? "yes" : "no", privacy: .public) (status \(result.status), chroma_format_idc \(result.chromaFormatIDC ?? -1))")
        return result.hardware444 ? [.hevcMain, .hevcMain44410Hardware] : [.hevcMain]
    }
}
