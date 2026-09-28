// CodecBench — spike S3/S3c. Hardware HEVC encode and decode timing at the 13" iPad Pro's
// native 2752×2064, on synthetic scrolling colored text. Results go in ARCHITECTURE.md §13.
//
//   swiftc -O CodecBench.swift -o /tmp/codecbench && /tmp/codecbench
//
// Encode timing is submit → output callback with one frame outstanding at a time (what the
// latest-wins pipeline does). "LL" = kVTVideoEncoderSpecification_EnableLowLatencyRateControl;
// "RT" = normal real-time session with MaxFrameDelayCount 0.

import AppKit
import CoreMedia
import Foundation
import VideoToolbox

let W = 2752, H = 2064
/// Average bitrate target; override with BITRATE_MBPS=… (default 60, the USB starting point).
let bitrate = (Int(ProcessInfo.processInfo.environment["BITRATE_MBPS"] ?? "") ?? 60) * 1_000_000
let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

// MARK: Synthetic content

/// A tall page of colored monospaced "code"; frames scroll a window over it.
func makeDocument() -> CGImage {
    let docH = H * 3
    let ctx = CGContext(data: nil, width: W, height: docH, bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: bitmapInfo)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: docH))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let colors: [NSColor] = [.black, .systemRed, .systemBlue, .systemPurple, .systemGreen, .systemOrange]
    let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)
    var y = 10, i = 0
    while y < docH - 40 {
        let line = "func encode\(i)(frame: CVPixelBuffer) -> Data { return compress(frame, qp: \(i % 51)) } // lain \(i)"
        NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: colors[i % colors.count]])
            .draw(at: NSPoint(x: 40, y: y))
        y += 34; i += 1
    }
    return ctx.makeImage()!
}

func makePixelBuffer(_ format: OSType) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, W, H, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    return pb!
}

let bgraFrames: [CVPixelBuffer] = {
    let doc = makeDocument()
    return (0..<60).map { n in
        let pb = makePixelBuffer(kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: colorSpace, bitmapInfo: bitmapInfo)!
        ctx.draw(doc, in: CGRect(x: 0, y: -n * 24, width: W, height: doc.height))   // 24 px/frame scroll
        CVPixelBufferUnlockBaseAddress(pb, [])
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        return pb
    }
}()

func convert(_ frames: [CVPixelBuffer], to format: OSType) -> [CVPixelBuffer] {
    guard format != kCVPixelFormatType_32BGRA else { return frames }
    var transfer: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    return frames.map { src in
        let dst = makePixelBuffer(format)
        VTPixelTransferSessionTransferImage(transfer!, from: src, to: dst)
        return dst
    }
}

// MARK: Encode

struct EncodeResult { var samples: [CMSampleBuffer] = []; var ms: [Double] = []; var keyframe = 0; var pBytes: [Int] = [] }

func percentile(_ values: [Double], _ p: Double) -> Double {
    let s = values.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
}

func chromaIdc(_ sample: CMSampleBuffer) -> Int {
    guard let fd = CMSampleBufferGetFormatDescription(sample),
          let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any],
          let atoms = ext["SampleDescriptionExtensionAtoms"] as? [String: Any],
          let hvcC = atoms["hvcC"] as? Data else { return -1 }
    return Int(hvcC[16] & 0x3)   // 1 = 4:2:0, 2 = 4:2:2, 3 = 4:4:4
}

