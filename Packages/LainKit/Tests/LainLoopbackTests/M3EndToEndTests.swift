#if os(macOS)
import CoreGraphics
import CoreVideo
import Dispatch
import Foundation
import LainClientCore
import LainHostCore
import LainInput
import LainMedia
import LainProtocol
import LainTelemetry
import LainTestSupport
import LainTransport
import LainUSBMux
import Synchronization
import Testing

/// M3 end to end (§12.2 layer 2): the real `HostSession` + `HostVideoPipeline` (real `VideoEncoder`,
/// `FrameGate`, cursor monitor) with a fake lain display and a fake capture source feeding synthetic
/// scrolling text at 120 Hz ↔ fake usbmuxd ↔ the real `ClientSession` + `ClientVideoPipeline` (real
/// `VideoDecoder`) + the offscreen `VideoRenderer`. No virtual display, no ScreenCaptureKit, no TCC.
///
/// The stand-in Mac's desktop (global points): main 1680×1050 at (0, 0), the lain display 688×516 pt
/// (1376×1032 px at 2×) below main at (0, 1050) once video creates it, a 1920×1080 monitor left of
/// main, and macOS's "unkn/virt" placeholder, which the layout must leave out.
@Suite(.serialized) struct M3EndToEndTests {
    static let pixelWidth = 1376, pixelHeight = 1032
    static let lainID: UInt32 = 9
    static let lainBounds = CGRect(x: 0, y: 1050, width: 688, height: 516)
    static let settings = HostInputSettings(doubleClickIntervalMs: 500, keyRepeatDelayMs: 225, keyRepeatIntervalMs: 30,
                                            inputSourceID: "com.apple.keylayout.Colemak")

