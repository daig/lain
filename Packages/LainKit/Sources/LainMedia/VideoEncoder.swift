import CoreMedia
import CoreVideo
import LainProtocol
import LainTelemetry
import Synchronization
import VideoToolbox

/// The host's HEVC encoder, exactly per §5.3: a normal real-time session (not low-latency rate
/// control), one frame in and one out, Main 4:4:4 10 fed with `xf44`. At creation it checks that the
/// hardware really produces 4:4:4 (hvcC chroma_format_idc = 3) and otherwise falls back to Main/`420f`.
public final class VideoEncoder: @unchecked Sendable {
    public struct Settings: Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var frameRate: Int = 120
        public var averageBitRate: Int = 60_000_000
        /// Hard cap in bytes per one-second window; nil (the default) for none. Measured on the M6:
        /// a 150 Mbps cap doubled encode time (17 vs 9.6 ms) and squeezed keyframes to 475 KB
        /// (35 dB luma), so don't set it without re-measuring (§13).
        public var dataRateLimit: Int?
        public var chroma: ChromaFormat = .yuv444

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// One encoded frame, as it goes on the wire.
    public struct Output: Sendable {
        public var frameId: UInt32
        /// Set when the parameter sets changed (always on the first frame).
        public var config: VideoConfig?
        public var data: [UInt8]
        public var isKeyframe: Bool
        public var isRefinement: Bool
        public var captureTimeNs: UInt64
        public var submitNs: UInt64
        public var encodeDoneNs: UInt64
    }

    public let settings: Settings
    /// The chroma actually produced (after the start-up check).
    public let chroma: ChromaFormat
    private let session: VTCompressionSession
    private let onOutput: @Sendable (Output?) -> Void
    private let state = Mutex<(format: CMFormatDescription?, configId: UInt32, forceKeyframe: Bool)>((nil, 0, true))
    private let log = Telemetry.logger("encoder")

    /// - Parameter onOutput: called on VideoToolbox's thread for every submitted frame; nil when the
    ///   encoder dropped it or failed.
    public init(settings: Settings, onOutput: @escaping @Sendable (Output?) -> Void) throws(MediaError) {
        self.settings = settings
        self.onOutput = onOutput
        var chroma = settings.chroma
        var session = try Self.makeSession(settings, chroma: chroma)
        if chroma == .yuv444 {
            let idc = try Self.probeChroma(session, settings)
            if idc != 3 {
                Telemetry.logger("encoder").error("4:4:4 requested but hardware produced chroma_format_idc \(idc); falling back to 4:2:0")
                VTCompressionSessionInvalidate(session)
                chroma = .yuv420
                session = try Self.makeSession(settings, chroma: chroma)
            }
        }
        self.chroma = chroma
        self.session = session
        log.notice("encoder ready: \(settings.width)×\(settings.height) \(chroma == .yuv444 ? "4:4:4 10-bit" : "4:2:0")")
    }

    deinit { VTCompressionSessionInvalidate(session) }

    /// The pixel format capture must deliver (`xf44` or `420f`).
    public var inputPixelFormat: OSType { chroma.pixelFormat }

