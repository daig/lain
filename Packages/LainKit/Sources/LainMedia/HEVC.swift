import CoreMedia
import CoreVideo
import LainProtocol
import VideoToolbox

/// HEVC format helpers shared by the encoder and decoder (§5.3, §6.2).
public enum HEVC {
    /// chroma_format_idc from a format description's hvcC (1 = 4:2:0, 3 = 4:4:4), or nil.
    public static func chromaFormatIDC(_ format: CMFormatDescription) -> Int? {
        guard let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any],
              let atoms = ext["SampleDescriptionExtensionAtoms"] as? [String: Any],
              let hvcC = atoms["hvcC"] as? Data, hvcC.count > 16 else { return nil }
        return Int(hvcC[hvcC.startIndex + 16] & 0x3)
    }

    /// VPS/SPS/PPS as raw NAL units (no start codes, no length prefix).
    public static func parameterSets(_ format: CMFormatDescription) -> [[UInt8]] {
        var count = 0
        guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                                 nalUnitHeaderLengthOut: nil) == noErr else { return [] }
        return (0..<count).compactMap { i in
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                     nalUnitHeaderLengthOut: nil) == noErr, let ptr else { return nil }
            return Array(UnsafeBufferPointer(start: ptr, count: size))
        }
    }

    /// Rebuilds a format description from `VideoConfig`'s parameter sets and color tags (client side).
    public static func formatDescription(_ config: VideoConfig) throws(MediaError) -> CMVideoFormatDescription {
        let sets = config.parameterSets
        guard !sets.isEmpty else { throw .badConfig("no parameter sets") }
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: sets.reduce(0) { $0 + $1.count })
        defer { storage.deallocate() }
        var pointers: [UnsafePointer<UInt8>] = []
        var offset = 0
        for ps in sets {
            (storage + offset).initialize(from: ps, count: ps.count)
            pointers.append(UnsafePointer(storage + offset))
            offset += ps.count
        }
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: sets.count, parameterSetPointers: pointers, parameterSetSizes: sets.map(\.count),
            nalUnitHeaderLength: 4, extensions: ColorTags.extensions(config) as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw .osStatus("CreateFromHEVCParameterSets", status) }
        return format
    }

    /// Sample bytes (4-byte length-prefixed NAL units) of an encoded sample buffer.
    public static func sampleBytes(_ sample: CMSampleBuffer) -> [UInt8]? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var out = [UInt8](repeating: 0, count: length)
        let status = out.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        return status == noErr ? out : nil
    }

    public static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        return !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }
}

/// Color tags carried in `VideoConfig` (ITU-T H.273 code points) and their CoreVideo equivalents.
/// The stream is Display P3 end to end, so colors are never converted (§5.3, D7).
public enum ColorTags {
    public static let p3D65Primaries: UInt8 = 12
    public static let sRGBTransfer: UInt8 = 13
    public static let bt709Matrix: UInt8 = 1

    public static func extensions(_ c: VideoConfig) -> [CFString: Any] {
        [kCMFormatDescriptionExtension_ColorPrimaries: c.colorPrimaries == p3D65Primaries
            ? kCVImageBufferColorPrimaries_P3_D65 : kCVImageBufferColorPrimaries_ITU_R_709_2,
         kCMFormatDescriptionExtension_TransferFunction: c.transferFunction == sRGBTransfer
            ? kCVImageBufferTransferFunction_sRGB : kCVImageBufferTransferFunction_ITU_R_709_2,
         kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
         kCMFormatDescriptionExtension_FullRangeVideo: c.fullRange]
    }

    /// Tags a capture buffer the way ScreenCaptureKit tags a P3 display.
    public static func tag(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}

public enum MediaError: Error, Equatable, Sendable {
    case osStatus(String, OSStatus)
    case badConfig(String)
    case noOutput
}

extension ChromaFormat {
    /// The capture/decode pixel format for this chroma mode: `xf44` (10-bit 4:4:4) or `420f`.
    public var pixelFormat: OSType {
        self == .yuv444 ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }
}
