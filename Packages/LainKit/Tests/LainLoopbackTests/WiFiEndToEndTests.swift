#if os(macOS)
import CoreGraphics
import CoreVideo
import Dispatch
import LainInput
import LainMedia
import LainProtocol
import LainTelemetry
import LainTestSupport
import LainTransport
import LainUSBMux
import Network
import Synchronization
import Testing
@testable import LainClientCore
@testable import LainHostCore

/// M6a end to end (§7.7 D29, §12.2 layer 2): the owner's first morning with Wi-Fi, on one Mac over
/// loopback. The real `HostSession` (host identity X; Wi-Fi on a loopback-only TLS-PSK listener that is
/// never advertised; the iPad on a fake usbmuxd; each session's video from its own fake lain display and
/// fake capture through the real `HostVideoPipeline` and encoder) ↔ the real `ClientSession` (a
/// `FixedHostDiscovery` reporting X at the listener's port, a short grace; the real `ClientVideoPipeline`
/// and decoder) + the offscreen `VideoRenderer`. Nothing browses or advertises.
///
/// It starts from the migration state a v1 pairing leaves: the iPad holds the secret only as "host", the
/// Mac under the iPad's serial. No Wi-Fi dial until a USB session has recorded `mac:X`; then unplugging
/// moves the session to Wi-Fi (4:4:4 video decoded and rendered, input injected), replugging hands it
/// back to USB (the Wi-Fi session ends first, one release per session end, the display-sleep assertion
/// held, one lain display at a time), a last unplug falls back to Wi-Fi, and stopping releases
/// everything.
@Suite(.serialized) struct WiFiEndToEndTests {
    static let identity = HostIdentity(id: "0C3F8A52-6E1B-4D57-9A0E-2B7C4F1D8E36", name: "Test Mac")
    static let serial = "IPAD-7"
    static let lainID: UInt32 = 9
    /// The lain display below main, 688×516 pt (1376×1032 px at 2×).
    static let lainBounds = CGRect(x: 0, y: 1050, width: 688, height: 516)
    static let main = ActiveDisplay(displayID: 1, bounds: CGRect(x: 0, y: 0, width: 1680, height: 1050), isMain: true)
    static let lo0 = LinkTransport.network(interface: "lo0", peerToPeer: false)

    // MARK: Fakes

    /// The Mac's active displays: main, and the lain display while one exists. Each session's pipeline
    /// creates its own lain display (as `HostVideoPipeline.live()` does); on a Mac they share one
    /// persistent identity, so two must never exist at once (`peak`).
    final class Displays: ActiveDisplaySource {
        private let state = Mutex((live: 0, peak: 0, created: 0, removed: 0))
        var live: Int { state.withLock { $0.live } }
        var peak: Int { state.withLock { $0.peak } }
        var created: Int { state.withLock { $0.created } }
        var removed: Int { state.withLock { $0.removed } }

        func makeLain() -> LainDisplay { LainDisplay(displays: self) }

        fileprivate func added() {
            state.withLock { s in
                s.live += 1
                s.created += 1
                s.peak = max(s.peak, s.live)
            }
        }

        fileprivate func gone() {
            state.withLock { s in
                s.live -= 1
                s.removed += 1
            }
        }

        func activeDisplays() -> [ActiveDisplay] {
            guard live > 0 else { return [WiFiEndToEndTests.main] }
            return [WiFiEndToEndTests.main, ActiveDisplay(displayID: WiFiEndToEndTests.lainID, bounds: WiFiEndToEndTests.lainBounds)]
        }
    }

    /// One session's lain display (gone from the active list as soon as it is destroyed).
    final class LainDisplay: StreamedDisplayProvider {
        let displays: Displays
        private let alive = Mutex(false)
        init(displays: Displays) { self.displays = displays }

        func create() async throws -> StreamedDisplay {
            alive.withLock { $0 = true }
            displays.added()
            return StreamedDisplay(displayID: WiFiEndToEndTests.lainID, pixelWidth: M3EndToEndTests.pixelWidth,
                                   pixelHeight: M3EndToEndTests.pixelHeight, bounds: WiFiEndToEndTests.lainBounds, refreshRate: 120)
        }
        func currentBounds() -> CGRect? { alive.withLock { $0 } ? WiFiEndToEndTests.lainBounds : nil }
        func destroy() {
            let wasAlive = alive.withLock { a -> Bool in
                defer { a = false }
                return a
            }
            if wasAlive { displays.gone() }
        }
    }

