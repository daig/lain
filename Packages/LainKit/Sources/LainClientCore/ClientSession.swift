import Dispatch
import LainProtocol
import LainTelemetry
import LainTransport
import Synchronization

/// The client's session (§6.1, §7.7): the loopback listener the Mac dials over USB and, given a
/// `ClientWiFiConfig`, a loop that finds paired Macs over Wi-Fi and dials them. On each link: `Hello`,
/// `HelloAck` applied to the input pipeline, input out on the realtime channel (global desktop points),
/// `DisplayLayout` and `CursorWarp` in, ping/pong, and frame acks (so `--bench usbmux` keeps working).
///
/// Links are adopted on one serial queue, `lain.client.session` (§7.7 D29), and USB wins: a USB link is
/// always installed (closing the one it replaces); a finished Wi-Fi dial is installed only if no link
/// came up since the loop decided to dial and the session isn't stopped, and is otherwise closed before
/// `Hello`. Each adopted link gets a generation: a replaced link's late messages are dropped where they
/// land (video, cursor overlay, input), and statuses go out only for the current link, in order.
///
/// Invariant 4: when a link closes, or a new link replaces it, the pipeline forgets everything held
/// locally (the host releases on its side when the link drops).
public final class ClientSession: Sendable {
    public struct ConnectionInfo: Sendable, Equatable {
        public var displayPointWidth: UInt32 = 0
        public var displayPointHeight: UInt32 = 0
        /// Displays in the Mac's desktop (`DisplayLayout`); 1 until one arrives.
        public var displayCount = 1
        public var macInputSource = ""
        /// The chroma the Mac streams (`HelloAck`).
        public var chroma: ChromaFormat?
        public var framesReceived = 0
        /// `HelloAck` arrived and was applied; input flows.
        public var isConfigured = false
        /// USB, or the network interface the link runs on (§7.7).
        public var transport: LinkTransport = .usb
        /// The Mac's name from its `HelloAck`; over Wi-Fi its Bonjour name until then.
        public var hostName = ""
        public init() {}
    }

    public enum Status: Sendable, Equatable {
        /// No link: the USB listener waits on `port`; with `wifi`, the Wi-Fi loop runs too.
        case listening(port: UInt16, wifi: Bool = false)
        /// Browsing for paired Macs over Wi-Fi; none seen yet.
        case searching
        /// A lain Mac this iPad holds no Wi-Fi secret for (`mac:<hostId>`): one USB session records it.
        case needsCable(hostName: String)
        /// A Mac runs another lain protocol version (nil name: the Mac on the cable; nil version: its
        /// TXT record names none): one of the two needs an update.
        case versionMismatch(hostName: String?, remote: UInt8?)
        /// Local Network access is off for lain: browsing or dialing was refused (TN3179).
        case localNetworkDenied
        /// The Mac answered `Error(busy)` (it has another session, e.g. over USB); retrying later.
        case hostBusy(hostName: String)
        /// Dialing, or about to dial, a paired Mac over Wi-Fi, seen on these interfaces.
        case connecting(hostName: String, interfaces: [String])
        case connected(ConnectionInfo)
    }

    public let port: UInt16
    public let input: ClientInput
    /// Video (M3): decode, render slot, keyframe requests, cursor shapes. nil keeps the M1/M2
    /// behaviour of acking frames without decoding them.
    public let video: ClientVideoPipeline?
    private let listener: ClientLinkListener
    private let core: SessionCore

    /// - Parameters:
    ///   - port: 47800 on the iPad; 0 in tests (the bound port is `port`).
    ///   - wifi: nil keeps the session USB-only.
    ///   - onStatus: called in order on the session's queue; hop to the main queue for UI.
    public init(port: UInt16 = LainProtocol.usbPort, secrets: some SecretStore, hello: Hello,
                input: ClientInput = ClientInput(), video: ClientVideoPipeline? = nil, wifi: ClientWiFiConfig? = nil,
                onStatus: @escaping @Sendable (Status) -> Void) throws {
        let core = SessionCore(secrets: secrets, hello: hello, input: input, video: video, wifi: wifi, onStatus: onStatus)
        self.core = core
        self.input = input
        self.video = video
        listener = try ClientLinkListener(port: port, secrets: secrets, acceptsPairing: true,
                                          onReject: { [weak core] error in
                                              guard let core else { return }
                                              core.queue.async { core.rejected(error) }
                                          },
                                          onLink: { [weak core] accepted in
                                              guard let core else { return accepted.link.close() }
                                              core.queue.async { core.adoptUSB(accepted) }
                                          })
        self.port = listener.port
        core.start(port: listener.port)
    }

    /// Stops listening and the Wi-Fi loop (discovery and any dial in flight), and closes the current
    /// link. Nothing is installed or published afterwards.
    public func stop() {
        listener.cancel()
        core.stop()
    }

