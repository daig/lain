// CodecBench — spike S3/S3c. Hardware HEVC encode and decode timing at the 13" iPad Pro's
// native 2752×2064, on synthetic scrolling colored text. Results go in ARCHITECTURE.md §13.
//
//   swiftc -O CodecBench.swift -o /tmp/codecbench && /tmp/codecbench
//   /tmp/codecbench ltr     # S3b: LTR in the real-time vs low-latency session
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

// MARK: LTR (S3b)

/// Luma PSNR (dB) between two xf44 buffers, on every 4th row. 10-bit samples live in the top bits.
func lumaPSNR(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!, pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!
    let ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    var sse = 0.0, n = 0.0
    for y in stride(from: 0, to: H, by: 4) {
        let la = (pa + y * ra).assumingMemoryBound(to: UInt16.self), lb = (pb + y * rb).assumingMemoryBound(to: UInt16.self)
        for x in 0..<W { let d = Double(Int(la[x] >> 6) - Int(lb[x] >> 6)); sse += d * d }
        n += Double(W)
    }
    return sse == 0 ? 99 : 10 * log10(1023.0 * 1023.0 / (sse / n))
}

struct LTRFrame { var sample: CMSampleBuffer; var index: Int; var bytes: Int; var key: Bool; var token: Int?; var ms: Double }

