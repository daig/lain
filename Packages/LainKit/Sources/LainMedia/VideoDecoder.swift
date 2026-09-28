import CoreMedia
import CoreVideo
import LainProtocol
import LainTelemetry
import VideoToolbox

/// The client's decoder (§6.2): a real-time `VTDecompressionSession` built from `VideoConfig`'s
/// parameter sets, emitting Metal-compatible buffers in the stream's native format (`xf44`/`420f`).
/// Frames are decoded as soon as they arrive; nothing is queued.
public final class VideoDecoder: @unchecked Sendable {
    /// Unchecked: the decoded buffer is never written after VideoToolbox hands it over.
    public struct Output: @unchecked Sendable {
        public var frameId: UInt32
        /// nil when the frame failed to decode (the client then sends `KeyframeRequest`, D22).
        public var image: CVPixelBuffer?
        public var status: OSStatus
        public var decodeDoneNs: UInt64
    }

    public let config: VideoConfig
    public let format: CMVideoFormatDescription
    private let session: VTDecompressionSession
    private let onOutput: @Sendable (Output) -> Void

    public init(config: VideoConfig, requireHardware: Bool = false,
                onOutput: @escaping @Sendable (Output) -> Void) throws(MediaError) {
        self.config = config
        self.onOutput = onOutput
        format = try HEVC.formatDescription(config)
        let spec: [CFString: Any] = requireHardware ? [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] : [:]
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: config.chroma.pixelFormat,
                                      kCVPixelBufferMetalCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary,
                                                  imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &session)
        guard status == noErr, let session else { throw .osStatus("VTDecompressionSessionCreate", status) }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        self.session = session
    }

    deinit { VTDecompressionSessionInvalidate(session) }

    /// chroma_format_idc of the stream as the client reconstructed it (3 = 4:4:4 on the wire).
    public var chromaFormatIDC: Int? { HEVC.chromaFormatIDC(format) }

    public var isHardwareAccelerated: Bool {
        var value: CFTypeRef?
        VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              allocator: nil, valueOut: &value)
        return (value as? Bool) ?? false
    }

    public func decode(_ frame: VideoFrame) {
        let id = frame.frameId
        guard let sample = makeSample(frame.data) else {
            onOutput(Output(frameId: id, image: nil, status: -1, decodeDoneNs: MonotonicClock.now()))
            return
        }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
                                                       infoFlagsOut: nil) { [onOutput] status, _, image, _, _ in
            onOutput(Output(frameId: id, image: status == noErr ? image : nil, status: status, decodeDoneNs: MonotonicClock.now()))
        }
        if status != noErr { onOutput(Output(frameId: id, image: nil, status: status, decodeDoneNs: MonotonicClock.now())) }
    }

    /// Waits for frames already submitted (tests, teardown).
    public func finish() { VTDecompressionSessionWaitForAsynchronousFrames(session) }

    private func makeSample(_ data: [UInt8]) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        guard data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                                  dataLength: data.count) }) == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
}