    /// The scene is in front again: a discovery that may have died while the app was suspended is
    /// recreated (§7.7 D29).
    public func sceneDidBecomeActive() {
        core.queue.async { [core] in core.sceneBecameActive() }
    }

    /// The scene went to the background: the Wi-Fi loop stops browsing (iPadOS suspends the app soon).
    public func sceneDidEnterBackground() {
        core.queue.async { [core] in core.sceneEnteredBackground() }
    }
}

/// How a link came to the session.
enum Via: Sendable {
    /// From the USB listener: the account whose secret authenticated it, whether it paired instead,
    /// and the session's secret.
    case usb(peer: String, paired: Bool, secret: [UInt8])
    /// A Wi-Fi dial to this host.
    case wifi(DiscoveredHost)

    var isUSB: Bool { if case .usb = self { true } else { false } }
    var name: String { isUSB ? "USB" : "Wi-Fi" }
}

/// How a link went, for the Wi-Fi loop's backoff (§7.7 D29).
struct LinkOutcome: Sendable, Equatable {
    var gotHelloAck = false
    /// The last `Error` the Mac sent (`busy`: it has another session).
    var error: ErrorMessage.Code?
    /// Over Wi-Fi, `HelloAck` named another host than the one dialed.
    var wrongHost = false
}

/// What one link's channel handlers share.
final class LinkState: Sendable {
    let info: Mutex<ClientSession.ConnectionInfo>
    let outcome = Mutex(LinkOutcome())
    let frames = Atomic<Int>(0)

    init(_ info: ClientSession.ConnectionInfo) { self.info = Mutex(info) }

    /// Applies `change` and hands the result to `publish` under the lock, so snapshots are published in
    /// the order they were taken, whichever channel took them.
    func update(_ change: (inout ClientSession.ConnectionInfo) -> Void,
                publish: (ClientSession.ConnectionInfo) -> Void) {
        info.withLock { i in
            change(&i)
            publish(i)
        }
    }
}

/// Everything ClientSession decides, confined to its serial queue (§7.7 D29): the current link and its
/// generation, adoption, the Wi-Fi secret writes, statuses, and the Wi-Fi loop (`ClientWiFi.swift`).
/// Unchecked: every mutable member is touched only on `queue`.
final class SessionCore: @unchecked Sendable {
    let queue = DispatchQueue(label: "lain.client.session", qos: .userInitiated)
    let secrets: any SecretStore
    let hello: Hello
    let input: ClientInput
    let video: ClientVideoPipeline?
    let wifi: WiFiLoop?
    let log = Telemetry.logger("client")
    private let onStatus: @Sendable (ClientSession.Status) -> Void
    private let onQueueKey = DispatchSpecificKey<UInt8>()

    struct Current {
        let link: Link
        let generation: UInt64
        let via: Via
        let state: LinkState
        /// The last snapshot published for it.
        var info: ClientSession.ConnectionInfo
    }

    // Touched only on `queue`.
    var port: UInt16 = 0
    var current: Current?
    /// The last adopted link's.
    var generation: UInt64 = 0
    /// Bumped by every adoption and by `stop()`: a Wi-Fi dial decided under an older epoch is stale.
    var epoch: UInt64 = 0
    var stopped = false
    /// The Mac on the cable speaks another protocol version (its connection was refused); cleared by
    /// the next link.
    var usbMismatch: UInt8?
    private var published: ClientSession.Status?

    init(secrets: some SecretStore, hello: Hello, input: ClientInput, video: ClientVideoPipeline?,
         wifi: ClientWiFiConfig?, onStatus: @escaping @Sendable (ClientSession.Status) -> Void) {
        self.secrets = secrets
        self.hello = hello
        self.input = input
        self.video = video
        self.wifi = wifi.map(WiFiLoop.init)
        self.onStatus = onStatus
        queue.setSpecific(key: onQueueKey, value: 1)
    }

    func start(port: UInt16) {
        queue.async { [self] in
            self.port = port
            startWiFi()
            publish()
        }
    }

    /// Synchronous, so nothing is installed or published once it returns.
    func stop() {
        onQueue { [self] in
            guard !stopped else { return }
            stopped = true
            epoch &+= 1
            stopWiFi()
            guard let c = current else { return }
            current = nil
            input.disconnect()
            video?.disconnect()
            c.link.close()
        }
    }

    // MARK: Adoption (on `queue`)

    /// USB always wins: installed whatever is current.
    func adoptUSB(_ accepted: AcceptedLink) {
        guard !stopped else { return accepted.link.close() }
        adopt(accepted.link, via: .usb(peer: accepted.peer, paired: accepted.paired, secret: accepted.secret))
    }