    /// One session's video on the Mac: its pipeline and its capture.
    struct SessionVideo: Sendable {
        let pipeline: HostVideoPipeline
        let capture: FakeFrameSource
    }

    /// The display-sleep assertion, counted as `IOPMPowerAssertions` counts it: held while begins
    /// outnumber ends.
    final class CountedPower: PowerAssertions {
        private let state = Mutex((count: PowerAssertionCount(), begins: 0, ends: 0))
        var holding: Bool { state.withLock { $0.count.count > 0 } }
        var begins: Int { state.withLock { $0.begins } }
        var ends: Int { state.withLock { $0.ends } }
        func beginPreventingDisplaySleep() {
            state.withLock { s in
                _ = s.count.begin()
                s.begins += 1
            }
        }
        func endPreventingDisplaySleep() {
            state.withLock { s in
                _ = s.count.end()
                s.ends += 1
            }
        }
        func declareUserActivity() {}
    }

    /// What Bonjour would report, without browsing: each discovery the client makes (at start, and each
    /// time it browses again) gets the hosts shown so far; `show` updates the live ones too.
    final class Beacon: Sendable {
        private let state = Mutex<(hosts: [DiscoveredHost], made: [FixedHostDiscovery])>(([], []))

        func make() -> any HostDiscovery {
            state.withLock { s in
                let discovery = FixedHostDiscovery(hosts: s.hosts)
                s.made.append(discovery)
                return discovery
            }
        }

        func show(_ hosts: [DiscoveredHost]) {
            let made = state.withLock { s in
                s.hosts = hosts
                return s.made
            }
            made.forEach { $0.update(hosts: hosts) }
        }
    }

    /// Counts the client's Wi-Fi link attempts (`ClientWiFiConfig.interpose` wraps each one's dialer).
    final class Dials: Sendable {
        private let count = Atomic<Int>(0)
        var value: Int { count.load(ordering: .relaxed) }
        func counting(_ dialer: any StreamDialer) -> any StreamDialer {
            count.add(1, ordering: .relaxed)
            return dialer
        }
    }

    // MARK: The test

    @Test func fromAV1PairingOverTheCableToWiFiAndBack() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let macAccount = PairingAccounts.mac(Self.identity.id)
        let frames = M3EndToEndTests.Frames(format: ChromaFormat.yuv444.pixelFormat)
        let displays = Displays()
        // The Mac's real cursor starts in the middle of where the lain display will be.
        let mac = InputLoopbackTests.VirtualMac(
            display: HostDisplay(displayID: 1, origin: .zero, pointSize: CGSize(width: 1680, height: 1050)),
            layout: DisplayLayout(displays: []), cursor: CGPoint(x: 344, y: 1308))
        let power = CountedPower()
        // The migration state: the Mac keeps the pairing under the iPad's serial, the iPad (v1) only as "host".
        let hostSecrets = InputLoopbackTests.CountingSecrets()
        hostSecrets.inner.setSecret(secret, for: Self.serial)
        let clientSecrets = InputLoopbackTests.CountingSecrets()
        clientSecrets.inner.setSecret(secret, for: PairingAccounts.usbHost)

