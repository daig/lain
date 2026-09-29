#if os(macOS)
import AppKit
import CoreMedia
import Foundation
import LainMedia
import LainTelemetry
@preconcurrency import ScreenCaptureKit

/// `LainHost --bench headless` (S2 remainder, M4 planning): does the Mac need a dummy display plug?
/// The owner starts it, then unplugs every physical monitor. With zero physical displays it creates the
/// virtual display, checks that it becomes main, that the window server renders to it (frames are
/// neither black nor frozen), that ScreenCaptureKit delivers and the hardware encoder works; then it
/// destroys and recreates the display (an iPad reconnect without keep-alive) and checks again. Progress
/// is spoken (`say`) because the owner can't see the Mac. Launch with `open` so TCC applies.
public enum HeadlessBench {
    static func physicalDisplays() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetOnlineDisplayList(n, &ids, &n)
        // Ours are vendor "LA". With no monitor attached, macOS creates its own 1920×1080 placeholder,
        // vendor "unkn" (0x756E6B6E) model "virt" (0x76697274) (observed 2026-09-28): not physical either.
        return ids.filter { CGDisplayVendorNumber($0) != 0x4C41 && !isPlaceholder($0) }
    }

    static func isPlaceholder(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == 0x756E_6B6E && CGDisplayModelNumber(id) == 0x7669_7274
    }

    static func describe(_ id: CGDirectDisplayID) -> String {
        let b = CGDisplayBounds(id)
        return "\(id) vendor \(String(CGDisplayVendorNumber(id), radix: 16)) model \(String(CGDisplayModelNumber(id), radix: 16)) "
            + "\(Int(b.width))×\(Int(b.height)) active=\(CGDisplayIsActive(id) != 0) asleep=\(CGDisplayIsAsleep(id) != 0) "
            + "online=\(CGDisplayIsOnline(id) != 0) main=\(CGDisplayIsMain(id) != 0)"
    }

    static func say(_ text: String) {
        print("🔊 \(text)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = [text]
        try? p.run()
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    static func describeDisplays(_ label: String) {
        let active = VirtualDisplay.activeDisplays()
        let main = CGMainDisplayID()
        let items = active.map { id -> String in
            let b = CGDisplayBounds(id)
            return "\(id)\(id == main ? "*" : "")\(CGDisplayVendorNumber(id) == 0x4C41 ? "(lain)" : isPlaceholder(id) ? "(macOS placeholder)" : "") \(Int(b.width))×\(Int(b.height))@(\(Int(b.origin.x)),\(Int(b.origin.y)))"
        }
        print("\(stamp()) [\(label)] active displays (* = main): \(items.isEmpty ? "none" : items.joined(separator: ", ")); physical online: \(physicalDisplays())")
    }

    @MainActor
    public static func run() async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else {
            print("LainHost needs Screen Recording (grant it, then run again).")
            return 3
        }
        describeDisplays("start")
        if ProcessInfo.processInfo.environment["LAIN_HEADLESS_DRY_RUN"] == nil {
            say("Lain headless test. Unplug all monitors now. I will talk you through it.")
        }
        print("\(stamp()) waiting up to 10 minutes for zero physical displays…")
        let deadline = Date().addingTimeInterval(600)
        // LAIN_HEADLESS_DRY_RUN=1: skip the unplug step (checks the bench itself with monitors attached).
        let dryRun = ProcessInfo.processInfo.environment["LAIN_HEADLESS_DRY_RUN"] != nil
        var lastSeen = ""
        while !dryRun {
            let physical = physicalDisplays()
            let seen = physical.map(describe).joined(separator: "; ")
            if seen != lastSeen {
                print("\(stamp()) physical displays online: \(physical.isEmpty ? "none" : seen)")
                if !lastSeen.isEmpty {
                    let live = physical.filter { CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 }.count
                    say(live == 0 ? "No active monitors." : "\(live) monitor\(live == 1 ? "" : "s") still detected.")
                }
                lastSeen = seen
            }
            // Headless may leave a placeholder that's online but not active (or asleep); count only live ones.
            if physical.allSatisfy({ CGDisplayIsActive($0) == 0 || CGDisplayIsAsleep($0) != 0 }) { break }
            if Date() > deadline {
                say("Timed out waiting for the monitors to be unplugged. Test cancelled.")
                return 2
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        describeDisplays("no physical displays")
        say("No monitors detected. Testing. Please wait about a minute.")
        try? await Task.sleep(for: .seconds(3))
        describeDisplays("headless, before virtual display")

        var ok = true
        for round in 1...2 {
            let passed = await trial(round: round)
            ok = ok && passed
            try? await Task.sleep(for: .seconds(3))
            describeDisplays("after round \(round) removed the virtual display")
        }

        say(ok ? "Test complete. All checks passed. Reconnect your monitors." : "Test complete, with failures. Reconnect your monitors.")
        print("\(stamp()) waiting up to 10 minutes for the monitors to come back…")
        let back = Date().addingTimeInterval(dryRun ? 0 : 600)
        while physicalDisplays().allSatisfy({ CGDisplayIsActive($0) == 0 || CGDisplayIsAsleep($0) != 0 }) && Date() < back {
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(3))
        describeDisplays("monitors back")
        say("Monitors are back. Lain headless test finished.")
        print("\(stamp()) RESULT: \(ok ? "PASS" : "FAIL")")
        return ok ? 0 : 1
    }

    /// Creates the display, captures an animated window, checks the frames, encodes, removes the display.
    @MainActor
    static func trial(round: Int) async -> Bool {
        print("\n\(stamp()) === round \(round) ===")
        let vd: VirtualDisplay
        do {
            vd = try VirtualDisplay()
            try await vd.waitUntilActive(timeout: 10)
        } catch {
            print("\(stamp()) virtual display FAILED: \(error)")
            return false
        }
        let selected = vd.selectNativeMode(refreshRate: 120) != nil
        try? await Task.sleep(for: .seconds(1))
        describeDisplays("round \(round) virtual display up")
        var isMain = CGMainDisplayID() == vd.displayID
        if !isMain {
            // What Primary mode (M4) will do: put our display at (0, 0), which makes it main.
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            CGConfigureDisplayOrigin(config, vd.displayID, 0, 0)
            let err = CGCompleteDisplayConfiguration(config, .forSession)
            try? await Task.sleep(for: .seconds(1))
            isMain = CGMainDisplayID() == vd.displayID
            print("\(stamp()) not main at first; moved to (0, 0): result \(err.rawValue), main now: \(isMain)")
            describeDisplays("round \(round) after making it main")
        }
        if let m = CGDisplayCopyDisplayMode(vd.displayID) {
            print(String(format: "%@ mode %d×%d pt, %d×%d px, %.0f Hz (native selected: %@); main: %@", stamp(), m.width, m.height,
                         m.pixelWidth, m.pixelHeight, m.refreshRate, "\(selected)", "\(isMain)"))
        }

        let window = VirtualDisplayBench.makeAnimatedWindow(on: vd.displayID)
        defer { window.orderOut(nil) }
        var passed = isMain
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == vd.displayID }) else {
                print("\(stamp()) ScreenCaptureKit doesn't list the virtual display")
                return false
            }
            let capture = VirtualDisplayBench.Capture()
            let config = SCStreamConfiguration()
            config.width = vd.spec.pixelWidth
            config.height = vd.spec.pixelHeight
            config.pixelFormat = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
            config.showsCursor = false
            config.queueDepth = 4
            config.colorSpaceName = CGColorSpace.displayP3
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
            try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
            try await stream.startCapture()
            try await Task.sleep(for: .milliseconds(500))
            capture.reset()
            try await Task.sleep(for: .seconds(10))
            let summary = capture.summary(seconds: 10)
            try await stream.stopCapture()
            print("\(stamp()) \(summary.describe("headless round \(round), animating 10 s"))")

            // Rendered, not black, not frozen.
            let frames = capture.keptFrames
            let lumas = frames.map(meanLuma)
            let motion = zip(frames, frames.dropFirst()).map { meanAbsDiff($0, $1) }
            let avgLuma = lumas.isEmpty ? 0 : lumas.reduce(0, +) / Double(lumas.count)
            let avgMotion = motion.isEmpty ? 0 : motion.reduce(0, +) / Double(motion.count)
            let fps = Double(summary.frames) / 10
            print(String(format: "%@ content: %d frames kept, mean luma %.0f / 1023 (white page expected ~900+), mean frame-to-frame change %.1f (moving bar expected > 0.5)",
                         stamp(), frames.count, avgLuma, avgMotion))
            let rendered = avgLuma > 500 && avgMotion > 0.5
            let fast = fps > 90
            print("\(stamp()) checks: main=\(isMain) rendered=\(rendered) fps>90=\(fast)")
            passed = passed && rendered && fast
            if !frames.isEmpty {
                print("\(stamp()) \(try await VirtualDisplayBench.encode(capture.keptFrames, width: vd.spec.pixelWidth, height: vd.spec.pixelHeight))")
            }
        } catch {
            print("\(stamp()) capture FAILED: \(error)")
            passed = false
        }
        withExtendedLifetime(vd) {}
        return passed
    }

    /// Mean 10-bit luma on a 16-pixel grid.
    static func meanLuma(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0 }
        let row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var sum = 0.0, n = 0.0
        for y in stride(from: 0, to: CVPixelBufferGetHeightOfPlane(pb, 0), by: 16) {
            let line = (base + y * row).assumingMemoryBound(to: UInt16.self)
            for x in stride(from: 0, to: CVPixelBufferGetWidthOfPlane(pb, 0), by: 16) { sum += Double(line[x] >> 6); n += 1 }
        }
        return n > 0 ? sum / n : 0
    }

    static func meanAbsDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0), let pb = CVPixelBufferGetBaseAddressOfPlane(b, 0) else { return 0 }
        let ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        var sum = 0.0, n = 0.0
        for y in stride(from: 0, to: CVPixelBufferGetHeightOfPlane(a, 0), by: 16) {
            let la = (pa + y * ra).assumingMemoryBound(to: UInt16.self), lb = (pb + y * rb).assumingMemoryBound(to: UInt16.self)
            for x in stride(from: 0, to: CVPixelBufferGetWidthOfPlane(a, 0), by: 16) {
                sum += abs(Double(la[x] >> 6) - Double(lb[x] >> 6)); n += 1
            }
        }
        return n > 0 ? sum / n : 0
    }
}
#endif
