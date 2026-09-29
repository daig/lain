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
        // Exactly one release, before the USB session's setup; the assertion never lapsed.
        #expect(rig.sink.calls == [.keyboardType(.ansi), .key(down), .releaseAll, .keyboardType(.iso)])
        #expect(rig.power.begins == 2 && rig.power.ends == 1 && rig.power.holding)
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

        let early = try await WiFiIPad.connect(port: port, secret: secret)
        defer { early.link.close() }
        #expect(ContinuousClock.now - start < .milliseconds(1200))
        #expect(early.reply == .error(ErrorMessage(code: .busy, message: "this iPad is on USB")))
        #expect(await early.closed.next(within: 3) == true)

        // Once USB has had its chance, Wi-Fi is let in.
        try await Task.sleep(until: start + .milliseconds(1700), clock: .continuous)
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
        #expect(rig.power.begins == 2 && rig.power.ends == 1 && rig.power.holding)
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
    }

    @Test func theCaptureBackoffHoldsEveryTransport() async throws {
        let secret = ChannelAuth.randomBytes(32)
        var tuning = HostSession.Tuning()
        tuning.captureRetryInterval = .milliseconds(1500)
        let rig = try Rig(stored: [Self.serial: secret], usb: [PairingAccounts.usbHost: secret], tuning: tuning, video: {
            let failing = FailingVideo()
            return HostVideoPipeline(display: failing, frameSource: failing, cursorSource: nil)
        })
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
        try await Task.sleep(until: ended + .milliseconds(1000), clock: .continuous)
        #expect(rig.mux.connectCount == 0)   // the USB loop waits too
        #expect(await eventually(within: 3) { rig.mux.connectCount > 0 })
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