    /// Submits a frame. Never blocks; the result arrives through `onOutput`.
    public func encode(_ buffer: CVPixelBuffer, frameId: UInt32, captureTimeNs: UInt64, refinement: Bool = false,
                       forceKeyframe: Bool = false) {
        let force = state.withLock { s in
            defer { s.forceKeyframe = false }
            return s.forceKeyframe || forceKeyframe
        }
        let props: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let submit = MonotonicClock.now()
        // PTS in frame ticks at the expected rate. Raw microsecond timestamps (a 1 MHz timescale) more
        // than doubled encode time on the M6 (18 vs 8 ms, §13), so capture times stay out of the PTS.
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: Int64(frameId), timescale: Int32(settings.frameRate)),
            duration: .invalid, frameProperties: props, infoFlagsOut: nil
        ) { [self] status, _, sample in
            guard status == noErr, let sample, let data = HEVC.sampleBytes(sample),
                  let format = CMSampleBufferGetFormatDescription(sample) else {
                onOutput(nil)
                return
            }
            let config = state.withLock { s -> VideoConfig? in
                if let f = s.format, CFEqual(f, format) { return nil }
                s.format = format
                s.configId += 1
                return VideoConfig(configId: s.configId, codec: .hevc, chroma: chroma, bitDepth: chroma == .yuv444 ? 10 : 8,
                                   width: UInt32(settings.width), height: UInt32(settings.height), fullRange: true,
                                   colorPrimaries: ColorTags.p3D65Primaries, transferFunction: ColorTags.sRGBTransfer,
                                   matrix: ColorTags.bt709Matrix, parameterSets: HEVC.parameterSets(format))
            }
            onOutput(Output(frameId: frameId, config: config, data: data, isKeyframe: HEVC.isKeyframe(sample),
                            isRefinement: refinement, captureTimeNs: captureTimeNs, submitNs: submit,
                            encodeDoneNs: MonotonicClock.now()))
        }
        if status != noErr {
            log.error("encode failed: \(status)")
            onOutput(nil)
        }
    }

    /// The next frame will be a keyframe (client `KeyframeRequest`, §7.7 and D22).
    public func requestKeyframe() { state.withLock { $0.forceKeyframe = true } }

    private static func makeSession(_ s: Settings, chroma: ChromaFormat) throws(MediaError) -> VTCompressionSession {
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
                    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: false] as CFDictionary
        let attrs = [kCVPixelBufferPixelFormatTypeKey: chroma.pixelFormat, kCVPixelBufferWidthKey: s.width,
                     kCVPixelBufferHeightKey: s.height] as CFDictionary
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(s.width), height: Int32(s.height),
                                                codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec,
                                                imageBufferAttributes: attrs, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw .osStatus("VTCompressionSessionCreate", status) }
        let profile: CFString = chroma == .yuv444 ? "HEVC_Main44410_AutoLevel" as CFString : kVTProfileLevel_HEVC_Main_AutoLevel
        // Profile first; the rest as CodecBench sets them.
        var props: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_ProfileLevel, profile),
            (kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_AllowFrameReordering, false),
            (kVTCompressionPropertyKey_ExpectedFrameRate, s.frameRate),
            (kVTCompressionPropertyKey_AverageBitRate, s.averageBitRate),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, 1_000_000),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_P3_D65),
            // No TransferFunction: setting any value (sRGB or 709) costs ~4 ms per frame at 2752×2064 on
            // the M6 (§13). The client takes the transfer function from VideoConfig, not the VUI.
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true),
        ]
        if let limit = s.dataRateLimit { props.append((kVTCompressionPropertyKey_DataRateLimits, [limit, 1] as CFArray)) }
        for (key, value) in props {
            let st = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            guard st == noErr else {
                VTCompressionSessionInvalidate(session)
                throw .osStatus("set \(key)", st)
            }
        }
        // One frame in, one out. The real-time HEVC session rejects setting this (-12900) but reports
        // 0 already (probed on the M6, macOS 27), so verify by reading it back.
        if VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber) != noErr {
            var value: CFTypeRef?
            VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, allocator: nil, valueOut: &value)
            guard (value as? Int) == 0 else {
                VTCompressionSessionInvalidate(session)
                throw .badConfig("MaxFrameDelayCount is \(value.map { "\($0)" } ?? "unset"), need 0")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }

    /// Encodes one blank frame synchronously and reads the produced chroma format.
    private static func probeChroma(_ session: VTCompressionSession, _ s: Settings) throws(MediaError) -> Int {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, s.width, s.height, ChromaFormat.yuv444.pixelFormat,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw .noOutput }
        ColorTags.tag(buffer)
        let done = DispatchSemaphore(value: 0)
        let idc = Mutex<Int?>(nil)
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: .zero, duration: .invalid,
                                        frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
            if status == noErr, let sample, let f = CMSampleBufferGetFormatDescription(sample) {
                idc.withLock { $0 = HEVC.chromaFormatIDC(f) }
            }
            done.signal()
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        done.wait()
        guard let value = idc.withLock({ $0 }) else { throw .noOutput }
        return value
    }
}