    /// A finished Wi-Fi dial, installed only if no link is current, none came up since the loop decided
    /// to dial (`epoch`), and the session isn't stopped. Otherwise it is closed before `Hello`.
    func adoptWiFi(_ link: Link, host: DiscoveredHost, decidedAt epoch: UInt64) -> Bool {
        guard !stopped, current == nil, self.epoch == epoch else {
            log.notice("Wi-Fi: closing the link to \(host.name, privacy: .public) unused: another link came up while it was dialing")
            link.close()
            return false
        }
        adopt(link, via: .wifi(host))
        return true
    }

    private func adopt(_ link: Link, via: Via) {
        let displaced = current
        generation &+= 1
        epoch &+= 1
        usbMismatch = nil
        let g = generation
        var info = ClientSession.ConnectionInfo()
        info.transport = link.transport
        if case .wifi(let host) = via { info.hostName = host.name }
        let state = LinkState(info)
        current = Current(link: link, generation: g, via: via, state: state, info: info)
        if let displaced {
            log.notice("\(via.name, privacy: .public) link replaces the \(displaced.via.name, privacy: .public) link")
            input.disconnect()   // transport switch: nothing stays held from the old link
            displaced.link.close()
        } else {
            log.notice("\(via.name, privacy: .public) link up (\(String(describing: link.transport), privacy: .public))")
        }
        input.adopt(link: g)
        wifiLinkAdopted(via)
        wire(link, generation: g, via: via, state: state)
        emit(.connected(info))
    }

    /// Handlers first, then `Hello` (the client always speaks first, §7.1).
    private func wire(_ link: Link, generation g: UInt64, via: Via, state: LinkState) {
        let input = input, video = video, log = log, queue = queue
        let realtime = link.realtime, videoChannel = link.video
        // Hops to the session queue; enqueued under the info lock (`LinkState.update`), so in order.
        let publishInfo: @Sendable (ClientSession.ConnectionInfo) -> Void = { [weak self] info in
            guard let self else { return }
            queue.async { self.publish(info, generation: g) }
        }
        let acked: @Sendable (HelloAck, ClientSession.ConnectionInfo) -> Void = { [weak self] ack, info in
            guard let self else { return }
            queue.async { self.helloAcked(ack, info: info, generation: g) }
        }
        // Before any handler: tagged cursor messages for this link must find it current.
        video?.connect(generation: g, control: { realtime.send($0) }, video: { videoChannel.send($0) })

        let control: @Sendable (Envelope) -> Void = { env in
            switch env.message {
            case .ping(let p):
                let received = MonotonicClock.now()
                realtime.send(.pong(Pong(id: p.id, pingSentAtNs: p.sentAtNs, receivedAtNs: received,
                                         sentAtNs: MonotonicClock.now())))
            case .helloAck(let ack):
                log.notice("HelloAck from \(ack.hostName, privacy: .public) (\(ack.hostId, privacy: .public)): \(ack.displayPointWidth)×\(ack.displayPointHeight) pt, input source \(ack.macInputSource, privacy: .public)")
                if case .wifi(let host) = via, ack.hostId != host.hostId {
                    // Over Wi-Fi the Mac must be the one dialed (its id is public and self-asserted).
                    log.error("Wi-Fi: closing the link: \(host.name, privacy: .public) answered as host \(ack.hostId, privacy: .public), not \(host.hostId, privacy: .public)")
                    state.outcome.withLock { $0.wrongHost = true }
                    return link.close()
                }
                state.outcome.withLock { $0.gotHelloAck = true }
                input.configure(ack, generation: g)
                input.connect(generation: g) { realtime.send($0) }
                state.update({ i in
                    i.displayPointWidth = ack.displayPointWidth
                    i.displayPointHeight = ack.displayPointHeight
                    i.macInputSource = ack.macInputSource
                    i.chroma = ack.chroma
                    i.isConfigured = true
                    if !ack.hostName.isEmpty { i.hostName = ack.hostName }
                }, publish: { info in
                    // Published by the session queue once it has taken the HelloAck (over USB, recorded
                    // the Mac for Wi-Fi): only then does a status say configured.
                    acked(ack, info)
                })
            case .displayLayout(let layout):
                // The full desktop: the cursor roams every display; the streamed one sets the size.
                input.applyLayout(layout, generation: g)
                state.update({ i in
                    if let s = layout.displays.first(where: \.isStreamed) {
                        i.displayPointWidth = UInt32(max(s.width, 0).rounded())
                        i.displayPointHeight = UInt32(max(s.height, 0).rounded())
                    }
                    i.displayCount = layout.displays.count
                }, publish: publishInfo)
            case .cursorWarp(let w):
                input.warp(x: w.x, y: w.y, generation: g)
            case .cursorShape, .cursorSelect:
                video?.cursor.apply(env.message, generation: g)
            case .error(let e):
                log.error("the Mac refused the session: \(String(describing: e.code), privacy: .public) \(e.message, privacy: .public)")
                state.outcome.withLock { $0.error = e.code }
            default:
                break
            }
        }
        realtime.setHandler(control)
        videoChannel.setHandler { env in
            if let video {
                // Decodes and acks frames itself (§7.3), and sees every envelope for gap detection.
                guard video.handleVideo(env, generation: g) else { return control(env) }
                guard case .videoFrame = env.message else { return }
            } else {
                guard case .videoFrame(let f) = env.message else { return control(env) }
                videoChannel.send(.frameAck(FrameAck(frameId: f.frameId, receivedAtNs: MonotonicClock.now(),
                                                     bytes: UInt32(f.data.count))))
            }
            let n = state.frames.add(1, ordering: .relaxed).newValue
            if n % 30 == 0 { state.update({ $0.framesReceived = n }, publish: publishInfo) }
        }
        link.audio.setHandler { _ in }
        realtime.setCloseHandler { [weak self] _ in
            guard let self else { return }
            queue.async { self.closed(generation: g) }
        }
        realtime.send(.hello(hello))
    }

