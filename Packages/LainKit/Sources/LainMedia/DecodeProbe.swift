import CoreVideo
import LainProtocol
import Synchronization
import VideoToolbox

/// S3c at runtime (§6.1): can this device decode HEVC Main 4:4:4 10 **in hardware**? The client
/// decodes a tiny embedded 4:4:4 keyframe with hardware required and reports the answer in
/// `Hello.decodeCapabilities`; the host falls back to 4:2:0 when it's missing (D10).
///
/// The vector was generated once on the M6 (macOS 27) with a throwaway VideoToolbox script: a 64×64
/// real-time `HEVC_Main44410_AutoLevel` hardware encode of an `xf44` luma ramp (flat chroma), forced
/// keyframe, P3/BT.709 tags; hvcC chroma_format_idc 3, 10-bit. 64×64 is not the hardware minimum
/// (16×16 also works) but keeps the sample comfortably above any decoder's minimum.
/// The Mac result is covered by `DecodeProbeTests`; the iPad's result is verified by the owner
/// (the host logs the client's capabilities).
public enum DecodeProbe {
    public static let width: UInt32 = 64
    public static let height: UInt32 = 64

    /// VPS, SPS, PPS (no start codes).
    public static let parameterSets: [[UInt8]] = [
        [
            0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0xBC, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x1E,
            0x17, 0x02, 0x40,
        ],
        [
            0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0xBC, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x1E, 0x90, 0x02, 0x04,
            0x08, 0x38, 0x10, 0x76, 0xC4, 0x0B, 0xC9, 0x22, 0xC8, 0xAB, 0x97, 0x2E, 0x5D, 0x4D, 0xC3, 0x00, 0x80, 0x40, 0x20,
        ],
        [
            0x44, 0x01, 0xC0, 0x72, 0x4C, 0x14, 0xC9,
        ],
    ]

    /// The keyframe as 4-byte length-prefixed NAL units (SEI + IDR slice).
    public static let keyframe: [UInt8] = [
        0x00, 0x00, 0x00, 0x3C, 0x4E, 0x01, 0x05, 0x32, 0x47, 0x56, 0x4A, 0xDC, 0x5C, 0x4C, 0x43, 0x3F, 0x94, 0xEF, 0xC5, 0x11,
        0x3C, 0xD1, 0x43, 0xA8, 0x01, 0x00, 0x00, 0x03, 0x00, 0x01, 0x03, 0x00, 0x00, 0x03, 0x00, 0x01, 0x02, 0x00, 0x00, 0x6B,
        0xFF, 0x0B, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x03, 0x0C, 0x0C, 0x03, 0x91, 0x2B, 0x01, 0x0D, 0xFF,
        0xFF, 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00, 0x2A, 0x28, 0x01, 0xAF, 0x15, 0x80, 0xF7, 0x01, 0xA3, 0x57, 0x57, 0x5F, 0xB7,
        0x2B, 0x0F, 0xF3, 0x06, 0x1D, 0x8B, 0xD3, 0x7A, 0x66, 0x78, 0xFA, 0xC9, 0x2F, 0x88, 0xED, 0x3F, 0x37, 0xFE, 0x41, 0x1D,
        0xCA, 0xF9, 0x7A, 0x9F, 0xFF, 0xD6, 0xEA, 0xDC, 0x92, 0xC0,
    ]

    public static var config: VideoConfig {
        VideoConfig(configId: 0, codec: .hevc, chroma: .yuv444, bitDepth: 10, width: width, height: height, fullRange: true,
                    colorPrimaries: ColorTags.p3D65Primaries, transferFunction: ColorTags.sRGBTransfer,
                    matrix: ColorTags.bt709Matrix, parameterSets: parameterSets)
    }

    public struct Result: Sendable, Equatable {
        /// The keyframe decoded with a hardware decoder required, into an `xf44` buffer of 64×64.
        public var hardware444: Bool
        /// chroma_format_idc the decoder saw (3 for 4:4:4), nil if the format couldn't be built.
        public var chromaFormatIDC: Int?
        public var status: OSStatus
    }

    /// Decodes the vector synchronously (a few ms). Safe from any thread except a VideoToolbox callback.
    public static func run() -> Result {
        let out = Mutex<VideoDecoder.Output?>(nil)
        let decoder: VideoDecoder
        do {
            decoder = try VideoDecoder(config: config, requireHardware: true) { o in out.withLock { $0 = o } }
        } catch {
            if case .osStatus(_, let s) = error { return Result(hardware444: false, chromaFormatIDC: nil, status: s) }
            return Result(hardware444: false, chromaFormatIDC: nil, status: -1)
        }
        decoder.decode(VideoFrame(frameId: 1, configId: 0, captureTimeNs: 0, encodeDoneNs: 0, isKeyframe: true, data: keyframe))
        decoder.finish()
        let o = out.withLock { $0 }
        var ok = false
        if let image = o?.image, o?.status == noErr {
            ok = CVPixelBufferGetWidth(image) == Int(width) && CVPixelBufferGetHeight(image) == Int(height)
                && CVPixelBufferGetPixelFormatType(image) == ChromaFormat.yuv444.pixelFormat
                && decoder.chromaFormatIDC == 3 && decoder.isHardwareAccelerated
        }
        return Result(hardware444: ok, chromaFormatIDC: decoder.chromaFormatIDC, status: o?.status ?? -1)
    }

    /// What the client puts in `Hello.decodeCapabilities`.
    public static func capabilities() -> DecodeCapabilities {
        run().hardware444 ? [.hevcMain, .hevcMain44410Hardware] : [.hevcMain]
    }
}