/// S3b: is EnableLTR accepted in this mode, do frames carry tokens, how big is a ForceLTRRefresh frame
/// compared with a keyframe, and does decoding survive a lost frame when the next one is an LTR refresh?
func ltr(_ label: String, lowLatency: Bool) {
    let frames = convert(bgraFrames, to: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
    let spec: [CFString: Any] = [
        kVTVideoEncoderSpecification_EnableLowLatencyRateControl: lowLatency,
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
    ]
    var session: VTCompressionSession?
    guard VTCompressionSessionCreate(allocator: nil, width: Int32(W), height: Int32(H), codecType: kCMVideoCodecType_HEVC,
                                     encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                                     compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                     compressionSessionOut: &session) == noErr, let s = session else {
        print("\(label): create failed"); return
    }
    defer { VTCompressionSessionInvalidate(s) }
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: "HEVC_Main44410_AutoLevel" as CFString)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 120 as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 100_000 as CFNumber)
    VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_P3_D65)
    if !lowLatency {
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
    }
    let ltrStatus = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_EnableLTR, value: kCFBooleanTrue)
    var readBack: CFTypeRef?
    VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_EnableLTR, allocator: nil, valueOut: &readBack)
    VTCompressionSessionPrepareToEncodeFrames(s)
    print("\(label): EnableLTR set status \(ltrStatus), reads back \(readBack.map { "\($0)" } ?? "nil")")

    // Plan: frames 0..<150. The receiver acks every token as soon as the frame arrives, except that
    // frame `lost` never arrives; frame `lost + 1` is encoded with ForceLTRRefresh. Frame `forcedKey`
    // is a mid-stream keyframe for size comparison.
    let lost = 60, forcedKey = 110, total = 150
    var out: [LTRFrame] = []
    var acked: [Int] = []
    for n in 0..<total {
        var props: [CFString: Any] = [:]
        if !acked.isEmpty { props[kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = acked as CFArray }
        if n == lost + 1 { props[kVTEncodeFrameOptionKey_ForceLTRRefresh] = kCFBooleanTrue }
        if n == forcedKey { props[kVTEncodeFrameOptionKey_ForceKeyFrame] = kCFBooleanTrue }
        let t0 = CFAbsoluteTimeGetCurrent()
        let done = DispatchSemaphore(value: 0)
        var produced: LTRFrame?
        let status = VTCompressionSessionEncodeFrame(s, imageBuffer: frames[n % frames.count],
                                                     presentationTimeStamp: CMTime(value: Int64(n), timescale: 120),
                                                     duration: .invalid, frameProperties: props.isEmpty ? nil : props as CFDictionary,
                                                     infoFlagsOut: nil) { st, _, sb in
            defer { done.signal() }
            guard st == noErr, let sb else { return }
            let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]])?.first
            let key = !((att?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
            let token = (att?[kVTSampleAttachmentKey_RequireLTRAcknowledgementToken] as? NSNumber)?.intValue
            produced = LTRFrame(sample: sb, index: n, bytes: CMSampleBufferGetTotalSampleSize(sb), key: key, token: token,
                                ms: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        guard status == noErr else { print("\(label): encode error \(status) at frame \(n)"); return }
        done.wait()
        guard let f = produced else { print("\(label): no output for frame \(n)"); return }
        out.append(f)
        if let token = f.token, n != lost { acked.append(token) }
        let rest = 1.0 / 120 - (CFAbsoluteTimeGetCurrent() - t0)
        if rest > 0 { Thread.sleep(forTimeInterval: rest) }
    }

    let tokens = out.filter { $0.token != nil }
    let pSizes = out.filter { !$0.key && $0.index != lost + 1 && $0.index > 2 }.map(\.bytes)
    let avgP = pSizes.reduce(0, +) / max(1, pSizes.count)
    let ms = out.dropFirst(2).map(\.ms)
    print(String(format: "  encode p50 %.2f p95 %.2f ms | frames with LTR token: %d (first at %@) | keyframes at %@",
                 percentile(ms, 0.5), percentile(ms, 0.95), tokens.count,
                 tokens.first.map { "\($0.index)" } ?? "-", out.filter(\.key).map { "\($0.index)" }.joined(separator: ",")))
    let refresh = out[lost + 1]
    print(String(format: "  sizes: IDR %d KB | forced mid-stream keyframe %d KB (key=%@) | LTR refresh %d KB (key=%@) | avg P %d KB",
                 out[0].bytes / 1024, out[forcedKey].bytes / 1024, "\(out[forcedKey].key)",
                 refresh.bytes / 1024, "\(refresh.key)", avgP / 1024))

    // Decode twice: the loss followed by the refresh as encoded, and the same loss with the refresh
    // frame treated as an ordinary P-frame reference (i.e. what happens without recovery is visible
    // as low PSNR on frames after the gap).
    func decodePSNR(skipping skip: Set<Int>) -> [Int: Double] {
        let fd = CMSampleBufferGetFormatDescription(out[0].sample)!
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_444YpCbCr10BiPlanarFullRange] as CFDictionary
        var ds: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                           imageBufferAttributes: attrs, outputCallback: nil, decompressionSessionOut: &ds) == noErr,
              let d = ds else { print("  decoder create failed"); return [:] }
        defer { VTDecompressionSessionInvalidate(d) }
        var psnr: [Int: Double] = [:]
        for f in out where !skip.contains(f.index) {
            let done = DispatchSemaphore(value: 0)
            VTDecompressionSessionDecodeFrame(d, sampleBuffer: f.sample, flags: [], infoFlagsOut: nil) { st, _, image, _, _ in
                if st == noErr, let image { psnr[f.index] = lumaPSNR(image, frames[f.index % frames.count]) } else { psnr[f.index] = -Double(st) }
                done.signal()
            }
            done.wait()
        }
        return psnr
    }
    let clean = decodePSNR(skipping: [])
    let lossy = decodePSNR(skipping: [lost])
    func fmt(_ m: [Int: Double], _ idx: [Int]) -> String { idx.map { i in m[i].map { String(format: "%d:%.1f", i, $0) } ?? "\(i):-" }.joined(separator: " ") }
    let around = [lost - 1, lost, lost + 1, lost + 2, lost + 10, forcedKey - 1, forcedKey, total - 1]
    print("  PSNR dB, no loss:            " + fmt(clean, around))
    print("  PSNR dB, frame \(lost) lost:      " + fmt(lossy, around))
}

// MARK: Run

if CommandLine.arguments.dropFirst().first == "ltr" {
    print("CodecBench S3b (LTR)  \(ProcessInfo.processInfo.operatingSystemVersionString)  \(W)×\(H)  xf44 → Main44410  target \(bitrate / 1_000_000) Mbps\n")
    ltr("RT (real-time, MaxFrameDelayCount 0)", lowLatency: false)
    print("")
    ltr("LL (low-latency rate control)", lowLatency: true)
    exit(0)
}

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