    /// The current link's realtime connection closed; a replaced link's close changes nothing.
    private func closed(generation g: UInt64) {
        guard let c = current, c.generation == g else { return }
        current = nil
        input.disconnect()
        video?.disconnect()
        c.link.close()
        let outcome = c.state.outcome.withLock { $0 }
        log.notice("\(c.via.name, privacy: .public) link closed\(outcome.gotHelloAck ? "" : " before HelloAck", privacy: .public)")
        wifiLinkEnded(c.via, outcome: outcome)
        publish()
    }

    /// On `queue`, in the order the link's snapshots were taken.
    private func helloAcked(_ ack: HelloAck, info: ClientSession.ConnectionInfo, generation g: UInt64) {
        guard let c = current, c.generation == g else { return }
        switch c.via {
        case .usb(let peer, let paired, let secret):
            if recordForWiFi(hostId: ack.hostId, peer: peer, paired: paired, secret: secret) {
                wifi?.config.lastHost.set(ack.hostId)
            }
        case .wifi(let host):
            wifi?.config.lastHost.set(host.hostId)   // and no secret is written: Wi-Fi never pairs (D13)
            wifiSessionStarted(host)
        }
        publish(info, generation: g)
    }

    /// Over USB only (§7.7 D29): the link's secret becomes usable over Wi-Fi under `mac:<hostId>`, if the
    /// Mac names a canonical id and the link authenticated with the USB account, with that Mac's own
    /// account, or just paired. The id is self-asserted and public, so a link authenticated as another
    /// Mac can't claim it. True when recorded.
    private func recordForWiFi(hostId: String, peer: String, paired: Bool, secret: [UInt8]) -> Bool {
        guard !hostId.isEmpty else { return false }
        guard PairingAccounts.isCanonicalHostId(hostId) else {
            log.error("HelloAck carried a malformed host id; not recorded for Wi-Fi")
            return false
        }
        let account = PairingAccounts.mac(hostId)
        guard paired || peer == PairingAccounts.usbHost || peer == account else {
            log.error("a USB link authenticated as \(peer, privacy: .public) claims host \(hostId, privacy: .public); not recorded for Wi-Fi")
            return false
        }
        do {
            try secrets.setSecret(secret, for: account)
            log.notice("recorded \(account, privacy: .public) for Wi-Fi")
            return true
        } catch {
            log.error("could not record \(account, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The USB listener refused a connection: a Mac on another protocol version is worth a status.
    func rejected(_ error: any Error) {
        guard !stopped, case .versionMismatch(let remote)? = error as? TransportError else { return }
        log.error("the Mac on the cable speaks lain protocol v\(remote); this iPad speaks v\(LainProtocol.majorVersion)")
        usbMismatch = remote
        publish()
    }

    // MARK: Statuses (on `queue`)

    /// A snapshot of link `g`'s info, if it is still the current link.
    private func publish(_ info: ClientSession.ConnectionInfo, generation g: UInt64) {
        guard current?.generation == g else { return }
        current?.info = info
        emit(.connected(info))
    }

    /// The status as derived from the state: the current link's last snapshot, else the Wi-Fi loop's
    /// view (which ranks a refused USB connection), else waiting.
    func publish() {
        if let c = current { return emit(.connected(c.info)) }
        emit(wifiStatus() ?? usbMismatch.map { .versionMismatch(hostName: nil, remote: $0) }
             ?? .listening(port: port, wifi: wifi != nil))
    }

    private func emit(_ status: ClientSession.Status) {
        guard !stopped, status != published else { return }
        published = status
        onStatus(status)
    }

    /// Runs `body` on `queue` and waits (inline when already there).
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: onQueueKey) != nil { body() } else { queue.sync(execute: body) }
    }
}