@discardableResult
func encode(_ label: String, input: OSType, profile: CFString, fps: Int, lowLatency: Bool) -> EncodeResult? {
    let frames = convert(bgraFrames, to: input)
    let spec: [CFString: Any] = [
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: lowLatency,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    ]
    var session: VTCompressionSession?
    guard VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_HEVC,
                                     encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                     compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                     compressionSessionOut: &session) == noErr, let s = session else {
        print("\(label): create failed"); return nil
    }
    defer { VTCompressionSessionInvalidate(s) }
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_P3_D65)
    if !lowLatency {
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
    }
    VTCompressionSessionPrepareToEncodeFrames(s)

    var result = EncodeResult()
    let interval = 1.0 / Double(fps)
    for (n, pb) in (frames + frames).enumerated() {
        let t0 = CFAbsoluteTimeGetCurrent()
        let done = DispatchSemaphore(value: 0)
        let status = VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: CMTime(value: Int64(n), timescale: Int32(fps)),
                                                     duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { st, _, sb in
            defer { done.signal() }
            guard st == noErr, let sb else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
            let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
            let size = CMSampleBufferGetTotalSampleSize(sb)
            result.samples.append(sb); result.ms.append(ms)
            if isKey { if result.keyframe == 0 { result.keyframe = size } } else { result.pBytes.append(size) }
        }
        guard status == noErr else { print("\(label): encode error \(status)"); return nil }
        done.wait()
        let rest = interval - (CFAbsoluteTimeGetCurrent() - t0)
        if rest > 0 { Thread.sleep(forTimeInterval: rest) }
    }
    guard result.ms.count > 2 else { print("\(label): no output"); return nil }
    let ms = Array(result.ms.dropFirst(2))
    let avgP = result.pBytes.isEmpty ? 0 : result.pBytes.reduce(0, +) / result.pBytes.count
    print(String(format: "%@ @%3d fps  chroma_idc=%d  encode p50 %5.2f  p95 %5.2f  max %5.2f ms | keyframe %4d KB  avg P %3d KB (~%.0f Mbps)",
                 label.padding(toLength: 32, withPad: " ", startingAt: 0), fps, chromaIdc(result.samples[0]),
                 percentile(ms, 0.5), percentile(ms, 0.95), ms.max()!, result.keyframe / 1024, avgP / 1024,
                 Double(avgP * 8 * fps) / 1e6))
    return result
}

// MARK: Decode

func decode(_ label: String, _ samples: [CMSampleBuffer]) {
    let fd = CMSampleBufferGetFormatDescription(samples[0])!
    let spec = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: spec,
                                              imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session)
    guard status == noErr, let s = session else { print("\(label): HW decoder create FAILED \(status)"); return }
    defer { VTDecompressionSessionInvalidate(s) }
    var hw: CFTypeRef?
    VTSessionCopyProperty(s, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hw)
    var ms: [Double] = []
    var outFormat: OSType = 0
    for sb in samples {
        let t0 = CFAbsoluteTimeGetCurrent()
        let done = DispatchSemaphore(value: 0)
        VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { st, _, image, _, _ in
            if st == noErr, let image { outFormat = CVPixelBufferGetPixelFormatType(image) }
            ms.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            done.signal()
        }
        done.wait()
    }
    let fourcc = String(bytes: withUnsafeBytes(of: outFormat.bigEndian, Array.init), encoding: .ascii) ?? "?"
    let steady = Array(ms.dropFirst())
    print(String(format: "%@ hw=%@ out=%@  decode p50 %5.2f  p95 %5.2f  max %5.2f ms",
                 label.padding(toLength: 32, withPad: " ", startingAt: 0), "\(hw ?? ("nil" as CFString))", fourcc,
                 percentile(steady, 0.5), percentile(steady, 0.95), steady.max()!))
}

// MARK: Run

print("CodecBench \(ProcessInfo.processInfo.operatingSystemVersionString)  \(W)×\(H)  target \(bitrate / 1_000_000) Mbps\n")
print("— encode —")
let main420 = encode("LL Main    in=420f", input: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, profile: kVTProfileLevel_HEVC_Main_AutoLevel, fps: 120, lowLatency: true)
encode("LL Main44410 in=xf44", input: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, profile: "HEVC_Main44410_AutoLevel" as CFString, fps: 120, lowLatency: true)
encode("RT Main    in=420f", input: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, profile: kVTProfileLevel_HEVC_Main_AutoLevel, fps: 120, lowLatency: false)
encode("RT Main444 in=444f", input: kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, profile: "HEVC_Main444_AutoLevel" as CFString, fps: 120, lowLatency: false)
let main44410 = encode("RT Main44410 in=xf44", input: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, profile: "HEVC_Main44410_AutoLevel" as CFString, fps: 120, lowLatency: false)
encode("RT Main44410 in=xf44", input: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, profile: "HEVC_Main44410_AutoLevel" as CFString, fps: 60, lowLatency: false)
encode("RT Main444 in=BGRA (trap)", input: kCVPixelFormatType_32BGRA, profile: "HEVC_Main444_AutoLevel" as CFString, fps: 120, lowLatency: false)

print("\n— decode (hardware required) —")
if let main420 { decode("Main 4:2:0", main420.samples) }
if let main44410 { decode("Main 4:4:4 10", main44410.samples) }