        let decoders = M3EndToEndTests.DecoderLog()
        let video = ClientVideoPipeline(makeDecoder: { config, hardware, onOutput in
            let d = try VideoDecoder(config: config, requireHardware: hardware, onOutput: onOutput)
            decoders.put(config.chroma, d.chromaFormatIDC)
            return d
        })
        let clientStatus = InputLoopbackTests.Recorder<ClientSession.Status>()
        let hostStatus = InputLoopbackTests.Recorder<HostStatus>()
        let beacon = Beacon(), dials = Dials()
        var wifi = ClientWiFiConfig(discovery: { beacon.make() }, options: .loopback)
        wifi.grace = 0.25
        wifi.interpose = { dials.counting($0) }
        let client = try ClientSession(port: 0, secrets: clientSecrets, hello: M3EndToEndTests.hello(hardware444: true),
                                       video: video, wifi: wifi) { clientStatus.put($0) }
        let mux = try FakeUSBMuxd(devices: [], targetPort: client.port)
        let sessions = InputLoopbackTests.Recorder<SessionVideo>()
        let deps = HostSession.Dependencies(
            usbmux: USBMuxClient(socketPath: mux.socketPath), secrets: hostSecrets, sink: mac,
            display: DisplayLayoutProvider(source: displays, streamedDisplayID: { nil }, cursor: { mac.cursorLocation() }),
            power: power, settings: { M3EndToEndTests.settings },
            video: {
                let capture = FakeFrameSource()
                let pipeline = HostVideoPipeline(display: displays.makeLain(), frameSource: capture, cursorSource: FakeCursor())
                sessions.put(SessionVideo(pipeline: pipeline, capture: capture))
                return pipeline
            },
            identity: Self.identity, wifi: HostWiFiConfig(options: .loopback, advertise: false))
        let host = HostSession(dependencies: deps) { hostStatus.put($0) }
        defer {
            host.stop()
            mux.stop()
            client.stop()
        }

        /// The client's link once its `HelloAck` is applied.
        func configured() -> ClientSession.ConnectionInfo? {
            if case .connected(let info) = clientStatus.last, info.isConfigured { info } else { nil }
        }
        func releases() -> Int { mac.calls.count { $0 == .releaseAll } }
        /// The video of the session that runs now, not one of `earlier` (a pipeline made for a link that
        /// was then turned away never starts).
        func runningVideo(besides earlier: [SessionVideo]) async -> SessionVideo? {
            await poll(within: 15) {
                sessions.all.last { s in s.pipeline.isRunning && !earlier.contains { $0.pipeline === s.pipeline } }
            }
        }

