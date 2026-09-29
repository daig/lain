#if os(macOS)
import AppKit
import CoreMedia
import Foundation
import LainMedia
import LainTelemetry
@preconcurrency import ScreenCaptureKit
import Synchronization

/// `LainHost --bench vdisplay` (S2): creates the iPad-geometry virtual display, reports the modes and
/// color space macOS gives it, animates a window on it, and measures what ScreenCaptureKit delivers
/// (fps, gaps, pixel format), then encodes the captured frames. Removes the display at the end.
/// Needs Screen Recording for LainHost; launch with `open` so TCC attributes it to LainHost.
public enum VirtualDisplayBench {
    @MainActor
    public static func run() async -> Int32 {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            print("""
                LainHost can't record the screen yet. In System Settings › Privacy & Security › Screen & System Audio \
                Recording, turn on LainHost (the prompt may have opened it), then run this again. No display was added.
                """)
            return 3
        }
        let before = VirtualDisplay.activeDisplays()
        print("displays before: \(before.map { "\($0)" }.joined(separator: ", "))")

        let vd: VirtualDisplay
        do {
            vd = try VirtualDisplay()
            try await vd.waitUntilActive()
        } catch {
            print("virtual display failed: \(error)")
            return 1
        }
        print("virtual display \(vd.displayID) active")

        // Modes and color space.
        let modes = vd.modes()
        print("modes offered (\(modes.count)):")
        for m in modes {
            print(String(format: "  %4d×%-4d pt  %4d×%-4d px  %5.1f Hz%@", m.width, m.height, m.pixelWidth, m.pixelHeight,
                         m.refreshRate, m.isUsableForDesktopGUI() ? "" : "  (not usable for GUI)"))
        }
        let selected = vd.selectNativeMode(refreshRate: 120)
        try? await Task.sleep(for: .milliseconds(500))
        if let cur = CGDisplayCopyDisplayMode(vd.displayID) {
            print(String(format: "current mode: %d×%d pt, %d×%d px, %.1f Hz (native 120 Hz mode %@)", cur.width, cur.height,
                         cur.pixelWidth, cur.pixelHeight, cur.refreshRate, selected != nil ? "selected" : "NOT found"))
        }
        let cs = CGDisplayCopyColorSpace(vd.displayID)
        print("display color space: \(cs.name.map { $0 as String } ?? "unnamed") (model \(cs.model.rawValue)); \(primariesDescription(cs))")
        let bounds = CGDisplayBounds(vd.displayID)
        print("display bounds (global points): \(bounds)")

        // Animated content on the virtual display (ScreenCaptureKit only delivers changed frames).
        let window = makeAnimatedWindow(on: vd.displayID)

