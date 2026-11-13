import CoreVideo
import Foundation
import LainProtocol

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

/// A source of the host's sound for the session (v6 `AudioPacket`). The real one is the screen capture, which
/// hears what the Mac plays.
public protocol AudioSource: AnyObject, Sendable {
    /// What the handler gets: interleaved 16-bit little-endian PCM.
    var audioFormat: AudioConfig { get }
    /// `handler` is called on the source's own queue with a few milliseconds of sound and when it was captured
    /// (`CLOCK_UPTIME_RAW` ns); nil stops the calls.
    func setAudioHandler(_ handler: (@Sendable ([UInt8], UInt64) -> Void)?)
}

#if os(macOS)
import CoreMedia
import LainTelemetry
@preconcurrency import ScreenCaptureKit
import Synchronization

/// The audio handler, set by the session and called from the audio queue with each buffer. The closure is kept
/// in a struct, never bare in the `Mutex`: a bare function type is reabstracted on its way into `withLock`'s
/// `inout` and again on the way back, so every read wrapped the stored closure once more (two stack frames per
/// read, measured). Read with each of ~47 buffers a second, the chain overflowed the audio queue's stack after
/// about 2¼ minutes, and freeing it at a session's end overflowed too: the host crashed and the client
/// reconnected every couple of minutes while the Mac's sound played on the iPad (2026-11-12, §13).
final class AudioHandlerSlot: Sendable {
    struct Handler: Sendable { let call: @Sendable ([UInt8], UInt64) -> Void }
    private let slot = Mutex<Handler?>(nil)

    func set(_ handler: (@Sendable ([UInt8], UInt64) -> Void)?) {
        let new = handler.map(Handler.init(call:))
        slot.withLock { $0 = new }
    }

    var current: Handler? { slot.withLock { $0 } }
}

/// The real source: an `SCStream` on the streamed display, configured per §5.2 and the S2 findings.
/// SCK `xf44` frames carry a Display P3 `CGColorSpace` but **no YCbCr matrix**, so the stream's
/// `colorMatrix` is set explicitly to BT.709 (the host tags each buffer to match before encoding).
/// SCK delivers nothing while the display is idle; idle refinement handles that (§5.3).
public final class ScreenCaptureFrameSource: NSObject, FrameSource, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public enum Failure: Error { case displayNotShareable(UInt32) }

    private let queue = DispatchQueue(label: "lain.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "lain.capture.audio", qos: .userInteractive)
    /// 24 kHz mono: plenty for alerts and speech, which is what this is for, and a quarter of the data of
    /// 48 kHz stereo, so each 20 ms packet fits one TCP segment and takes less of the radio from the video.
    public let audioFormat = AudioConfig(sampleRate: 24_000, channels: 1, encoding: .pcm16LE)
    private let audioHandler = AudioHandlerSlot()
    private struct AudioMeter { var since: UInt64 = 0, last: UInt64 = 0, buffers = 0, frames = 0, maxGapMs = 0.0, maxAgeMs = 0.0 }
    private let audioMeter = Mutex(AudioMeter())
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
        // The Mac's sound, for the iPad's speakers: everything it plays but lain's own.
        sc.capturesAudio = true
        sc.sampleRate = Int(audioFormat.sampleRate)
        sc.channelCount = Int(audioFormat.channels)
        sc.excludesCurrentProcessAudio = true
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: sc, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
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

    public func setAudioHandler(_ handler: (@Sendable ([UInt8], UInt64) -> Void)?) {
        audioHandler.set(handler)
    }

    /// One buffer of sound (the audio queue): SCK's 32-bit float samples, planar or interleaved, as interleaved
    /// 16-bit, to the handler.
    private func audio(_ sample: CMSampleBuffer) {
        guard let handler = audioHandler.current, let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return }
        let frames = CMSampleBufferGetNumSamples(sample), channels = Int(audioFormat.channels)
        guard frames > 0 else { return }
        var out = [UInt8](repeating: 0, count: frames * channels * 2)
        let ok: Bool? = try? sample.withAudioBufferList { list, _ in
            let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let sourceChannels = Int(asbd.mChannelsPerFrame)
            guard sourceChannels > 0, list.count >= (planar ? 1 : 1) else { return false }
            out.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Int16.self)
                for c in 0..<channels {
                    let sc = min(c, sourceChannels - 1)   // mono fills both
                    let buffer = planar ? list[min(sc, list.count - 1)] : list[0]
                    guard let data = buffer.mData else { continue }
                    let src = data.assumingMemoryBound(to: Float32.self)
                    let stride = planar ? 1 : sourceChannels, offset = planar ? 0 : sc
                    let available = Int(buffer.mDataByteSize) / 4 / stride
                    for i in 0..<min(frames, available) {
                        let v = max(-1, min(1, src[i * stride + offset]))
                        dst[i * channels + c] = Int16(v * 32767).littleEndian
                    }
                }
            }
            return true
        }
        guard ok == true else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let now = MonotonicClock.now()
        let ns = time.isValid ? UInt64(max(0, time.seconds) * 1e9) : now
        // How the capture delivers sound, every few seconds: buffer length, the longest wait between two, and
        // how old a buffer's first sample is when it gets here.
        let report = audioMeter.withLock { m -> String? in
            if m.last != 0 { m.maxGapMs = max(m.maxGapMs, Double(now - m.last) / 1e6) }
            m.last = now
            m.buffers += 1
            m.frames += frames
            m.maxAgeMs = max(m.maxAgeMs, (Double(now) - Double(ns)) / 1e6)
            guard now - m.since > 5_000_000_000 else { return nil }
            defer { m = AudioMeter(since: now, last: now) }
            return "audio capture: \(m.buffers) buffers of \(m.frames / max(m.buffers, 1)) frames in 5 s, longest wait \(Int(m.maxGapMs)) ms, oldest on delivery \(Int(m.maxAgeMs)) ms"
        }
        if let report { log.debug("\(report, privacy: .public)") }
        handler.call(out, ns)
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { return audio(sample) }
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
