import CoreVideo
import Foundation

/// What to capture (§5.2).
public struct FrameSourceConfig: Sendable, Equatable {
    public var displayID: UInt32
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// `xf44` or `420f`: must equal the encoder's `inputPixelFormat`.
    public var pixelFormat: OSType
    public var frameRate: Int

    public init(displayID: UInt32, pixelWidth: Int, pixelHeight: Int, pixelFormat: OSType, frameRate: Int) {
        self.displayID = displayID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pixelFormat = pixelFormat
        self.frameRate = frameRate
    }
}

/// Capture was stopped by the Mac's owner (the screen-recording indicator in the menu bar or Control
/// Center): the session goes on input-only rather than restarting capture against their wish.
public struct CaptureStoppedByUser: Error, Equatable {
    public init() {}
}

/// Delivers complete captured frames of the streamed display. Injected so tests feed synthetic frames.
public protocol FrameSource: Sendable {
    /// Starts capture. `onFrame` is called on the source's own serial queue for each **complete** frame
    /// with the buffer and its capture time (`CLOCK_UPTIME_RAW` ns); it must return promptly and never
    /// block. `onError` is called at most once if capture stops on its own.
    func start(_ config: FrameSourceConfig, onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
               onError: @escaping @Sendable (any Error) -> Void) async throws
    /// Stops capture; no `onFrame` call starts after this returns. Idempotent.
    func stop() async
}

#if os(macOS)
import CoreMedia
import LainTelemetry
@preconcurrency import ScreenCaptureKit
import Synchronization

/// The real source: an `SCStream` on the streamed display, configured per §5.2 and the S2 findings.
/// SCK `xf44` frames carry a Display P3 `CGColorSpace` but **no YCbCr matrix**, so the stream's
/// `colorMatrix` is set explicitly to BT.709 (the host tags each buffer to match before encoding).
/// SCK delivers nothing while the display is idle; idle refinement handles that (§5.3).
public final class ScreenCaptureFrameSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public enum Failure: Error { case displayNotShareable(UInt32) }

    private let queue = DispatchQueue(label: "lain.capture", qos: .userInteractive)
    private struct State {
        var stream: SCStream?
        var onFrame: (@Sendable (CVPixelBuffer, UInt64) -> Void)?
        var onError: (@Sendable (any Error) -> Void)?
        var stopped = false
    }
    private let state = Mutex(State())
    private let log = Telemetry.logger("capture")
    /// Converts SCK's mach-absolute display times to ns (CLOCK_UPTIME_RAW is the same clock).
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()
    /// Bridged once so the per-frame lookups don't allocate.
    private let statusKey = SCStreamFrameInfo.status.rawValue as CFString
    private let displayTimeKey = SCStreamFrameInfo.displayTime.rawValue as CFString

    public override init() { super.init() }

    public func start(_ config: FrameSourceConfig, onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
                      onError: @escaping @Sendable (any Error) -> Void) async throws {
        // A just-created display can take a moment to become shareable.
        var display: SCDisplay?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            display = content.displays.first { $0.displayID == config.displayID }
            if display == nil { try await Task.sleep(for: .milliseconds(100)) }
        } while display == nil && Date() < deadline
        guard let display else { throw Failure.displayNotShareable(config.displayID) }

        let sc = SCStreamConfiguration()
        sc.width = config.pixelWidth
        sc.height = config.pixelHeight
        sc.pixelFormat = config.pixelFormat
        sc.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
        sc.showsCursor = false                       // the client draws the cursor (invariant 1)
        sc.queueDepth = 4                            // a surface pool, not a latency queue (§5.2)
        sc.colorSpaceName = CGColorSpace.displayP3
        sc.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: sc, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let proceed = state.withLock { s -> Bool in
            guard !s.stopped else { return false }
            s.stream = stream
            s.onFrame = onFrame
            s.onError = onError
            return true
        }
        guard proceed else { return }
        try await stream.startCapture()
        if state.withLock({ $0.stopped }) {
            // stop() ran while capture was starting and found nothing to stop yet.
            try? await stream.stopCapture()
            return
        }
        log.notice("capturing display \(config.displayID) \(config.pixelWidth)×\(config.pixelHeight) at \(config.frameRate) Hz")
    }

    public func stop() async {
        let stream = state.withLock { s -> SCStream? in
            s.stopped = true
            s.onFrame = nil
            s.onError = nil
            defer { s.stream = nil }
            return s.stream
        }
        try? await stream?.stopCapture()
    }

    // MARK: SCStreamOutput (the capture queue: real-time, no awaits, no Swift collection bridging)

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0,
              let first = CFArrayGetValueAtIndex(attachments, 0) else { return }
        let info = unsafeBitCast(first, to: CFDictionary.self)
        guard let rawStatus = CFDictionaryGetValue(info, Unmanaged.passUnretained(statusKey).toOpaque()) else { return }
        var status = 0
        CFNumberGetValue(unsafeBitCast(rawStatus, to: CFNumber.self), .nsIntegerType, &status)
        guard status == SCFrameStatus.complete.rawValue, let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
        var captureNs = MonotonicClock.now()
        if let rawTime = CFDictionaryGetValue(info, Unmanaged.passUnretained(displayTimeKey).toOpaque()) {
            var ticks: UInt64 = 0
            if CFNumberGetValue(unsafeBitCast(rawTime, to: CFNumber.self), .sInt64Type, &ticks), ticks > 0 {
                captureNs = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
            }
        }
        state.withLock { $0.onFrame }?(buffer, captureNs)
    }

    // MARK: SCStreamDelegate

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        log.error("capture stopped: \(error)")
        let handler = state.withLock { s -> (@Sendable (any Error) -> Void)? in
            defer { s.onError = nil; s.onFrame = nil }
            return s.stopped ? nil : s.onError
        }
        if let e = error as? SCStreamError, e.code == .userStopped { handler?(CaptureStoppedByUser()) } else { handler?(error) }
    }
}
#endif
