#if os(macOS)
import CoreGraphics
import CoreVideo
import LainProtocol
import LainTestSupport
import LainTransport
import LainUSBMux
import Network
import Synchronization
import Testing
@testable import LainHostCore
@testable import LainTransport

/// HostSession over Wi-Fi (§7.7 D29): the iPad's Wi-Fi side is `LinkDialer` over a loopback
/// `WiFiLinkDialer` holding one pairing's PSK; its USB side, where a test needs one, is a
/// `ClientLinkListener` behind the fake usbmuxd. Loopback only: never advertised, nothing browses.
@Suite(.serialized) struct HostSessionWiFiTests {
    static let identity = HostIdentity(id: "0C3F8A52-6E1B-4D57-9A0E-2B7C4F1D8E36", name: "Test Mac")
    static let serial = "IPAD-7"
    /// The iPad over Wi-Fi says ANSI, over USB (`HostSessionTests.hello`) ISO, so the sink shows which
    /// session set it up.
    static let wifiHello = Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                                 decodeCapabilities: [.hevcMain, .hevcMain44410Hardware], keyboardType: .ansi)

    /// The host's secrets in memory, counting writes (Wi-Fi never pairs) and listings; the first
    /// `failingLists` listings throw, as the Keychain can.
    final class CountingStore: SecretStore {
        struct Unreadable: Error {}
        let inner: InMemorySecretStore
        private let writes = Atomic<Int>(0)
        private let lists = Atomic<Int>(0)
        private let failingLists: Int
        init(_ initial: [String: [UInt8]], failingLists: Int = 0) {
            inner = InMemorySecretStore(initial)
            self.failingLists = failingLists
        }
        var writeCount: Int { writes.load(ordering: .relaxed) }
        var listCount: Int { lists.load(ordering: .relaxed) }
        func secret(for peer: String) throws -> [UInt8]? { inner.secret(for: peer) }
        func setSecret(_ secret: [UInt8], for peer: String) throws {
            writes.add(1, ordering: .relaxed)
            inner.setSecret(secret, for: peer)
        }
        func removeSecret(for peer: String) throws { inner.removeSecret(for: peer) }
        func allSecrets() throws -> [String: [UInt8]] {
            guard lists.add(1, ordering: .relaxed).newValue > failingLists else { throw Unreadable() }
            return inner.allSecrets()
        }
    }

    /// The iPad's USB side: its loopback listener (pairing accepted) with its own store; sends `Hello`
    /// on every link.
    final class USBIPad: Sendable {
        let secrets: InMemorySecretStore
        let links = Inbox<Link>()
        let received = Inbox<Message>()
        let listener: ClientLinkListener

        init(secrets stored: [String: [UInt8]]) throws {
            let secrets = InMemorySecretStore(stored), links = links, received = received
            self.secrets = secrets
            listener = try ClientLinkListener(port: 0, secrets: secrets, acceptsPairing: true) { link in
                link.realtime.setHandler { env in received.put(env.message) }
                link.video.setHandler { _ in }
                link.audio.setHandler { _ in }
                link.realtime.send(.hello(HostSessionTests.hello))
                links.put(link)
            }
        }
    }

    /// The iPad over Wi-Fi: one link attempt under a pairing's secret (its PSK for TLS, its key for the
    /// `ChannelHello` HMACs), then `Hello`; keeps the host's reply and records what follows.
    final class WiFiIPad: Sendable {
        let link: Link
        /// `HelloAck`, or `Error(busy)`.
        let reply: Message
        let received = Inbox<Message>()
        let closed = Inbox<Bool>()

        static func dialer(port: UInt16, secret: [UInt8]) -> LinkDialer {
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            return LinkDialer(dialer: WiFiLinkDialer(endpoint: endpoint, psk: WiFiPSK(secret: secret), options: .loopback),
                              label: "test.ipad.wifi")
        }

        static func connect(port: UInt16, secret: [UInt8], hello: Hello = HostSessionWiFiTests.wifiHello) async throws -> WiFiIPad {
            let link = try await dialer(port: port, secret: secret).open(secret: secret)
            link.realtime.send(.hello(hello))
            do {
                return WiFiIPad(link: link, reply: try await LinkDialer.reply(on: link, timeoutSeconds: 5).message)
            } catch {
                link.close()
                throw error
            }
        }

        private init(link: Link, reply: Message) {
            self.link = link
            self.reply = reply
            link.realtime.setHandler { [received] env in received.put(env.message) }
            link.realtime.setCloseHandler { [closed] _ in closed.put(true) }
        }

        var helloAck: HelloAck? { if case .helloAck(let ack) = reply { ack } else { nil } }
    }

    final class Rig: Sendable {
        let secrets: CountingStore
        let usb: USBIPad
        let mux: FakeUSBMuxd
        let sink = RecordingSink()
        let power = RecordingPower()
        let statuses = Inbox<HostStatus>()
        let session: HostSession

        static var wifi: HostWiFiConfig { HostWiFiConfig(options: .loopback, advertise: false) }

        /// Starts the session. `stored`: the host's pairings (iPad serial → secret); `usb`: the iPad's.
        init(stored: [String: [UInt8]], usb: [String: [UInt8]] = [:], devices: [FakeUSBMuxd.Device] = [],
             wifi: HostWiFiConfig = Rig.wifi, tuning: HostSession.Tuning = .init(), failingLists: Int = 0,
             video: (@Sendable () -> HostVideoPipeline)? = nil) throws {
            secrets = CountingStore(stored, failingLists: failingLists)
            self.usb = try USBIPad(secrets: usb)
            mux = try FakeUSBMuxd(devices: devices, targetPort: self.usb.listener.port)
            let deps = HostSession.Dependencies(
                usbmux: USBMuxClient(socketPath: mux.socketPath), secrets: secrets, sink: sink,
                display: FakeDisplay(display: HostSessionTests.display, cursor: nil), power: power,
                settings: { HostSessionTests.settings }, video: video, identity: HostSessionWiFiTests.identity, wifi: wifi)
            let statuses = statuses
            session = HostSession(dependencies: deps, tuning: tuning) { statuses.put($0) }
            session.start()
        }

        func tearDown() {
            session.stop()
            mux.stop()
            usb.listener.cancel()
        }

        /// The Wi-Fi listener's port, once it listens.
        func listening(within seconds: Double = 5) async -> UInt16? {
            guard await eventually(within: seconds, { session.wifiPort != nil }) else { return nil }
            return session.wifiPort
        }

        /// Waits for `status`, skipping the ones before it.
        func reaches(_ status: HostStatus, within seconds: Double = 5) async -> Bool {
            await statuses.first(within: seconds) { $0 == status } != nil
        }
    }

    static func wifiTransport(_ ipad: WiFiIPad) -> LinkTransport { ipad.link.transport }

    // MARK: A session over Wi-Fi

    @Test func aWiFiSessionRunsLikeAUSBOne() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        #expect(rig.session.wifiStatus == .advertising(name: nil, port: port, pairedCount: 1))

        let ipad = try await WiFiIPad.connect(port: port, secret: secret)
        defer { ipad.link.close() }
        // HelloAck names this Mac, over Wi-Fi as over USB.
        let ack = try #require(ipad.helloAck)
        #expect(ack == HelloAck.host(display: HostSessionTests.display, settings: HostSessionTests.settings,
                                     hostId: Self.identity.id, hostName: Self.identity.name))
        // The layout follows it.
        #expect(await ipad.received.next() == .displayLayout(FakeDisplay(display: HostSessionTests.display, cursor: nil).desktopLayout()))
        let via = ipad.link.transport
        guard case .network(let interface?, peerToPeer: false) = via else {
            Issue.record("expected a loopback network path, got \(via)")
            return
        }
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6", via: via)))
        #expect(rig.session.status.title == "Connected to iPad16,6 over Wi-Fi (LAN, \(interface))")
        #expect(rig.power.holding)
        #expect(rig.sink.calls == [.keyboardType(.ansi)])

        // Input is injected; pings are answered.
        let down = KeyEvent(usage: 0x04, isDown: true, modifiers: [])
        ipad.link.realtime.send(.keyEvent(down))
        #expect(await eventually { rig.sink.inputCalls == [.key(down)] })
        ipad.link.realtime.send(.ping(Ping(id: 5, sentAtNs: 77)))
        #expect(await ipad.received.first { if case .pong(let p) = $0 { p.id == 5 && p.pingSentAtNs == 77 } else { false } } != nil)

        // The iPad goes away: everything is released once, the assertion dropped.
        ipad.link.close()
        #expect(await eventually { rig.sink.inputCalls.last == .releaseAll })
        #expect(await eventually { !rig.power.holding })
        #expect(await rig.reaches(.waitingForIPad))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.sink.inputCalls == [.key(down), .releaseAll])
        #expect(rig.power.begins == 1 && rig.power.ends == 1)
        #expect(rig.secrets.writeCount == 0)   // Wi-Fi never pairs (D13)
    }

    // MARK: USB wins

    @Test func usbTakesOverFromALiveWiFiSession() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        let ipad = try await WiFiIPad.connect(port: port, secret: secret)
        defer { ipad.link.close() }
        #expect(ipad.helloAck != nil)
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6", via: ipad.link.transport)))
        let down = KeyEvent(usage: 0x04, isDown: true, modifiers: [])
        ipad.link.realtime.send(.keyEvent(down))
        #expect(await eventually { rig.sink.inputCalls == [.key(down)] })

        // The cable goes in: the same iPad over USB takes the session.
        rig.mux.attach(.init(deviceID: 7, serialNumber: Self.serial))
        let usb = try #require(await rig.usb.links.next(within: 5))
        defer { usb.close() }
        let usbAck = await rig.usb.received.first { if case .helloAck = $0 { true } else { false } }
        guard case .helloAck(let ack) = try #require(usbAck) else { return }
        #expect(ack.hostId == Self.identity.id && ack.hostName == Self.identity.name)
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6")))   // via USB
        #expect(await ipad.closed.next() == true)
        // Exactly one release, before the USB session's setup; the assertion never lapsed (the USB session
        // began before the Wi-Fi one ended: never released, held throughout).
        #expect(rig.sink.calls == [.keyboardType(.ansi), .key(down), .releaseAll, .keyboardType(.iso)])
        #expect(rig.power.begins == 2 && rig.power.ends == 1 && rig.power.holding)
        #expect(rig.power.creates == 1 && rig.power.releases == 0)
        #expect(rig.session.status == .connected(deviceModel: "iPad16,6", via: .usb))
        #expect(rig.session.status.title == "Connected to iPad16,6 over USB")
    }

    @Test func aWiFiLinkWhileUSBIsLiveIsBusy() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret],
                          devices: [.init(deviceID: 7, serialNumber: Self.serial)])
        defer { rig.tearDown() }
        let usb = try #require(await rig.usb.links.next(within: 5))
        defer { usb.close() }
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6")))
        let port = try #require(await rig.listening())

        let ipad = try await WiFiIPad.connect(port: port, secret: secret)
        defer { ipad.link.close() }
        #expect(ipad.reply == .error(ErrorMessage(code: .busy, message: "a USB session is live")))
        #expect(await ipad.closed.next(within: 3) == true)   // after a short drain
        // The USB session never noticed.
        #expect(rig.session.status == .connected(deviceModel: "iPad16,6"))
        #expect(!rig.sink.inputCalls.contains(.releaseAll))
        #expect(rig.power.begins == 1 && rig.power.holding)
    }

    @Test func theSameIPadAttachedOverUSBIsPreferredForAWhile() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var wifi = Rig.wifi
        wifi.usbPreference = .milliseconds(1500)
        // The iPad is on the cable, but lain doesn't answer there: its USB dials keep failing.
        let rig = try Rig(stored: [Self.serial: secret], devices: [.init(deviceID: 7, serialNumber: Self.serial, acceptsConnect: false)],
                          wifi: wifi)
        defer { rig.tearDown() }
        let start = ContinuousClock.now
        let port = try #require(await rig.listening())
        #expect(await eventually { rig.session.usbDeviceDialed == 7 })
        let dialed = ContinuousClock.now   // the window began between `start` and now (the attach)

        let early = try await WiFiIPad.connect(port: port, secret: secret)
        defer { early.link.close() }
        #expect(ContinuousClock.now - start < .milliseconds(1200))
        #expect(early.reply == .error(ErrorMessage(code: .busy, message: "this iPad is on USB")))
        #expect(await early.closed.next(within: 3) == true)

        // Once USB has had its chance, Wi-Fi is let in.
        try await Task.sleep(until: dialed + .milliseconds(1700), clock: .continuous)
        let late = try await WiFiIPad.connect(port: port, secret: secret)
        defer { late.link.close() }
        #expect(late.helloAck != nil)
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6", via: late.link.transport)))
    }

    @Test func theWindowRestartsWhenTheIPadsUSBSessionEnds() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var wifi = Rig.wifi
        wifi.usbPreference = .milliseconds(1500)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret],
                          devices: [.init(deviceID: 7, serialNumber: Self.serial)], wifi: wifi)
        defer { rig.tearDown() }
        let usb = try #require(await rig.usb.links.next(within: 5))
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6")))
        let port = try #require(await rig.listening())
        try await Task.sleep(for: .milliseconds(1700))   // long past the attach

        // lain on the iPad stops answering over USB (the session ends, redials fail) and dials over Wi-Fi at
        // once: USB just had a session, so it gets its window again.
        rig.usb.listener.cancel()
        usb.close()
        #expect(await rig.reaches(.connecting))
        let ended = ContinuousClock.now
        let early = try await WiFiIPad.connect(port: port, secret: secret)
        defer { early.link.close() }
        #expect(ContinuousClock.now - ended < .milliseconds(1200))
        #expect(early.reply == .error(ErrorMessage(code: .busy, message: "this iPad is on USB")))

        try await Task.sleep(until: ended + .milliseconds(1700), clock: .continuous)
        let late = try await WiFiIPad.connect(port: port, secret: secret)
        defer { late.link.close() }
        #expect(late.helloAck != nil)
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6", via: late.link.transport)))
    }

    /// The case the window exists for: the iPad is plugged in behind a device without lain (an iPhone
    /// charging), whose fast retries take about 2 s. The iPad's window counts from its attach, so it dials
    /// over Wi-Fi in vain meanwhile, and its session comes up over USB with no Wi-Fi session in between.
    @Test func anIPadWaitingBehindAnotherDeviceIsKeptForUSB() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret],
                          devices: [.init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false),
                                    .init(deviceID: 7, serialNumber: Self.serial)])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        #expect(await eventually { rig.session.usbDeviceDialed == 3 })

        let wifi = try await WiFiIPad.connect(port: port, secret: secret)
        defer { wifi.link.close() }
        #expect(wifi.reply == .error(ErrorMessage(code: .busy, message: "this iPad is on USB")))
        #expect(rig.session.usbDeviceDialed == 3)   // still waiting its turn: the window came from its attach

        let usb = try #require(await rig.usb.links.next(within: 5))
        defer { usb.close() }
        #expect(await rig.usb.received.first { if case .helloAck = $0 { true } else { false } } != nil)
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6")))
        #expect(rig.sink.calls == [.keyboardType(.iso)])   // no Wi-Fi session ever started
        #expect(rig.power.begins == 1)
    }

    /// The window restarts at the waiting iPad's first dial: however long the device ahead of it took,
    /// USB gets its full window once it is the iPad's turn.
    @Test func theWindowRestartsWhenAWaitingIPadIsFirstDialed() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var wifi = Rig.wifi
        wifi.usbPreference = .milliseconds(1500)
        var tuning = HostSession.Tuning()
        tuning.fastRetries = 25   // the iPhone's turn: 25 × 100 ms, well past the window from the attach
        let rig = try Rig(stored: [Self.serial: secret],
                          devices: [.init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false),
                                    .init(deviceID: 7, serialNumber: Self.serial, acceptsConnect: false)],
                          wifi: wifi, tuning: tuning)
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        #expect(await eventually { rig.session.usbDeviceDialed == 3 })
        let attached = ContinuousClock.now   // usbmuxd reported both devices together
        #expect(await eventually { rig.session.usbDeviceDialed == 7 })
        #expect(ContinuousClock.now - attached > .milliseconds(1500))   // the window from the attach is over

        let ipad = try await WiFiIPad.connect(port: port, secret: secret)
        defer { ipad.link.close() }
        #expect(ipad.reply == .error(ErrorMessage(code: .busy, message: "this iPad is on USB")))
    }

    /// Two devices failing over USB take turns, but hand-overs back to the iPad don't restart its window:
    /// Wi-Fi gets in once the window from its first dial is over, instead of being busy for good.
    @Test func handOversBetweenFailingDevicesDontKeepWiFiBusy() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var wifi = Rig.wifi
        wifi.usbPreference = .milliseconds(1500)
        var tuning = HostSession.Tuning()
        tuning.fastRetries = 5   // a hand-over about every 0.5 s: the iPad is dialed again about every second
        let rig = try Rig(stored: [Self.serial: secret],
                          devices: [.init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false),
                                    .init(deviceID: 7, serialNumber: Self.serial, acceptsConnect: false)],
                          wifi: wifi, tuning: tuning)
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        #expect(await eventually { rig.session.usbDeviceDialed == 7 })
        let firstDial = ContinuousClock.now   // its window began just before
        let early = try await WiFiIPad.connect(port: port, secret: secret)
        defer { early.link.close() }
        #expect(early.reply == .error(ErrorMessage(code: .busy, message: "this iPad is on USB")))

        // The iPhone's turn, then the iPad's again...
        #expect(await eventually { rig.session.usbDeviceDialed == 3 })
        #expect(await eventually { rig.session.usbDeviceDialed == 7 })
        // ...and the window from its first dial runs out all the same.
        try await Task.sleep(until: firstDial + .milliseconds(1700), clock: .continuous)
        let late = try await WiFiIPad.connect(port: port, secret: secret)
        defer { late.link.close() }
        #expect(late.helloAck != nil)
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6", via: late.link.transport)))
    }

    // MARK: Wi-Fi over Wi-Fi

    @Test func aNewWiFiLinkFromTheSameIPadReplacesItsSession() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        let first = try await WiFiIPad.connect(port: port, secret: secret)
        defer { first.link.close() }
        #expect(first.helloAck != nil)
        let down = KeyEvent(usage: 0x04, isDown: true, modifiers: [])
        first.link.realtime.send(.keyEvent(down))
        #expect(await eventually { rig.sink.inputCalls == [.key(down)] })

        // The iPad redials (it thinks the first link is gone): the new link takes over.
        let second = try await WiFiIPad.connect(port: port, secret: secret, hello: HostSessionTests.hello)
        defer { second.link.close() }
        #expect(second.helloAck != nil)
        #expect(await first.closed.next() == true)
        #expect(rig.sink.calls == [.keyboardType(.ansi), .key(down), .releaseAll, .keyboardType(.iso)])
        // The assertion never lapsed: the new session began before the old one ended.
        #expect(rig.power.begins == 2 && rig.power.ends == 1 && rig.power.holding)
        #expect(rig.power.creates == 1 && rig.power.releases == 0)
        let up = KeyEvent(usage: 0x04, isDown: false, modifiers: [])
        second.link.realtime.send(.keyEvent(up))
        #expect(await eventually { rig.sink.inputCalls.last == .key(up) })
        #expect(rig.session.status == .connected(deviceModel: "iPad16,6", via: second.link.transport))
    }

    @Test func anotherIPadOverWiFiIsBusy() async throws {
        let one = ChannelAuth.randomBytes(32), two = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: one, "IPAD-8": two])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        #expect(await eventually { rig.session.wifiStatus == .advertising(name: nil, port: port, pairedCount: 2) })
        let first = try await WiFiIPad.connect(port: port, secret: one)
        defer { first.link.close() }
        #expect(first.helloAck != nil)
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6", via: first.link.transport)))

        let second = try await WiFiIPad.connect(port: port, secret: two)
        defer { second.link.close() }
        #expect(second.reply == .error(ErrorMessage(code: .busy, message: "another iPad is connected")))
        #expect(await second.closed.next(within: 3) == true)
        // The first goes on untouched.
        let down = KeyEvent(usage: 0x04, isDown: true, modifiers: [])
        first.link.realtime.send(.keyEvent(down))
        #expect(await eventually { rig.sink.inputCalls == [.key(down)] })
        #expect(await first.closed.next(within: 0.2) == nil)
        #expect(rig.power.begins == 1 && rig.power.holding)
    }

    // MARK: Other USB devices

    @Test func anIPhoneComingAndGoingLeavesTheWiFiSessionUp() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        let ipad = try await WiFiIPad.connect(port: port, secret: secret)
        defer { ipad.link.close() }
        let wifi = HostStatus.connected(deviceModel: "iPad16,6", via: ipad.link.transport)
        #expect(await rig.reaches(wifi))

        // An iPhone is plugged in to charge (no lain on it), then unplugged.
        rig.mux.attach(.init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false))
        #expect(await eventually { rig.session.usbDeviceDialed == 3 })
        try await Task.sleep(for: .milliseconds(250))   // several failed dials
        #expect(rig.session.status == wifi)
        rig.mux.detach(deviceID: 3)
        #expect(await eventually { rig.session.usbDeviceDialed == nil })
        try await Task.sleep(for: .milliseconds(100))

        // Nothing ended, nothing was released, and the status never left the Wi-Fi session.
        #expect(rig.session.status == wifi)
        #expect(await rig.statuses.next(within: 0.1) == nil)
        #expect(await ipad.closed.next(within: 0.1) == nil)
        #expect(!rig.sink.inputCalls.contains(.releaseAll))
        #expect(rig.power.holding && rig.power.ends == 0)
        let down = KeyEvent(usage: 0x04, isDown: true, modifiers: [])
        ipad.link.realtime.send(.keyEvent(down))
        #expect(await eventually { rig.sink.inputCalls == [.key(down)] })
    }

    /// Nothing reached the live Wi-Fi session: the same status with nothing new published, its link
    /// open, nothing released, the assertion held throughout, and input still flowing.
    static func expectUntouched(_ rig: Rig, _ ipad: WiFiIPad, _ status: HostStatus,
                                sourceLocation: SourceLocation = #_sourceLocation) async {
        #expect(rig.session.status == status, sourceLocation: sourceLocation)
        #expect(await rig.statuses.next(within: 0.1) == nil, sourceLocation: sourceLocation)
        #expect(await ipad.closed.next(within: 0.1) == nil, sourceLocation: sourceLocation)
        #expect(!rig.sink.inputCalls.contains(.releaseAll), sourceLocation: sourceLocation)
        #expect(rig.power.holding && rig.power.ends == 0 && rig.power.releases == 0, sourceLocation: sourceLocation)
        let down = KeyEvent(usage: 0x04, isDown: true, modifiers: [])
        ipad.link.realtime.send(.keyEvent(down))
        #expect(await eventually { rig.sink.inputCalls == [.key(down)] }, sourceLocation: sourceLocation)
    }

    @Test func anIPhoneReattachingLeavesTheWiFiSessionUp() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        let ipad = try await WiFiIPad.connect(port: port, secret: secret)
        defer { ipad.link.close() }
        let wifi = HostStatus.connected(deviceModel: "iPad16,6", via: ipad.link.transport)
        #expect(await rig.reaches(wifi))
        rig.mux.attach(.init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false))
        #expect(await eventually { rig.session.usbDeviceDialed == 3 })
        let loop = rig.session.usbConnectLoop

        // usbmuxd reports the iPhone attached again (it re-enumerated): its connect loop starts over, and
        // only a session of that loop's would end.
        rig.mux.attach(.init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false))
        #expect(await eventually { rig.session.usbConnectLoop != loop && rig.session.usbDeviceDialed == 3 })
        try await Task.sleep(for: .milliseconds(100))
        await Self.expectUntouched(rig, ipad, wifi)
    }

    @Test func aUSBMuxdRestartLeavesTheWiFiSessionUp() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var tuning = HostSession.Tuning()
        tuning.usbmuxRetryInterval = .milliseconds(100)
        let rig = try Rig(stored: [Self.serial: secret], tuning: tuning)
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        let ipad = try await WiFiIPad.connect(port: port, secret: secret)
        defer { ipad.link.close() }
        let wifi = HostStatus.connected(deviceModel: "iPad16,6", via: ipad.link.transport)
        #expect(await rig.reaches(wifi))
        rig.mux.attach(.init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false))
        #expect(await eventually { rig.session.usbDeviceDialed == 3 })
        let loop = rig.session.usbConnectLoop

        // usbmuxd restarts: the host forgets its devices (ending their loops) and listens again, and the
        // iPhone is reported afresh.
        rig.mux.restart()
        #expect(await eventually { rig.session.usbConnectLoop != loop && rig.session.usbDeviceDialed == 3 })
        try await Task.sleep(for: .milliseconds(100))
        await Self.expectUntouched(rig, ipad, wifi)
    }

    // MARK: Another protocol

    /// A v1 app can't speak v2 at all: its first frame, framed in v1, is refused by the Wi-Fi acceptor
    /// (answered in v1), and the owner is told to update the iPad, as over USB.
    @Test func aWiFiPeerFramingAnotherProtocolIsAskedToUpdate() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)))
        let stream = try await NetworkStreamDialer(endpoint: endpoint, psk: WiFiPSK(secret: secret), options: .loopback)
            .connect(kind: .realtime)
        defer { stream.close() }
        let hello = ChannelAuth.hello(kind: .realtime, token: ChannelAuth.randomBytes(ChannelHello.tokenSize), secret: secret)
        stream.write(MessageCodec.encode(.channelHello(hello), sequence: 0, timestampNs: 0, version: 1))
        #expect(await rig.reaches(HostStatus.iPadNeedsUpdate))
        #expect(rig.session.status.title == "Error: lain on the iPad speaks another protocol: update it")
        #expect(!rig.session.hasWiFiLink && rig.power.begins == 0 && rig.sink.calls.isEmpty)
    }

    /// A link whose `Hello` says another protocol version is answered `Error(versionMismatch)` and closed,
    /// and the owner told to update the iPad.
    @Test func aWiFiHelloInAnotherProtocolIsAskedToUpdate() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        var hello = Self.wifiHello
        hello.protocolVersion = LainProtocol.majorVersion + 1
        await #expect(throws: TransportError.versionMismatch(remote: 0)) {
            _ = try await WiFiIPad.connect(port: port, secret: secret, hello: hello)
        }
        #expect(await rig.reaches(HostStatus.iPadNeedsUpdate))
        #expect(await eventually { !rig.session.hasWiFiLink })
        #expect(rig.power.begins == 0 && rig.sink.calls.isEmpty)
    }

    /// The same for a `Hello` framed in another version, on a link authenticated in ours.
    @Test func aWiFiHelloFramedInAnotherProtocolIsAskedToUpdate() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        let link = try await WiFiIPad.dialer(port: port, secret: secret).open(secret: secret)
        defer { link.close() }
        #expect(await eventually { rig.session.hasWiFiLink })   // delivered: the host waits for its Hello
        link.realtime.stream.write(MessageCodec.encode(.hello(Self.wifiHello), sequence: 1, timestampNs: 0,
                                                       version: LainProtocol.majorVersion + 1))
        #expect(await rig.reaches(HostStatus.iPadNeedsUpdate))
        #expect(await eventually { !rig.session.hasWiFiLink })
        #expect(rig.power.begins == 0 && rig.sink.calls.isEmpty)
    }

    // MARK: Lifecycle

    @Test func stopDuringTheHelloWaitClosesTheLink() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        // A link that never sends Hello.
        let link = try await WiFiIPad.dialer(port: port, secret: secret).open(secret: secret)
        defer { link.close() }
        let closed = Inbox<Bool>()
        link.realtime.setCloseHandler { _ in closed.put(true) }
        #expect(await eventually { rig.session.hasWiFiLink })

        let stopped = ContinuousClock.now
        rig.session.stop()
        #expect(await closed.next(within: 3) == true)
        #expect(ContinuousClock.now - stopped < .seconds(2))   // closed by the stop, not the 5 s Hello timeout
        #expect(!rig.session.hasWiFiLink)
        #expect(rig.session.wifiStatus == .off("stopped"))
        #expect(rig.power.begins == 0 && rig.sink.calls.isEmpty)
    }

    @Test func aLinkThatNeverSaysHelloIsClosed() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var wifi = Rig.wifi
        wifi.helloTimeout = 0.3
        let rig = try Rig(stored: [Self.serial: secret], wifi: wifi)
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        let link = try await WiFiIPad.dialer(port: port, secret: secret).open(secret: secret)
        defer { link.close() }
        let closed = Inbox<Bool>()
        link.realtime.setCloseHandler { _ in closed.put(true) }
        #expect(await closed.next(within: 3) == true)
        #expect(await eventually { !rig.session.hasWiFiLink })
        #expect(rig.power.begins == 0 && rig.sink.calls.isEmpty)
        #expect(rig.session.status == .waitingForIPad)
    }

    // MARK: Keys

    @Test func anUnreadableKeychainIsRetriedWithBackoff() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var wifi = Rig.wifi
        wifi.retryInitial = .milliseconds(100)
        wifi.retryMax = .milliseconds(150)
        // The first two listings fail, as the Keychain can right after login.
        let started = ContinuousClock.now
        let rig = try Rig(stored: [Self.serial: secret], wifi: wifi, failingLists: 2)
        defer { rig.tearDown() }
        #expect(await eventually { rig.session.wifiStatus == .off("can't read the pairing secrets") })
        let port = try #require(await rig.listening())
        // Retried after 100 ms, then after 150 ms (doubled, capped): the third listing works.
        #expect(ContinuousClock.now - started >= .milliseconds(250))
        #expect(rig.secrets.listCount == 3)
        #expect(rig.session.wifiStatus == .advertising(name: nil, port: port, pairedCount: 1))
        let ipad = try await WiFiIPad.connect(port: port, secret: secret)
        defer { ipad.link.close() }
        #expect(ipad.helloAck != nil)
    }

    @Test func anAuthenticatedUSBLinkKeepsTheListener() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret])
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        #expect(rig.session.wifiListenerStarts == 1)
        rig.mux.attach(.init(deviceID: 7, serialNumber: Self.serial))
        let usb = try #require(await rig.usb.links.next(within: 5))
        defer { usb.close() }
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6")))
        // The keys were re-read at the link-up and are the same: the listener stays as it was.
        #expect(rig.secrets.listCount >= 2)
        #expect(rig.session.wifiListenerStarts == 1)
        #expect(rig.session.wifiPort == port)
        #expect(rig.secrets.writeCount == 0)
    }

    @Test func noPairedIPadMeansNoListenerUntilAUSBPairing() async throws {
        let rig = try Rig(stored: [:])
        defer { rig.tearDown() }
        #expect(await eventually { rig.session.wifiStatus == .off("no paired iPad yet") })
        #expect(rig.session.wifiPort == nil)

        // The first USB session pairs; its Pair carries the host id, so the iPad keeps the secret for Wi-Fi too.
        rig.mux.attach(.init(deviceID: 7, serialNumber: Self.serial))
        let usb = try #require(await rig.usb.links.next(within: 5))
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6")))
        let secret = try #require(rig.secrets.inner.secret(for: Self.serial))
        #expect(rig.usb.secrets.secret(for: PairingAccounts.mac(Self.identity.id)) == secret)
        let port = try #require(await rig.listening())
        #expect(rig.session.wifiStatus == .advertising(name: nil, port: port, pairedCount: 1))

        // Unplugged: the iPad comes back over Wi-Fi with that secret.
        usb.close()
        rig.mux.detach(deviceID: 7)
        #expect(await rig.reaches(.waitingForIPad))
        let ipad = try await WiFiIPad.connect(port: port, secret: secret)
        defer { ipad.link.close() }
        #expect(ipad.helloAck?.hostId == Self.identity.id)
    }

    @Test func aUSBRePairingRestartsTheListenerWithTheNewKey() async throws {
        let old = ChannelAuth.randomBytes(32)
        // The iPad lost its secret (lain reinstalled): the host re-pairs over USB.
        let rig = try Rig(stored: [Self.serial: old])
        defer { rig.tearDown() }
        #expect(await rig.listening() != nil)
        rig.mux.attach(.init(deviceID: 7, serialNumber: Self.serial))
        let usb = try #require(await rig.usb.links.next(within: 5))
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6")))
        let new = try #require(rig.secrets.inner.secret(for: Self.serial))
        #expect(new != old)
        // The keys were re-read at the link-up, before the session started: the listener restarted.
        let port = try #require(await rig.listening())
        #expect(rig.session.wifiStatus == .advertising(name: nil, port: port, pairedCount: 1))

        usb.close()
        rig.mux.detach(deviceID: 7)
        #expect(await rig.reaches(.waitingForIPad))
        // The old key is refused at TLS; the new one gets a session.
        await #expect(throws: NetworkStreamError.unknownIdentity) {
            _ = try await WiFiIPad.connect(port: port, secret: old)
        }
        let ipad = try await WiFiIPad.connect(port: port, secret: new)
        defer { ipad.link.close() }
        #expect(ipad.helloAck != nil)
    }

    /// The host's secrets in memory; the next listing can be held once it has read them, as a slow
    /// Keychain read would be.
    final class HeldListing: SecretStore {
        let inner: InMemorySecretStore
        /// Gets a value when the held listing has read the secrets.
        let entered = Inbox<Bool>()
        private let hold = Mutex(false)
        private let release = DispatchSemaphore(value: 0)
        init(_ initial: [String: [UInt8]]) { inner = InMemorySecretStore(initial) }
        func holdNextListing() { hold.withLock { $0 = true } }
        func releaseListing() { release.signal() }
        func secret(for peer: String) throws -> [UInt8]? { inner.secret(for: peer) }
        func setSecret(_ secret: [UInt8], for peer: String) throws { inner.setSecret(secret, for: peer) }
        func removeSecret(for peer: String) throws { inner.removeSecret(for: peer) }
        func allSecrets() throws -> [String: [UInt8]] {
            let read = inner.allSecrets()
            if hold.withLock({ h in defer { h = false }; return h }) {
                entered.put(true)
                release.wait()
            }
            return read
        }
    }

    /// Refreshes overlap (launch, each USB link-up, retries): a slow read of the old keys that finishes
    /// after a re-pairing's refresh must not put them back.
    @Test func aSlowKeyReadFinishingLastDoesNotPutBackTheOldKey() async throws {
        let old = ChannelAuth.randomBytes(32), new = ChannelAuth.randomBytes(32)
        let store = HeldListing([Self.serial: old])
        let listener = HostWiFiListener(config: Rig.wifi, secrets: store, identity: nil, onAccept: { $0.close() })
        defer { listener.cancel() }
        // The launch refresh reads the keys and is slow to come back...
        store.holdNextListing()
        let slow = Inbox<Bool>()
        DispatchQueue.global().async {
            listener.refresh()
            slow.put(true)
        }
        #expect(await store.entered.next() == true)
        // ...while the iPad re-pairs over USB, and the link-up's refresh reads the new key and starts listening.
        try store.setSecret(new, for: Self.serial)
        listener.refresh()
        #expect(listener.starts == 1)
        // The slow read comes back last, with the old key: dropped.
        store.releaseListing()
        #expect(await slow.next() == true)
        #expect(listener.starts == 1)
        #expect(await eventually { listener.port != nil })
        let port = try #require(listener.port)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: try #require(NWEndpoint.Port(rawValue: port)))
        func dial(_ secret: [UInt8]) async throws {
            try await NetworkStreamDialer(endpoint: endpoint, psk: WiFiPSK(secret: secret), options: .loopback)
                .connect(kind: .realtime).close()
        }
        try await dial(new)
        await #expect(throws: NetworkStreamError.unknownIdentity) { try await dial(old) }
    }

    // MARK: Capture failures

    /// A lain display and a capture that stops on its own right after starting (as SCK's
    /// didStopWithError would).
    final class FailingVideo: StreamedDisplayProvider, FrameSource {
        private let alive = Mutex(false)
        func create() async throws -> StreamedDisplay {
            alive.withLock { $0 = true }
            return StreamedDisplay(displayID: 9, pixelWidth: 640, pixelHeight: 480,
                                   bounds: CGRect(x: 0, y: 1050, width: 320, height: 240), refreshRate: 120)
        }
        func currentBounds() -> CGRect? { alive.withLock { $0 } ? CGRect(x: 0, y: 1050, width: 320, height: 240) : nil }
        func destroy() { alive.withLock { $0 = false } }
        func start(_ config: FrameSourceConfig, onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
                   onError: @escaping @Sendable (any Error) -> Void) async throws {
            struct Stopped: Error {}
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { onError(Stopped()) }
        }
        func stop() async {}

        /// One session's video, whose capture fails right after it starts.
        static func pipeline() -> HostVideoPipeline {
            let failing = FailingVideo()
            return HostVideoPipeline(display: failing, frameSource: failing, cursorSource: nil)
        }
    }

    @Test func theCaptureBackoffHoldsEveryTransport() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var tuning = HostSession.Tuning()
        tuning.captureRetryInterval = .milliseconds(1500)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret], tuning: tuning,
                          video: { FailingVideo.pipeline() })
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())

        // Capture fails right after each start, and the host ends the session. The first time, the next
        // session may start at once.
        let first = try await WiFiIPad.connect(port: port, secret: secret)
        defer { first.link.close() }
        #expect(first.helloAck != nil)
        #expect(await first.closed.next() == true)
        #expect(await eventually { !rig.session.hasWiFiLink })
        let second = try await WiFiIPad.connect(port: port, secret: secret)
        defer { second.link.close() }
        #expect(second.helloAck != nil)
        #expect(await second.closed.next() == true)
        #expect(await eventually { !rig.session.hasWiFiLink })

        // Twice in a row: nothing starts for a while, whichever transport it comes over.
        let ended = ContinuousClock.now
        let third = try await WiFiIPad.connect(port: port, secret: secret)
        defer { third.link.close() }
        #expect(third.reply == .error(ErrorMessage(code: .busy, message: "backing off after capture failures")))
        rig.mux.attach(.init(deviceID: 7, serialNumber: "IPAD-9"))
        #expect(await rig.reaches(HostStatus.captureBackingOff))   // not "open lain on the iPad"
        try await Task.sleep(until: ended + .milliseconds(1000), clock: .continuous)
        #expect(rig.mux.connectCount == 0)   // the USB loop waits too
        #expect(await eventually(within: 3) { rig.mux.connectCount > 0 })
        #expect(await rig.reaches(.connecting))   // once the backoff was over
    }

    /// Replugging the iPad whose sessions kept failing capture is the owner's reset: it is dialed at once,
    /// not after the backoff, and its count starts over.
    @Test func repluggingTheIPadStartsItsSessionsAfresh() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var tuning = HostSession.Tuning()
        tuning.captureRetryInterval = .seconds(5)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret],
                          devices: [.init(deviceID: 7, serialNumber: Self.serial)], tuning: tuning,
                          video: { FailingVideo.pipeline() })
        defer { rig.tearDown() }
        // Capture fails right after each start and the host ends the session: it redials at once the first
        // time; after the second it backs off, and the menu says so.
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(await rig.reaches(HostStatus.captureBackingOff))
        #expect(rig.session.status.title == "Error: backing off after capture failures")
        #expect(await rig.usb.links.next(within: 0.5) == nil)

        // The owner replugs the cable (usbmuxd numbers the iPad anew): it is dialed at once, and the next
        // failure redials at once again, as the first one did.
        rig.mux.detach(deviceID: 7)
        rig.mux.attach(.init(deviceID: 8, serialNumber: Self.serial))
        let replugged = ContinuousClock.now
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(ContinuousClock.now - replugged < .seconds(2))
    }

    /// The same with an iPhone charging on another port (no lain on it): unplugging the iPad hands the
    /// dialing to the iPhone, which waits the backoff out. The replugged iPad goes ahead of it: it is
    /// dialed at once, and its count starts over.
    @Test func repluggingTheIPadGoesAheadOfADeviceWaitingOutTheBackoff() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var tuning = HostSession.Tuning()
        tuning.captureRetryInterval = .seconds(5)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret],
                          devices: [.init(deviceID: 7, serialNumber: Self.serial),
                                    .init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false)],
                          tuning: tuning, video: { FailingVideo.pipeline() })
        defer { rig.tearDown() }
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(await rig.reaches(HostStatus.captureBackingOff))

        // Unplugged: the iPhone is dialed next, and it waits the backoff out.
        rig.mux.detach(deviceID: 7)
        #expect(await eventually { rig.session.usbDeviceDialed == 3 && rig.session.status == HostStatus.captureBackingOff })
        #expect(await rig.reaches(HostStatus.captureBackingOff))   // the statuses so far

        // Replugged: the iPad is dialed ahead of it at once, the menu stops saying it backs off, and the next
        // failure redials at once again.
        rig.mux.attach(.init(deviceID: 8, serialNumber: Self.serial))
        let replugged = ContinuousClock.now
        #expect(await eventually(within: 1) { rig.session.usbDeviceDialed == 8 })
        #expect(await rig.statuses.next(within: 1).map { $0 != HostStatus.captureBackingOff } == true)
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(ContinuousClock.now - replugged < .seconds(2))

        // The iPhone kept its place in line.
        rig.mux.detach(deviceID: 8)
        #expect(await eventually { rig.session.usbDeviceDialed == 3 })
    }

    /// A replug behind a device that is dialing (its backoff over) waits its turn, but it is the owner's
    /// reset all the same: once the iPad is dialed, a capture failure redials at once.
    @Test func aReplugWaitingItsTurnStillStartsTheCountOver() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var tuning = HostSession.Tuning()
        tuning.captureRetryInterval = .milliseconds(1500)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret],
                          devices: [.init(deviceID: 7, serialNumber: Self.serial),
                                    .init(deviceID: 3, serialNumber: "IPHONE-3", acceptsConnect: false)],
                          tuning: tuning, video: { FailingVideo.pipeline() })
        defer { rig.tearDown() }
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(await rig.reaches(HostStatus.captureBackingOff))

        // Unplugged: the iPhone is dialed next and, once it has waited the backoff out, dials in vain.
        rig.mux.detach(deviceID: 7)
        #expect(await eventually { rig.session.usbDeviceDialed == 3 && rig.session.status == HostStatus.captureBackingOff })
        #expect(await eventually(within: 3) { rig.session.status == .connecting })

        // Replugged: it waits until the iPhone's fast retries run out (about 2 s). Then its first failure
        // redials at once, not after twice the interval (a third failure in a row).
        rig.mux.attach(.init(deviceID: 8, serialNumber: Self.serial))
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.session.usbDeviceDialed == 3)   // a device that is dialing keeps its turn
        #expect(await rig.usb.links.next(within: 5) != nil)
        let first = ContinuousClock.now
        #expect(await rig.usb.links.next(within: 5) != nil)
        #expect(ContinuousClock.now - first < .milliseconds(1500))
    }

    // MARK: One lain display at a time

    /// The Mac's lain displays: each session's pipeline makes its own, and a destroyed one leaves the
    /// active list only `removalMs` later (as a released CGVirtualDisplay does, but slower). On a Mac they
    /// share one identity, so two must never exist at once (`peak`).
    final class SlowDisplays: Sendable {
        let removalMs: Int
        private let counts = Mutex((live: 0, peak: 0, created: 0))
        init(removalMs: Int) { self.removalMs = removalMs }
        var live: Int { counts.withLock { $0.live } }
        var peak: Int { counts.withLock { $0.peak } }
        var created: Int { counts.withLock { $0.created } }

        /// One session's video: its own lain display, and a capture that delivers nothing.
        func pipeline() -> HostVideoPipeline {
            let display = Display(displays: self)
            return HostVideoPipeline(display: display, frameSource: display, cursorSource: nil)
        }

        func added() {
            counts.withLock { c in
                c.live += 1
                c.created += 1
                c.peak = max(c.peak, c.live)
            }
        }

        func gone() { counts.withLock { $0.live -= 1 } }

        final class Display: StreamedDisplayProvider, FrameSource {
            static let bounds = CGRect(x: 0, y: 1050, width: 320, height: 240)
            let displays: SlowDisplays
            private let state = Mutex((alive: false, listed: false))
            init(displays: SlowDisplays) { self.displays = displays }

            func create() async throws -> StreamedDisplay {
                state.withLock { $0 = (true, true) }
                displays.added()
                return StreamedDisplay(displayID: 9, pixelWidth: 640, pixelHeight: 480, bounds: Self.bounds, refreshRate: 120)
            }
            func currentBounds() -> CGRect? { state.withLock { $0.alive } ? Self.bounds : nil }
            func destroy() {
                let wasAlive = state.withLock { s -> Bool in
                    defer { s.alive = false }
                    return s.alive
                }
                guard wasAlive else { return }
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(displays.removalMs)) { [self] in
                    state.withLock { $0.listed = false }
                    displays.gone()
                }
            }
            func waitUntilRemoved() async {
                await VirtualDisplay.waitUntilGone(9, timeout: 5) { _ in state.withLock { $0.listed } }
            }
            func start(_ config: FrameSourceConfig, onFrame: @escaping @Sendable (CVPixelBuffer, UInt64) -> Void,
                       onError: @escaping @Sendable (any Error) -> Void) async throws {}
            func stop() async {}
        }
    }

    /// A takeover inside another takeover's wait: the iPad's second link waits for its first session's
    /// display to go, and a third link displaces the second before it has. The third session waits for
    /// the first session's display too, not only for the second's (which never existed).
    @Test func aTakeoverDuringATakeoverWaitsForEveryEarlierDisplay() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let displays = SlowDisplays(removalMs: 800)
        let rig = try Rig(stored: [Self.serial: secret], video: { displays.pipeline() })
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        let first = try await WiFiIPad.connect(port: port, secret: secret)
        defer { first.link.close() }
        #expect(first.helloAck != nil && displays.live == 1)

        // The iPad redials: the second link takes over and waits while the first session's display goes...
        let second = Task { try await WiFiIPad.connect(port: port, secret: secret) }
        #expect(await first.closed.next() == true)
        #expect(displays.live == 1)
        // ...and redials again before it has gone.
        let third = try await WiFiIPad.connect(port: port, secret: secret)
        defer { third.link.close() }
        #expect(third.helloAck != nil)
        #expect(displays.peak == 1 && displays.live == 1 && displays.created == 2)
        await #expect(throws: (any Error).self) { try await second.value }   // closed without a HelloAck
    }

    /// The same with the cable going in while the second Wi-Fi link waits: the USB session waits for the
    /// first session's display too.
    @Test func theCableGoingInDuringATakeoverWaitsForEveryEarlierDisplay() async throws {
        let secret = ChannelAuth.randomBytes(32)
        let displays = SlowDisplays(removalMs: 800)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret], video: { displays.pipeline() })
        defer { rig.tearDown() }
        let port = try #require(await rig.listening())
        let first = try await WiFiIPad.connect(port: port, secret: secret)
        defer { first.link.close() }
        #expect(first.helloAck != nil && displays.live == 1)

        let second = Task { try await WiFiIPad.connect(port: port, secret: secret) }
        #expect(await first.closed.next() == true)
        #expect(displays.live == 1)
        rig.mux.attach(.init(deviceID: 7, serialNumber: Self.serial))
        let usb = try #require(await rig.usb.links.next(within: 5))
        defer { usb.close() }
        #expect(await rig.usb.received.first { if case .helloAck = $0 { true } else { false } } != nil)
        #expect(await rig.reaches(.connected(deviceModel: "iPad16,6")))
        #expect(displays.peak == 1 && displays.live == 1 && displays.created == 2)
        await #expect(throws: (any Error).self) { try await second.value }
    }
}

/// `IOPMPowerAssertions`' counting, without IOKit (§5.5 Power): held while begins outnumber ends.
@Suite struct PowerAssertionCountTests {
    @Test func theAssertionIsHeldWhileBeginsOutnumberEnds() {
        var count = PowerAssertionCount()
        // Whether each call creates (begin) or releases (end) the IOKit assertion.
        let steps = [count.begin(),    // 0 → 1: create
                     count.begin(),    // a hand-over: the new session begins before the old one ends
                     count.end(),      // 2 → 1: still held
                     count.end(),      // 1 → 0: release
                     count.end(),      // an unmatched end changes nothing
                     count.begin()]    // and the next begin creates it again
        #expect(steps == [true, false, false, true, false, true])
        #expect(count.count == 1)
        let released = count.end()
        #expect(released && count.count == 0)
    }
}
#endif