        // Capture.
        var result: Int32 = 0
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == vd.displayID }) else {
                print("ScreenCaptureKit doesn't list the virtual display")
                throw VirtualDisplay.Failure.didNotAppear
            }
            let capture = Capture()
            let config = SCStreamConfiguration()
            config.width = vd.spec.pixelWidth
            config.height = vd.spec.pixelHeight
            config.pixelFormat = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            config.showsCursor = false
            config.queueDepth = 4
            config.colorSpaceName = CGColorSpace.displayP3
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config,
                                  delegate: nil)
            try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
            try await stream.startCapture()

            try await Task.sleep(for: .milliseconds(500))        // settle
            capture.reset()
            try await Task.sleep(for: .seconds(5))
            let moving = capture.summary(seconds: 5)
            window.contentView?.layer?.sublayers?.forEach { $0.removeAllAnimations() }
            try await Task.sleep(for: .milliseconds(300))
            capture.reset()
            try await Task.sleep(for: .seconds(1))
            let idle = capture.summary(seconds: 1)
            try await stream.stopCapture()
            print(moving.describe("animating (5 s)"))
            print(idle.describe("idle (1 s)"))

            // Encode real captured frames with the production encoder.
            let frames = capture.keptFrames
            if !frames.isEmpty {
                print(try await encode(frames, width: vd.spec.pixelWidth, height: vd.spec.pixelHeight))
            }
        } catch {
            print("capture failed: \(error)")
            result = 1
        }

        window.orderOut(nil)
        withExtendedLifetime(vd) {}
        return result
    }

    /// Maps the display's primaries through its color space to XYZ and compares with Display P3.
    static func primariesDescription(_ cs: CGColorSpace) -> String {
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3), let xyz = CGColorSpace(name: CGColorSpace.genericXYZ) else { return "?" }
        func xy(_ space: CGColorSpace, _ rgb: [CGFloat]) -> (Double, Double)? {
            guard let c = CGColor(colorSpace: space, components: rgb + [1]),
                  let conv = c.converted(to: xyz, intent: .absoluteColorimetric, options: nil),
                  let v = conv.components, v.count >= 3 else { return nil }
            let sum = v[0] + v[1] + v[2]
            return sum > 0 ? (Double(v[0] / sum), Double(v[1] / sum)) : nil
        }
        let names = ["R", "G", "B"]
        let unit: [[CGFloat]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        var parts: [String] = []
        var maxErr = 0.0
        for (n, u) in zip(names, unit) {
            guard let a = xy(cs, u), let b = xy(p3, u) else { return "primaries unreadable" }
            maxErr = max(maxErr, abs(a.0 - b.0), abs(a.1 - b.1))
            parts.append(String(format: "%@ (%.3f, %.3f)", n, a.0, a.1))
        }
        return "primaries " + parts.joined(separator: " ") + String(format: " — max xy difference from Display P3 %.3f", maxErr)
    }

    // MARK: Content

    @MainActor
    static func makeAnimatedWindow(on displayID: CGDirectDisplayID) -> NSWindow {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1376, height: 1032)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .white
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let bar = CALayer()
        bar.backgroundColor = NSColor.systemRed.cgColor
        bar.frame = CGRect(x: 0, y: 0, width: 120, height: frame.height)
        view.layer?.addSublayer(bar)
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = 60
        anim.toValue = frame.width - 60
        anim.duration = 1.5
        anim.autoreverses = true
        anim.repeatCount = .infinity
        bar.add(anim, forKey: "sweep")
        window.contentView = view
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        return window
    }

    // MARK: Capture

    final class Capture: NSObject, SCStreamOutput, @unchecked Sendable {
        let queue = DispatchQueue(label: "lain.bench.capture", qos: .userInteractive)
        struct State {
            var times: [UInt64] = []
            var statuses: [Int: Int] = [:]
            var format: OSType = 0
            var size = CGSize.zero
            var primaries = "?"
            var kept: [Frame] = []
        }
        let state = Mutex(State())

        /// A captured copy; never written after creation.
        struct Frame: @unchecked Sendable { let buffer: CVPixelBuffer }

        func reset() { state.withLock { s in s.times.removeAll(); s.statuses.removeAll() } }

        func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen else { return }
            let now = MonotonicClock.now()
            let attachments = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
            let raw = attachments?[.status] as? Int ?? -1
            let pb = raw == SCFrameStatus.complete.rawValue ? CMSampleBufferGetImageBuffer(sb) : nil
            let format = pb.map(CVPixelBufferGetPixelFormatType) ?? 0
            let size = pb.map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) } ?? .zero
            // Both attachment buckets, plus the per-key lookup (which searches both and reports the mode).
            let primaries = pb.map { buffer -> String in
                let keys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey]
                let perKey = keys.map { key -> String in
                    var mode = CVAttachmentMode.shouldPropagate
                    let v = CVBufferCopyAttachment(buffer, key, &mode)
                    let short = (key as String).replacingOccurrences(of: "CVImageBuffer", with: "")
                    return "\(short)=\(v.map { "\($0) [\(mode == .shouldPropagate ? "propagate" : "don't propagate")]" } ?? "-")"
                }
                let prop = (CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any])?.keys.sorted() ?? []
                let noProp = (CVBufferCopyAttachments(buffer, .shouldNotPropagate) as? [String: Any])?.keys.sorted() ?? []
                var csText = "none"
                if let raw = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil) {
                    let cs = raw as! CGColorSpace
                    csText = "\(cs.name.map { $0 as String } ?? "unnamed") model \(cs.model.rawValue), "
                        + VirtualDisplayBench.primariesDescription(cs)
                }
                return perKey.joined(separator: " ") + " | propagate bucket: \(prop) | don't-propagate bucket: \(noProp)"
                    + " | attached CGColorSpace: \(csText)"
            }
            // Keep copies of up to 60 frames for the encode pass (SCK recycles its surfaces).
            let needCopy = pb != nil && state.withLock { $0.kept.count < 60 }
            let copy = needCopy ? pb.flatMap(Capture.copy).map(Frame.init) : nil
            state.withLock { s in
                s.statuses[raw, default: 0] += 1
                guard pb != nil else { return }
                s.times.append(now)
                s.format = format
                s.size = size
                if let primaries { s.primaries = primaries }
                if let copy { s.kept.append(copy) }
            }
        }

        var keptFrames: [CVPixelBuffer] { state.withLock { $0.kept }.map(\.buffer) }

        struct Summary {
            var frames: Int
            var seconds: Double
            var gaps: (p50: Double, p95: Double, max: Double)
            var statuses: [Int: Int]
            var format: OSType
            var size: CGSize
            var primaries: String

            func describe(_ label: String) -> String {
                let fourcc = String(bytes: withUnsafeBytes(of: format.bigEndian, Array.init), encoding: .ascii) ?? "?"
                let st = statuses.sorted { $0.key < $1.key }.map { "\(statusName($0.key))=\($0.value)" }.joined(separator: " ")
                return String(format: "capture %@: %d complete frames = %.1f fps; gaps p50 %.2f p95 %.2f max %.2f ms; %@ %.0f×%.0f; primaries %@; statuses %@",
                              label, frames, Double(frames) / seconds, gaps.p50, gaps.p95, gaps.max, fourcc, size.width,
                              size.height, primaries, st)
            }

            func statusName(_ raw: Int) -> String {
                switch SCFrameStatus(rawValue: raw) {
                case .complete: "complete"
                case .idle: "idle"
                case .blank: "blank"
                case .suspended: "suspended"
                case .started: "started"
                case .stopped: "stopped"
                default: "\(raw)"
                }
            }
        }

        func summary(seconds: Double) -> Summary {
            state.withLock { s in
                let gaps = zip(s.times.dropFirst(), s.times).map { Double($0 - $1) / 1e6 }.sorted()
                func pct(_ p: Double) -> Double { gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * p))] }
                return Summary(frames: s.times.count, seconds: seconds, gaps: (pct(0.5), pct(0.95), gaps.last ?? 0),
                               statuses: s.statuses, format: s.format, size: s.size, primaries: s.primaries)
            }
        }

        static func copy(_ src: CVPixelBuffer) -> CVPixelBuffer? {
            var dst: CVPixelBuffer?
            CVPixelBufferCreate(nil, CVPixelBufferGetWidth(src), CVPixelBufferGetHeight(src), CVPixelBufferGetPixelFormatType(src),
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &dst)
            guard let dst else { return nil }
            var transfer: VTPixelTransferSession?
            VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
            guard let transfer else { return nil }
            defer { VTPixelTransferSessionInvalidate(transfer) }
            CVBufferPropagateAttachments(src, dst)
            return VTPixelTransferSessionTransferImage(transfer, from: src, to: dst) == noErr ? dst : nil
        }
    }

    // MARK: Encode

    static func encode(_ frames: [CVPixelBuffer], width: Int, height: Int) async throws -> String {
        let done = AsyncStream<VideoEncoder.Output?>.makeStream()
        let encoder = try VideoEncoder(settings: VideoEncoder.Settings(width: width, height: height)) { done.continuation.yield($0) }
        var it = done.stream.makeAsyncIterator()
        var ms: [Double] = []
        var sizes: [Int] = []
        for (i, f) in frames.enumerated() {
            let t0 = MonotonicClock.now()
            encoder.encode(f, frameId: UInt32(i + 1), captureTimeNs: t0)
            guard let out = await it.next(), let out else { continue }
            ms.append(Double(out.encodeDoneNs - t0) / 1e6)
            sizes.append(out.data.count)
        }
        let steady = ms.dropFirst(2).sorted()
        func pct(_ p: Double) -> Double { steady.isEmpty ? 0 : steady[min(steady.count - 1, Int(Double(steady.count) * p))] }
        return String(format: "encode of %d captured frames (%@): p50 %.2f ms, p95 %.2f ms; keyframe %d KB, P-frames avg %d KB",
                      ms.count, encoder.chroma == .yuv444 ? "4:4:4 10-bit" : "4:2:0 fallback", pct(0.5), pct(0.95),
                      (sizes.first ?? 0) / 1024, sizes.dropFirst().reduce(0, +) / max(sizes.count - 1, 1) / 1024)
    }
}
#endif
