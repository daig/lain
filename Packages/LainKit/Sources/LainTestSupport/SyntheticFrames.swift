#if os(macOS)
import AppKit
import CoreVideo
import VideoToolbox

/// CodecBench's content (§13): a tall page of colored monospaced "code" in Display P3, scrolled a
/// few pixels per frame. Worst-ish case for chroma: thin colored strokes on white.
public enum SyntheticFrames {
    /// `count` BGRA frames of `width`×`height`, scrolling `scroll` px per frame.
    public static func scrollingText(width: Int, height: Int, count: Int, scroll: Int = 24) -> [CVPixelBuffer] {
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let docHeight = height + count * scroll + 64
        let ctx = CGContext(data: nil, width: width, height: docHeight, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: bitmapInfo)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: docHeight))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let colors: [NSColor] = [.black, .systemRed, .systemBlue, .systemPurple, .systemGreen, .systemOrange]
        let font = NSFont.monospacedSystemFont(ofSize: 26, weight: .regular)
        var y = 10, i = 0
        while y < docHeight - 40 {
            let line = "func encode\(i)(frame: CVPixelBuffer) -> Data { return compress(frame, qp: \(i % 51)) } // lain \(i)"
            NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: colors[i % colors.count]])
                .draw(at: NSPoint(x: 40, y: y))
            y += 34
            i += 1
        }
        NSGraphicsContext.current = previous
        let doc = ctx.makeImage()!
        return (0..<count).map { n in
            let pb = makeBuffer(width, height, kCVPixelFormatType_32BGRA)
            CVPixelBufferLockBaseAddress(pb, [])
            let fctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: colorSpace, bitmapInfo: bitmapInfo)!
            fctx.draw(doc, in: CGRect(x: 0, y: -n * scroll, width: width, height: docHeight))
            CVPixelBufferUnlockBaseAddress(pb, [])
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            return pb
        }
    }

    /// Converts frames to `format` (e.g. `xf44`) as ScreenCaptureKit would deliver them, BT.709 full range.
    public static func convert(_ frames: [CVPixelBuffer], to format: OSType) -> [CVPixelBuffer] {
        var transfer: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        defer { VTPixelTransferSessionInvalidate(transfer!) }
        return frames.map { src in
            let dst = makeBuffer(CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), format)
            CVBufferSetAttachment(dst, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(dst, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
            CVBufferSetAttachment(dst, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
            VTPixelTransferSessionTransferImage(transfer!, from: src, to: dst)
            return dst
        }
    }

    public static func makeBuffer(_ width: Int, _ height: Int, _ format: OSType) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, format,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &pb)
        return pb!
    }
}

/// PSNR between two biplanar 10-bit 4:4:4 (`xf44`) buffers, per plane, on every `step`-th row.
public enum ImageCompare {
    public struct PSNR: Sendable {
        public var luma: Double
        public var chroma: Double
    }

    public static func psnr444(_ a: CVPixelBuffer, _ b: CVPixelBuffer, rowStep: Int = 2) -> PSNR {
        precondition(CVPixelBufferGetPixelFormatType(a) == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        precondition(CVPixelBufferGetPixelFormatType(b) == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        func plane(_ p: Int, samplesPerRow: Int) -> Double {
            let pa = CVPixelBufferGetBaseAddressOfPlane(a, p)!, pb = CVPixelBufferGetBaseAddressOfPlane(b, p)!
            let ra = CVPixelBufferGetBytesPerRowOfPlane(a, p), rb = CVPixelBufferGetBytesPerRowOfPlane(b, p)
            let rows = CVPixelBufferGetHeightOfPlane(a, p)
            var sse = 0.0, n = 0.0
            for y in stride(from: 0, to: rows, by: rowStep) {
                let la = (pa + y * ra).assumingMemoryBound(to: UInt16.self)
                let lb = (pb + y * rb).assumingMemoryBound(to: UInt16.self)
                for x in 0..<samplesPerRow {
                    let d = Double(Int(la[x] >> 6) - Int(lb[x] >> 6))
                    sse += d * d
                }
                n += Double(samplesPerRow)
            }
            return sse == 0 ? 99 : 10 * log10(1023.0 * 1023.0 / (sse / n))
        }
        let w = CVPixelBufferGetWidth(a)
        return PSNR(luma: plane(0, samplesPerRow: w), chroma: plane(1, samplesPerRow: w * 2))
    }
}
#endif