        host.start()
        #expect(await eventually { host.wifiPort != nil })
        let port = try #require(host.wifiPort)
        #expect(host.wifiStatus == .advertising(name: nil, port: port, pairedCount: 1))
        beacon.show([DiscoveredHost(hostId: Self.identity.id, name: Self.identity.name, versions: LainProtocol.supportedVersions,
                                    endpoint: .hostPort(host: .ipv4(.loopback), port: try #require(NWEndpoint.Port(rawValue: port))),
                                    interfaceNames: ["lo0"])])

        // 1. The iPad sees its Mac on the network but holds no mac:X, only the v1 "host": it asks for the
        //    cable and dials nothing, well past the grace (a negative: there's no event to wait for).
        #expect(await eventually { clientStatus.last == .needsCable(hostName: "Test Mac") })
        try await Task.sleep(for: .seconds(wifi.grace * 4))
        #expect(dials.value == 0 && !host.hasWiFiLink)
        #expect(clientStatus.last == .needsCable(hostName: "Test Mac"))
        #expect(!clientStatus.all.contains { if case .connecting = $0 { true } else { false } })
        #expect(clientSecrets.inner.secret(for: macAccount) == nil)

        // 2. Cable in: the Mac dials over USB and authenticates as "host"; its HelloAck names X, so the
        //    iPad records the same secret as mac:X (the Mac's store is untouched: no re-pairing).
        mux.attach(.init(deviceID: 7, serialNumber: Self.serial))
        #expect(await eventually { configured()?.transport == .usb })
        #expect(await eventually { hostStatus.last == .connected(deviceModel: "iPad16,6", via: .usb) })
        #expect(clientSecrets.inner.secret(for: macAccount) == secret)
        #expect(clientSecrets.inner.secret(for: PairingAccounts.usbHost) == secret)
        #expect(clientSecrets.writeCount == 1 && hostSecrets.writeCount == 0)
        #expect(configured()?.hostName == "Test Mac")
        // The keys the listener re-read at the link-up are the same: still one listener, on the same port.
        #expect(host.wifiPort == port && host.wifiListenerStarts == 1)
        let usb1 = try #require(await runningVideo(besides: []))
        try await usb1.capture.feed(frames.captured, count: 12)
        #expect(await eventually { video.stats().framesDecoded >= 3 })
        #expect(power.holding && power.begins == 1)
        #expect(dials.value == 0)   // no browsing while USB is current

        // 3. Unplugged: the USB session ends (one release, the assertion dropped, its display removed) and,
        //    after the grace, the iPad dials the Mac it just recorded: the session runs over Wi-Fi.
        let unplugged = clientStatus.all.count, hostMark = hostStatus.all.count
        mux.detach(deviceID: 7)
        #expect(await eventually { releases() == 1 && power.ends == 1 && displays.removed == 1 })
        // The Mac's own mouse moves meanwhile: only the Wi-Fi session's first warp can bring it to the iPad.
        mac.setCursor(global: CGPoint(x: 400, y: 1300))
        #expect(await eventually { configured()?.transport == Self.lo0 })
        #expect(await eventually { hostStatus.last == .connected(deviceModel: "iPad16,6", via: Self.lo0) })
        #expect(host.status.title == "Connected to iPad16,6 over Wi-Fi (LAN, lo0)")
        #expect(hostStatus.all.dropFirst(hostMark).contains(.waitingForIPad))
        #expect(clientStatus.all.dropFirst(unplugged).contains(.connecting(hostName: "Test Mac", interfaces: ["lo0"])))
        #expect(dials.value == 1 && host.hasWiFiLink)
        let wifiInfo = try #require(configured())
        #expect(wifiInfo.hostName == "Test Mac" && wifiInfo.chroma == .yuv444)
        #expect(wifiInfo.displayPointWidth == 688 && wifiInfo.displayPointHeight == 516)
        #expect(clientSecrets.writeCount == 1)   // a Wi-Fi HelloAck writes nothing (D13)
        #expect(power.holding && power.begins == 2 && power.ends == 1)

        //    Video over Wi-Fi: a fresh stream (VideoConfig, then a keyframe: nothing to recover), decoded
        //    4:4:4 in hardware; the last frame, once refined, rendered offscreen, matches its source.
        let wifi1 = try #require(await runningVideo(besides: [usb1]))
        #expect(wifi1.pipeline.chroma == .yuv444)
        try await wifi1.capture.feed(frames.captured, count: 60)
        #expect(await eventually { video.stats().framesDecoded >= 10 })
        // Idle refinement re-encodes the last frame 150 and 300 ms after it; every frame is acked, and
        // the client has decoded everything sent.
        #expect(await eventually {
            let s = wifi1.pipeline.stats
            return s.refinements >= 2 && s.inFlight == 0
        })
        let hostStats = wifi1.pipeline.stats
        #expect(await eventually {
            let v = video.stats()
            return v.framesReceived == hostStats.sent && v.framesDecoded == hostStats.sent
        })
        let clientStats = video.stats()
        #expect(clientStats.keyframeRequests == 0 && clientStats.sequenceGaps == 0 && clientStats.decodeErrors == 0)
        #expect(clientStats.framesDropped == 0 && clientStats.chroma == .yuv444)
        #expect(hostStats.peakInFlight <= 2 && hostStats.keyframes >= 1 && hostStats.encodeFailures == 0)
        #expect(decoders.all.count == 2 && decoders.all.last?.chroma == .yuv444 && decoders.all.last?.idc == 3)
        var newest: DecodedFrame?
        while let f = video.latest.take() { newest = f }
        let frame = try #require(newest)
        #expect(CVPixelBufferGetPixelFormatType(frame.image) == ChromaFormat.yuv444.pixelFormat)
        let renderer = try VideoRenderer(pixelFormat: .bgra8Unorm)
        let rendered = VideoRenderer.readBGRA8(try #require(renderer.renderOffscreen(
            VideoRenderer.Scene(frame: frame), width: M3EndToEndTests.pixelWidth, height: M3EndToEndTests.pixelHeight)))
        let psnr = bgraPSNR(rendered, frames.bgra[(60 - 1) % frames.bgra.count])
        print(String(format: "Wi-Fi e2e 4:4:4 over lo0: PSNR B %.1f G %.1f R %.1f dB; %d sent, peak in flight %d, dropped before encode %d",
                     psnr[0], psnr[1], psnr[2], hostStats.sent, hostStats.peakInFlight, hostStats.droppedBeforeEncode))
        #expect(psnr.allSatisfy { $0 >= 35 })

        //    Input over Wi-Fi: the session's first warp brought the Mac's cursor to the iPad; a move lands
        //    at the right global point, keys follow in order.
        #expect(await eventually {
            let c = client.input.cursor
            return c.globalX == 400 && c.globalY == 1300 && c.onStream
        })
        let inputMark = mac.inputCalls.count
        client.input.setCurve(AccelerationCurve(sensitivity: 1, acceleration: 0))
        client.input.mouseMoved(dx: 10, dy: 0)
        client.input.keyChanged(InputLoopbackTests.keyB, isDown: true)
        client.input.keyChanged(InputLoopbackTests.keyB, isDown: false)
        #expect(await eventually { mac.inputCalls.count >= inputMark + 3 })
        #expect(Array(mac.inputCalls.dropFirst(inputMark)) == [
            .move(PointerMove(x: 410, y: 1300, dx: 10, dy: 0, buttons: 0)),
            .key(KeyEvent(usage: 0x05, isDown: true, modifiers: [])),
            .key(KeyEvent(usage: 0x05, isDown: false, modifiers: [])),
        ])

        // 4. Replugged: USB wins. The iPad adopts the USB link and closes the Wi-Fi one, going straight
        //    from one session to the other; the Mac finishes the Wi-Fi session (its one release) before
        //    setting up the USB one; the assertion ends up held; one lain display at a time.
        let replugged = clientStatus.all.count, callsMark = mac.calls.count, dialsBefore = dials.value
        mux.attach(.init(deviceID: 7, serialNumber: Self.serial))
        #expect(await eventually { configured()?.transport == .usb })
        #expect(await eventually { hostStatus.last == .connected(deviceModel: "iPad16,6", via: .usb) })
        #expect(await eventually { !host.hasWiFiLink && power.ends == 2 })
        #expect(Array(mac.calls.dropFirst(callsMark)).prefix(2) == [.releaseAll, .keyboardType(.ansi)])
        #expect(releases() == 2)
        #expect(power.holding && power.begins == 3)
        #expect(clientStatus.all.dropFirst(replugged).allSatisfy { if case .connected = $0 { true } else { false } })
        let usb2 = try #require(await runningVideo(besides: [usb1, wifi1]))
        try await usb2.capture.feed(frames.captured, count: 12)
        #expect(await eventually { video.stats().framesDecoded >= 3 })
        #expect(decoders.all.count == 3)
        #expect(displays.created == 3 && displays.removed == 2 && displays.peak == 1)
        // No Wi-Fi dial while USB is current; nothing released twice.
        #expect(dials.value == dialsBefore && releases() == 2)
        // The USB HelloAck records mac:X again (same secret); the Mac's store still untouched.
        #expect(clientSecrets.writeCount == 2 && hostSecrets.writeCount == 0)
        #expect(clientSecrets.inner.secret(for: macAccount) == secret)

        // 5. Unplugged for good: the USB session ends (its release, its display removed, the assertion
        //    dropped), and the iPad falls back to Wi-Fi with the secret it recorded.
        let lastMark = hostStatus.all.count
        mux.detach(deviceID: 7)
        #expect(await eventually { releases() == 3 && power.ends == 3 && displays.removed == 3 })
        #expect(await eventually { configured()?.transport == Self.lo0 })
        #expect(await eventually { hostStatus.last == .connected(deviceModel: "iPad16,6", via: Self.lo0) })
        #expect(hostStatus.all.dropFirst(lastMark).contains(.waitingForIPad))
        #expect(dials.value == dialsBefore + 1)
        #expect(power.holding && power.begins == 4)
        #expect(clientSecrets.writeCount == 2 && hostSecrets.writeCount == 0)

        //    Stopping the Mac releases everything before it returns; the last lain display goes, and the
        //    iPad sees the session end.
        host.stop()
        #expect(releases() == 4 && mac.calls.last == .releaseAll)
        #expect(!power.holding && power.begins == 4 && power.ends == 4)
        #expect(host.wifiStatus == .off("stopped") && !host.hasWiFiLink)
        #expect(await eventually { displays.live == 0 })
        #expect(displays.created == 4 && displays.removed == 4 && displays.peak == 1)
        #expect(await eventually { configured() == nil })
    }
}

/// Polls `condition` until it holds or `seconds` pass (generous: other suites run alongside, and
/// ThreadSanitizer slows everything down).
private func eventually(within seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1e9)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
#endif