    static func hello(hardware444: Bool) -> Hello {
        Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
              decodeCapabilities: hardware444 ? [.hevcMain, .hevcMain44410Hardware] : [.hevcMain], keyboardType: .ansi)
    }

    /// BGRA originals and their capture-format copies (no attachments, like SCK frames: the host must
    /// tag them). Read-only after creation.
    struct Frames: @unchecked Sendable {
        let bgra: [CVPixelBuffer]
        let captured: [CVPixelBuffer]
        init(format: OSType) {
            bgra = SyntheticFrames.scrollingText(width: M3EndToEndTests.pixelWidth, height: M3EndToEndTests.pixelHeight, count: 4)
            captured = SyntheticFrames.convert(bgra, to: format)
            captured.forEach { CVBufferRemoveAllAttachments($0) }
        }
    }

    // MARK: Fakes

    /// The lain virtual display: "created" by the video pipeline, and listed among the active displays
    /// only while it exists.
    final class FakeLainDisplay: StreamedDisplayProvider, ActiveDisplaySource {
        private let state = Mutex((alive: false, created: 0, destroyed: 0))
        /// Like the window server, the display leaves the active list a while after it is released.
        let removalDelayMs: Int
        init(removalDelayMs: Int = 0) { self.removalDelayMs = removalDelayMs }
        var alive: Bool { state.withLock { $0.alive } }
        var created: Int { state.withLock { $0.created } }
        var destroyed: Int { state.withLock { $0.destroyed } }

        func create() async throws -> StreamedDisplay {
            state.withLock { $0.alive = true; $0.created += 1 }
            return StreamedDisplay(displayID: M3EndToEndTests.lainID, pixelWidth: M3EndToEndTests.pixelWidth,
                                   pixelHeight: M3EndToEndTests.pixelHeight, bounds: M3EndToEndTests.lainBounds, refreshRate: 120)
        }
        func currentBounds() -> CGRect? { alive ? M3EndToEndTests.lainBounds : nil }
        func destroy() {
            let remove: @Sendable () -> Void = { [self] in
                state.withLock { s in
                    if s.alive { s.destroyed += 1 }
                    s.alive = false
                }
            }
            if removalDelayMs == 0 { remove() } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(removalDelayMs), execute: remove)
            }
        }
        func waitUntilRemoved() async {
            // Polled like `VirtualDisplay.waitUntilGone`: at its pace even on a cancelled task (a detach
            // during video start), where `Task.sleep` would return at once and spin.
            while alive {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { c.resume() }
                }
            }
        }

        func activeDisplays() -> [ActiveDisplay] {
            var all = [
                ActiveDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1680, height: 1050), isMain: true),
                ActiveDisplay(displayID: 4, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080)),
                ActiveDisplay(displayID: 77, bounds: CGRect(x: 1680, y: 0, width: 1920, height: 1080),
                              vendor: ActiveDisplay.placeholderVendor, model: ActiveDisplay.placeholderModel),
            ]
            if alive { all.append(ActiveDisplay(displayID: M3EndToEndTests.lainID, bounds: M3EndToEndTests.lainBounds)) }
            return all
        }
    }

    final class Status<T: Sendable>: Sendable {
        private let items = Mutex<[T]>([])
        func put(_ v: T) { items.withLock { $0.append(v) } }
        var last: T? { items.withLock { $0.last } }
        var all: [T] { items.withLock { $0 } }
    }

    /// What the client's decoder factory saw: the stream's configs and each decoder's chroma_format_idc.
    final class DecoderLog: Sendable {
        private let items = Mutex<[(chroma: ChromaFormat, idc: Int?)]>([])
        func put(_ c: ChromaFormat, _ idc: Int?) { items.withLock { $0.append((c, idc)) } }
        var all: [(chroma: ChromaFormat, idc: Int?)] { items.withLock { $0 } }
    }

    // MARK: The test

    @Test(arguments: [true, false])
    func videoAndFullDesktopInputEndToEnd(hardware444: Bool) async throws {
        let expected: ChromaFormat = hardware444 ? .yuv444 : .yuv420
        let frames = Frames(format: expected.pixelFormat)
        let lain = FakeLainDisplay()
        let capture = FakeFrameSource()
        // The Mac's real cursor starts in the middle of the lain display.
        let mac = InputLoopbackTests.VirtualMac(
            display: HostDisplay(displayID: 1, origin: .zero, pointSize: CGSize(width: 1680, height: 1050)),
            layout: DisplayLayout(displays: []), cursor: CGPoint(x: 344, y: 1308))
        let power = InputLoopbackTests.FakePower()
        let decoders = DecoderLog()
        let video = ClientVideoPipeline(makeDecoder: { config, hardware, onOutput in
            let d = try VideoDecoder(config: config, requireHardware: hardware, onOutput: onOutput)
            decoders.put(config.chroma, d.chromaFormatIDC)
            return d
        })
        let clientStatus = Status<ClientSession.Status>(), hostStatus = Status<HostStatus>()
        let client = try ClientSession(port: 0, secrets: InMemorySecretStore(), hello: Self.hello(hardware444: hardware444),
                                       video: video) { clientStatus.put($0) }
        let mux = try FakeUSBMuxd(devices: [.init(deviceID: 7, serialNumber: "IPAD-7")], targetPort: client.port)
        let pipelines = Status<HostVideoPipeline>()
        let deps = HostSession.Dependencies(
            usbmux: USBMuxClient(socketPath: mux.socketPath), secrets: InMemorySecretStore(), sink: mac,
            display: DisplayLayoutProvider(source: lain, streamedDisplayID: { nil }, cursor: { mac.cursorLocation() }),
            power: power, settings: { Self.settings },
            video: {
                let p = HostVideoPipeline(display: lain, frameSource: capture, cursorSource: FakeCursor())
                pipelines.put(p)
                return p
            })
        let host = HostSession(dependencies: deps) { hostStatus.put($0) }
        defer {
            host.stop()
            mux.stop()
            client.stop()
        }
        host.start()

        // 1. Handshake: video starts first (the lain display exists), then HelloAck carries its point
        //    size, and DisplayLayout lists the three real displays with the lain display streamed.
        #expect(await eventually {
            if case .connected(let i) = clientStatus.last { i.isConfigured && i.displayCount == 3 } else { false }
        })
        guard case .connected(let info) = clientStatus.last else { Issue.record("not connected"); return }
        #expect(info.displayPointWidth == 688 && info.displayPointHeight == 516)
        // The HelloAck itself (the first configured snapshot, before any layout) carried the lain
        // display's size and the chroma streamed.
        let acked = clientStatus.all.compactMap { if case .connected(let i) = $0, i.isConfigured { i } else { nil } }.first
        #expect(acked?.displayPointWidth == 688 && acked?.displayPointHeight == 516 && acked?.displayCount == 1)
        #expect(acked?.chroma == expected)
        #expect(lain.alive && lain.created == 1)
        let pipeline = try #require(pipelines.all.first)
        #expect(pipeline.chroma == expected)
        #expect(pipeline.streamedDisplayID == Self.lainID)
        #expect(capture.config?.pixelFormat == expected.pixelFormat)
        #expect(await eventually { client.input.cursor.globalX == 344 && client.input.cursor.globalY == 1308 })
        client.input.sync { p in
            #expect(p.hasLayout && p.pointer.displays.count == 3)
            #expect(p.streamedDisplay == DesktopDisplay(x: 0, y: 1050, width: 688, height: 516))
        }
        let start = client.input.cursor
        #expect(start.onStream && start.x == 344 && start.y == 258)
        // The cursor monitor's shape reached the client's overlay.
        #expect(await eventually { video.cursor.current.sprite.pixelWidth == 2 })

        // 2. Video: synthetic scrolling text at 120 Hz. The first thing decoded is VideoConfig then a
        //    keyframe (no keyframe request was needed), in the negotiated chroma; acks gate the host.
        try await capture.feed(frames.captured, count: 60)
        #expect(await eventually { video.stats().framesDecoded >= 10 })
        let first = video.stats()
        #expect(first.keyframeRequests == 0 && first.sequenceGaps == 0 && first.decodeErrors == 0)
        #expect(first.chroma == expected)
        let log = decoders.all
        #expect(log.count == 1 && log.first?.chroma == expected)
        #expect(log.first?.idc == (hardware444 ? 3 : 1))
        let hostStats = pipeline.stats
        #expect(hostStats.peakInFlight <= 2 && hostStats.peakInFlight >= 1)
        #expect(hostStats.keyframes >= 1 && hostStats.encodeFailures == 0)
        #expect(hostStats.encoded + hostStats.droppedBeforeEncode <= hostStats.offered)
        #expect(await eventually { pipeline.stats.inFlight == 0 })   // every frame acked

        // 3. The picture: the last frame fed, after idle refinement, rendered offscreen, matches the
        //    original BGRA (4:2:0 loses chroma detail on coloured text by design; §5.3).
        let lastFed = frames.bgra[(60 - 1) % frames.bgra.count]
        try await Task.sleep(for: .milliseconds(450))   // two refinements at 150 and 300 ms
        #expect(pipeline.stats.refinements >= 1)
        var newest: DecodedFrame?
        while let f = video.latest.take() { newest = f }
        let frame = try #require(newest)
        #expect(CVPixelBufferGetPixelFormatType(frame.image) == expected.pixelFormat)
        #expect(CVPixelBufferGetWidth(frame.image) == Self.pixelWidth && CVPixelBufferGetHeight(frame.image) == Self.pixelHeight)
        let renderer = try VideoRenderer(pixelFormat: .bgra8Unorm)
        let rendered = VideoRenderer.readBGRA8(try #require(renderer.renderOffscreen(
            VideoRenderer.Scene(frame: frame), width: Self.pixelWidth, height: Self.pixelHeight)))
        let psnr = bgraPSNR(rendered, lastFed)
        print(String(format: "M3 e2e %@: PSNR B %.1f G %.1f R %.1f dB; host peak in flight %d, dropped before encode %d",
                     hardware444 ? "4:4:4" : "4:2:0", psnr[0], psnr[1], psnr[2], hostStats.peakInFlight,
                     hostStats.droppedBeforeEncode))
        #expect(psnr.allSatisfy { $0 >= (hardware444 ? 35 : 25) })

        // 4. Loss recovery (D22): the client's KeyframeRequest (as after a sequence gap) goes over the
        //    realtime channel; the host re-encodes its last frame as a keyframe even though capture is
        //    idle, and the client decodes it.
        let keyframesBefore = pipeline.stats.keyframes
        let decodedBefore = video.stats().framesDecoded
        video.requestKeyframe(.sequenceGap)
        #expect(await eventually { pipeline.stats.keyframes > keyframesBefore })
        #expect(await eventually { video.stats().framesDecoded > decodedBefore })
        #expect(video.stats().decodeErrors == 0)

        // 5. Full desktop: straight up off the lain display onto main (they share main's bottom edge):
        //    the Mac gets the move in global points and the client stops drawing its cursor.
        let red = CursorSprite(key: 1, pixelWidth: 4, pixelHeight: 4, scale: 2, hotspotX: 0, hotspotY: 0,
                               pixels: (0..<16).flatMap { _ in [0, 0, 255, 255] as [UInt8] })
        func cursorPixels() throws -> Int {
            let c = client.input.cursor
            let scene = VideoRenderer.Scene(displayPointSize: c.streamedSize.map { SIMD2($0.width, $0.height) },
                                            cursorPoint: c.streamedPoint.map { SIMD2($0.x, $0.y) },
                                            cursorSprite: c.streamedPoint == nil ? nil : red)
            let px = VideoRenderer.readBGRA8(try #require(renderer.renderOffscreen(scene, width: 688, height: 516)))
            return stride(from: 0, to: px.count, by: 4).count { px[$0 + 2] > 200 && px[$0] < 50 }
        }
        #expect(try cursorPixels() > 0)   // on the lain display: drawn
        let mark = mac.inputCalls.count
        client.input.setCurve(AccelerationCurve(sensitivity: 1, acceleration: 0))
        client.input.mouseMoved(dx: 0, dy: 600)     // up-positive in
        #expect(await eventually { mac.inputCalls.count > mark })
        #expect(mac.inputCalls.dropFirst(mark).first == .move(PointerMove(x: 344, y: 708, dx: 0, dy: -600, buttons: 0)))
        #expect(mac.cursorLocation() == CGPoint(x: 344, y: 708))
        #expect(await eventually { !client.input.cursor.onStream })
        #expect(client.input.cursor.streamedPoint == nil)
        #expect(try cursorPixels() == 0)  // on main: not drawn
        // Left along main onto the side monitor (they share main's left edge), then back down onto
        // the lain display via main.
        client.input.mouseMoved(dx: -600, dy: 0)
        #expect(await eventually { mac.cursorLocation() == CGPoint(x: -256, y: 708) })
        client.input.mouseMoved(dx: 400, dy: 0)
        client.input.mouseMoved(dx: 0, dy: -500)
        #expect(await eventually { mac.cursorLocation() == CGPoint(x: 144, y: 1208) })
        #expect(await eventually { client.input.cursor.onStream })
        #expect(client.input.cursor.x == 144 && client.input.cursor.y == 158)
        #expect(try cursorPixels() > 0)

        // 6. Detach with a button held: video stops (capture stopped, lain display removed), the host
        //    releases everything once, and the client goes back to listening.
        client.input.mouseButton(.left, isDown: true)
        #expect(await eventually { mac.inputCalls.last.map { if case .button = $0 { true } else { false } } ?? false })
        mux.detach(deviceID: 7)
        #expect(await eventually { mac.inputCalls.last == .releaseAll })
        #expect(await eventually { !pipeline.isRunning && capture.stops >= 1 && !lain.alive && lain.destroyed == 1 })
        #expect(await eventually { hostStatus.last == .waitingForIPad })
        #expect(await eventually { !power.holding })
        #expect(await eventually { if case .listening = clientStatus.last { true } else { false } })
        #expect(host.videoStats == nil)

        // 7. Replug: a fresh session creates the display again and streams.
        mux.attach(.init(deviceID: 7, serialNumber: "IPAD-7"))
        #expect(await eventually { pipelines.all.count == 2 && lain.alive && lain.created == 2 })
        #expect(await eventually { host.videoStats != nil })
        let decodedBeforeReplug = video.stats().framesDecoded
        try await capture.feed(frames.captured, count: 12)
        #expect(await eventually { video.stats().framesDecoded > decodedBeforeReplug })
    }

    /// Capture (or the virtual display) failing at start leaves an input-only session on the main
    /// display, with the reason for the menu.
    /// Host tracker → client overlay over many more distinct cursors than either keeps: whatever the
    /// Mac shows is always drawn (never the built-in arrow once shapes exist).
    @Test func manyCursorShapesNeverFallBackToTheArrow() {
        var tracker = CursorShapeTracker()
        let overlay = CursorOverlay()
        var rng = SystemRandomNumberGenerator()
        var order = Array(0..<150) + (0..<600).map { _ in Int.random(in: 0..<150, using: &rng) }
        order += Array(0..<150)
        for n in order {
            let pixels = [UInt8](repeating: UInt8(n % 256), count: 16) + [UInt8(n / 256), 0, 0, 0] + [UInt8](repeating: 0, count: 12)
            let img = CursorImage(pixelWidth: 2, pixelHeight: 4, scale: 2, hotspotX: 0, hotspotY: 0, pixels: pixels)
            for m in tracker.update(img) { overlay.apply(m) }
            let sprite = overlay.current.sprite
            #expect(sprite != .arrow && sprite.pixels == pixels, "cursor \(n)")
            if sprite == .arrow { return }
        }
        #expect(tracker.uniqueShapes <= CursorShape.maxLive)
    }

    /// Capture that starts, then stops on its own shortly after (SCK's didStopWithError).
    final class StoppingSource: FrameSource {
        let makeError: @Sendable () -> any Error
        init(_ makeError: @escaping @Sendable () -> any Error) { self.makeError = makeError }
        func start(_ config: FrameSourceConfig, onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
                   onError: @escaping @Sendable (any Error) -> Void) async throws {
            let makeError = makeError
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { onError(makeError()) }
        }
        func stop() async {}
    }

    /// A host session over `source` with an input-only stand-in Mac; returns what the test watches.
    static func stoppingRig(_ source: @escaping @Sendable () -> any FrameSource, tuning: HostSession.Tuning = .init()) throws
        -> (host: HostSession, lain: FakeLainDisplay, mac: InputLoopbackTests.VirtualMac, client: ClientSession,
            status: Status<ClientSession.Status>, stop: @Sendable () -> Void) {
        let lain = FakeLainDisplay()
        let mac = InputLoopbackTests.VirtualMac(
            display: HostDisplay(displayID: 1, origin: .zero, pointSize: CGSize(width: 1680, height: 1050)),
            layout: DisplayLayout(displays: []), cursor: CGPoint(x: 100, y: 100))
        let status = Status<ClientSession.Status>()
        let client = try ClientSession(port: 0, secrets: InMemorySecretStore(), hello: Self.hello(hardware444: true),
                                       video: ClientVideoPipeline()) { status.put($0) }
        let mux = try FakeUSBMuxd(devices: [.init(deviceID: 7, serialNumber: "IPAD-7")], targetPort: client.port)
        let host = HostSession(dependencies: HostSession.Dependencies(
            usbmux: USBMuxClient(socketPath: mux.socketPath), secrets: InMemorySecretStore(), sink: mac,
            display: DisplayLayoutProvider(source: lain, streamedDisplayID: { nil }, cursor: { mac.cursorLocation() }),
            power: InputLoopbackTests.FakePower(), settings: { Self.settings },
            video: { HostVideoPipeline(display: lain, frameSource: source(), cursorSource: nil) }), tuning: tuning)
        host.start()
        return (host, lain, mac, client, status, { host.stop(); mux.stop(); client.stop() })
    }

    @Test func captureStoppedByTheUserKeepsAnInputOnlySession() async throws {
        let rig = try Self.stoppingRig { StoppingSource { CaptureStoppedByUser() } }
        defer { rig.stop() }
        #expect(await eventually { rig.lain.created == 1 && !rig.lain.alive })
        #expect(await eventually { rig.host.videoError != nil })
        // Not restarted: the session goes on with the same link, no new display.
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.lain.created == 1)
        #expect(rig.host.status == .connected(deviceModel: "iPad16,6"))
        #expect(!rig.mac.inputCalls.contains(.releaseAll))
        let mark = rig.mac.inputCalls.count
        rig.client.input.mouseMoved(dx: 10, dy: 0)
        #expect(await eventually { rig.mac.inputCalls.count > mark })
    }

    @Test func recurringCaptureErrorsBackOff() async throws {
        struct Broken: Error {}
        var tuning = HostSession.Tuning()
        tuning.captureRetryInterval = .milliseconds(200)
        let rig = try Self.stoppingRig({ StoppingSource { Broken() } }, tuning: tuning)
        defer { rig.stop() }
        #expect(await eventually { rig.lain.created >= 2 })        // the first one redials at once
        try await Task.sleep(for: .milliseconds(1000))
        // Immediate, then 200, 400, 800 ms apart: a handful of sessions, not one every few ms.
        #expect(rig.lain.created <= 6, "\(rig.lain.created) sessions")
    }

    @Test func videoFailureLeavesAnInputOnlySession() async throws {
        struct Denied: Error {}
        final class FailingSource: FrameSource {
            func start(_ config: FrameSourceConfig, onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
                       onError: @escaping @Sendable (any Error) -> Void) async throws { throw Denied() }
            func stop() async {}
        }
        // The failed start's display lingers in the active list, as a released CGVirtualDisplay does.
        let lain = FakeLainDisplay(removalDelayMs: 300)
        let mac = InputLoopbackTests.VirtualMac(
            display: HostDisplay(displayID: 1, origin: .zero, pointSize: CGSize(width: 1680, height: 1050)),
            layout: DisplayLayout(displays: []), cursor: CGPoint(x: 100, y: 100))
        let clientStatus = Status<ClientSession.Status>()
        let client = try ClientSession(port: 0, secrets: InMemorySecretStore(), hello: Self.hello(hardware444: true),
                                       video: ClientVideoPipeline()) { clientStatus.put($0) }
        let mux = try FakeUSBMuxd(devices: [.init(deviceID: 7, serialNumber: "IPAD-7")], targetPort: client.port)
        let host = HostSession(dependencies: HostSession.Dependencies(
            usbmux: USBMuxClient(socketPath: mux.socketPath), secrets: InMemorySecretStore(), sink: mac,
            display: DisplayLayoutProvider(source: lain, streamedDisplayID: { nil }, cursor: { mac.cursorLocation() }),
            power: InputLoopbackTests.FakePower(), settings: { Self.settings },
            video: { HostVideoPipeline(display: lain, frameSource: FailingSource(), cursorSource: nil) }))
        defer {
            host.stop()
            mux.stop()
            client.stop()
        }
        host.start()
        #expect(await eventually {
            if case .connected(let i) = clientStatus.last { i.isConfigured && i.displayCount == 2 } else { false }
        })
        guard case .connected(let info) = clientStatus.last else { Issue.record("not connected"); return }
        #expect(info.displayPointWidth == 1680 && info.displayPointHeight == 1050)   // main: nothing streamed
        // Neither HelloAck nor any layout ever described the display being torn down.
        let seen = clientStatus.all.compactMap { if case .connected(let i) = $0, i.isConfigured { i } else { nil } }
        #expect(seen.allSatisfy { $0.displayPointWidth == 1680 && $0.displayCount <= 2 })
        #expect(!lain.alive && lain.destroyed == 1)
        #expect(host.videoError?.contains("Denied") == true)
        #expect(host.videoStats == nil)
        let mark = mac.inputCalls.count
        client.input.mouseMoved(dx: 10, dy: 0)
        #expect(await eventually { mac.inputCalls.count > mark })
    }
}

/// Polls `condition` until it holds or `seconds` pass.
private func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
#endif
