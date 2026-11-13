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
/// came up since the loop decided to dial, the scene is in front and the session isn't stopped, and is
/// otherwise closed before `Hello`. Each adopted link gets a generation: a replaced link's late messages
/// are dropped where they land (video, cursor overlay, input), and statuses go out only for the current
/// link, in order. A link that stops being current has its handlers released, so it is freed.
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
        /// The protocol version the link negotiated, and the newest this iPad offered (PROTOCOL-VERSIONING §3.2).
        public var protocolVersion: UInt8 = 0
        public var newestOffered: UInt8 = 0
        /// The Mac's setup (v4 `HostSetup`): what's missing, why there's no video. nil until one arrives,
        /// and always with a Mac on an older version.
        public var setup: HostSetup?
        /// v7: the display's scale, in hundredths, and the ones the host can make for this device (`HelloAck`);
        /// 0 and none with an older host.
        public var displayScale: UInt16 = 0
        public var displayScales: [UInt16] = []
        public init() {}

        /// The Mac runs an older protocol than this iPad's newest: what updating it adds (empty if not).
        public var olderMacMisses: [ProtocolFeature] {
            protocolVersion == 0 ? [] : ProtocolFeature.missing(at: protocolVersion, upTo: newestOffered)
        }
    }

    public enum Status: Sendable, Equatable {
        /// No link: the USB listener waits on `port`; with `wifi`, the Wi-Fi loop runs too.
        case listening(port: UInt16, wifi: Bool = false)
        /// Browsing for paired Macs over Wi-Fi; none seen yet.
        case searching
        /// A lain Mac this iPad holds no Wi-Fi secret for (`mac:<hostId>`): one USB session records it.
        case needsCable(hostName: String)
        /// A Mac shares no protocol version with this iPad (nil name: the Mac on the cable): `gap` says
        /// which of the two needs an update.
        case versionMismatch(hostName: String?, gap: VersionGap)
        /// Local Network access is off for lain: browsing or dialing was refused (TN3179).
        case localNetworkDenied
        /// The Mac answered `Error(busy)` (it has another session, e.g. over USB); retrying later.
        case hostBusy(hostName: String)
        /// The Mac's Wi-Fi listener refused this iPad's key twice in a row (TLS: no PSK under our identity,
        /// or another key under it), and nothing else in sight can be dialed: it lost or replaced the
        /// pairing. One USB session pairs again; the loop keeps retrying meanwhile.
        case pairingRefused(hostName: String)
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
    ///   - port: nil: `LainProtocol.usbPort` (the iPad); 0 in tests (the bound port is `port`).
    ///   - wifi: nil keeps the session USB-only.
    ///   - versions: the protocol versions offered (PROTOCOL-VERSIONING §3.2); nil: `VersionList.offered`.
    ///   - onStatus: called in order on the session's queue; hop to the main queue for UI.
    /// What plays the host's sound (v6 `AudioConfig` and `AudioPacket`); nil drops it. The player is handed
    /// the audio channel's messages on that channel's queue.
    public func setAudioPlayer(_ player: ClientAudioPlayer?) { core.audioSink.player.withLock { $0 = player } }

    public init(port: UInt16? = nil, secrets: some SecretStore, hello: Hello,
                input: ClientInput = ClientInput(), video: ClientVideoPipeline? = nil, wifi: ClientWiFiConfig? = nil,
                versions: VersionList? = nil, onStatus: @escaping @Sendable (Status) -> Void) throws {
        let versions = versions ?? .offered
        let core = SessionCore(secrets: secrets, hello: hello, input: input, video: video, wifi: wifi, versions: versions,
                               onStatus: onStatus)
        self.core = core
        self.input = input
        self.video = video
        listener = try ClientLinkListener(port: port, secrets: secrets, acceptsPairing: true, versions: versions,
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

    /// A Mac this iPad can reach over Wi-Fi (it holds its key), for the panel's host list.
    public struct SavedHost: Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        /// The current link is to it.
        public var isCurrent: Bool
        /// Discovery lists it now (only known while the iPad browses: no link, or a peer-to-peer one).
        public var isSeen: Bool
        public init(id: String, name: String, isCurrent: Bool, isSeen: Bool) {
            self.id = id; self.name = name; self.isCurrent = isCurrent; self.isSeen = isSeen
        }
    }

    public struct HostList: Sendable, Equatable {
        /// By name.
        public var hosts: [SavedHost] = []
        /// The host picked in the panel; nil: automatic.
        public var selected: String?
        /// The current link is the cable: it wins, and the panel offers no switching.
        public var onCable = false
        /// v7: the scales the current host can make for this device (in hundredths, ascending), and the one it
        /// applied; none without a link, or with an older host. The panel offers them.
        public var displayScales: [UInt16] = []
        public var displayScale: UInt16 = 0
        public init() {}
    }

    /// The saved Macs, the pick and whether the cable is in (from the session queue: cheap, for the panel).
    public func hostList() -> HostList { core.queue.sync { core.hostList() } }

    /// The display scale to ask the host for (v7 `Hello.desiredScale`, in hundredths): on every link from now
    /// on, and on the current one at once, which reconnects to take it (a new scale is a new display).
    public func setDesiredScale(_ scale: UInt16) {
        core.queue.async { [core] in core.setDesiredScale(scale) }
    }

    /// Picks the Mac to use over Wi-Fi (nil: automatic). Over Wi-Fi, a link to another Mac closes and the
    /// picked one is dialed at once; over the cable nothing changes (the panel doesn't offer it then).
    public func selectHost(_ id: String?) {
        core.queue.async { [core] in core.selectHost(id) }
    }

    /// The Wi-Fi path and radio priority (the panel). A Wi-Fi link closes and redials at once to take them;
    /// a USB link is left alone.
    public func setNetwork(path: WiFiPath, radioPriority: NetworkStreamOptions.RadioPriority) {
        core.queue.async { [core] in core.setNetwork(path: path, radioPriority: radioPriority) }
    }

    /// The Mac's latest `HostStats` (v5) on the current link, while they're asked for
    /// (`setHostStatsInterval`); nil before the first, and with a Mac on an older version.
    public var hostStats: HostStats? { core.hostStats.withLock { $0.stats } }

    /// Asks the Mac for `HostStats` every `ms` (0: stop), now and on every link that comes up meanwhile;
    /// a Mac without `ProtocolFeature.hostStats` isn't asked.
    public func setHostStatsInterval(ms: UInt32) {
        core.queue.async { [core] in core.setStatsInterval(ms) }
    }

    /// The scene is in front again: a discovery that may have died while the app was suspended is
    /// recreated (§7.7 D29).
    public func sceneDidBecomeActive() {
        core.queue.async { [core] in core.sceneBecameActive() }
    }

    /// The scene went to the background: the Wi-Fi loop stops browsing and dialing (iPadOS suspends the
    /// app soon), and a dial that finishes meanwhile is closed unused; back in front, it dials again.
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

/// The latest `HostStats`, tagged with its link's generation: written by the link's handler, read by the UI.
final class HostStatsSlot: Sendable {
    private let state = Mutex<(generation: UInt64, stats: HostStats?)>((0, nil))
    func withLock<R>(_ body: (inout (generation: UInt64, stats: HostStats?)) -> R) -> R { state.withLock { body(&$0) } }
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
    /// The protocol versions this iPad offers.
    let versions: VersionList
    /// What every link says first; its `desiredScale` changes with the owner's choice.
    var hello: Hello
    let input: ClientInput
    let video: ClientVideoPipeline?
    /// Where the audio channel's messages go (the player); nil drops them.
    let audioSink = AudioSink()
    final class AudioSink: Sendable {
        let player = Mutex<ClientAudioPlayer?>(nil)
    }
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
        /// The Mac's id from its `HelloAck`.
        var hostId: String?
    }

    // Touched only on `queue`.
    var port: UInt16 = 0
    var current: Current?
    /// The last adopted link's.
    var generation: UInt64 = 0
    /// Bumped by every adoption and by `stop()`: a Wi-Fi dial decided under an older epoch is stale.
    var epoch: UInt64 = 0
    var stopped = false
    /// The Mac on the cable shares no protocol version with this iPad (its connection was refused);
    /// cleared by the next link.
    var usbGap: VersionGap?
    private var published: ClientSession.Status?
    /// How often the overlay wants `HostStats` (0: not shown).
    var statsInterval: UInt32 = 0
    /// The latest `HostStats`, tagged with its link's generation (read from any thread).
    let hostStats = HostStatsSlot()

    init(secrets: some SecretStore, hello: Hello, input: ClientInput, video: ClientVideoPipeline?,
         wifi: ClientWiFiConfig?, versions: VersionList, onStatus: @escaping @Sendable (ClientSession.Status) -> Void) {
        self.secrets = secrets
        self.versions = versions
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
            release(c.link)
        }
    }

    // MARK: Adoption (on `queue`)

    /// USB always wins: installed whatever is current.
    func adoptUSB(_ accepted: AcceptedLink) {
        guard !stopped else { return accepted.link.close() }
        adopt(accepted.link, via: .usb(peer: accepted.peer, paired: accepted.paired, secret: accepted.secret))
    }

    /// A finished Wi-Fi dial, installed only if the session isn't stopped, no link is current, none came
    /// up since the loop decided to dial (`epoch`), and the scene is in front (in the background the Mac
    /// would start a session for an app iPadOS is about to suspend; the loop dials again once the scene
    /// is back). Otherwise it is closed before `Hello`.
    func adoptWiFi(_ link: Link, host: DiscoveredHost, decidedAt epoch: UInt64) -> Bool {
        let refused: String? = if stopped {
            "the session stopped"
        } else if current != nil || self.epoch != epoch {
            "another link came up while it was dialing"
        } else if wifi?.paused == true {
            "the scene is in the background"
        } else {
            nil
        }
        if let refused {
            log.notice("Wi-Fi: closing the link to \(host.name, privacy: .public) unused: \(refused, privacy: .public)")
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
        usbGap = nil
        let g = generation
        hostStats.withLock { $0 = (g, nil) }
        var info = ClientSession.ConnectionInfo()
        info.transport = link.transport
        info.protocolVersion = link.version
        info.newestOffered = link.localVersions.newest ?? link.version
        if case .wifi(let host) = via { info.hostName = host.name }
        let state = LinkState(info)
        current = Current(link: link, generation: g, via: via, state: state, info: info)
        if let displaced {
            log.notice("\(via.name, privacy: .public) link replaces the \(displaced.via.name, privacy: .public) link")
            input.disconnect()   // transport switch: nothing stays held from the old link
            displaced.link.close()
            release(displaced.link)
        } else {
            log.notice("\(via.name, privacy: .public) link up (\(String(describing: link.transport), privacy: .public))")
        }
        input.adopt(link: g)
        wifiLinkAdopted()
        wire(link, generation: g, via: via, state: state)
        emit(.connected(info))
    }

    /// Handlers first, then `Hello` (the client always speaks first, §7.1).
    private func wire(_ link: Link, generation g: UInt64, via: Via, state: LinkState) {
        let input = input, video = video, log = log, queue = queue, hostStats = hostStats
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
                    i.displayScale = ack.displayScale
                    i.displayScales = ack.displayScales
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
            case .hostStats(let stats):
                hostStats.withLock { if $0.generation == g { $0.stats = stats } }
            case .hostSetup(let setup):
                log.notice("HostSetup: missing \(setup.missing.map { "\($0)" }.joined(separator: ", "), privacy: .public); video problem: \(setup.videoProblem.isEmpty ? "none" : setup.videoProblem, privacy: .public)")
                state.update({ $0.setup = setup }, publish: publishInfo)
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
        let audioSink = audioSink
        let audioChannel = link.audio
        audioChannel.setHandler { [weak audioChannel] env in
            guard let channel = audioChannel else { return }
            audioSink.player.withLock { $0 }?.handle(env.message, on: channel)
        }
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
        release(c.link)
        let outcome = c.state.outcome.withLock { $0 }
        log.notice("\(c.via.name, privacy: .public) link closed\(outcome.gotHelloAck ? "" : " before HelloAck", privacy: .public)")
        wifiLinkEnded(c.via, outcome: outcome)
        publish()
    }

    /// Replaces the handlers of a link that stopped being current (as `HostConnection.finish` does on the
    /// Mac): a channel keeps its handlers for life, and ours hold the link (the realtime one answers
    /// pings on it and may close it), so otherwise the link, its streams and the video channel's
    /// keyframe-sized parse buffer would never be freed. Whatever still arrives is dropped.
    private func release(_ link: Link) {
        for channel in link.channels {
            channel.setHandler { _ in }
            channel.setCloseHandler { _ in }
        }
    }

    /// On `queue`, in the order the link's snapshots were taken.
    /// The scales the last host offered and the one it applied (v7 `HelloAck`), kept across reconnects.
    private var lastDisplayScales: (scales: [UInt16], applied: UInt16) = ([], 0)

    private func helloAcked(_ ack: HelloAck, info: ClientSession.ConnectionInfo, generation g: UInt64) {
        guard let c = current, c.generation == g else { return }
        lastDisplayScales = (ack.displayScales, ack.displayScale)
        current?.hostId = ack.hostId
        if PairingAccounts.isCanonicalHostId(ack.hostId), !ack.hostName.isEmpty {
            wifi?.config.lastHost.setName(ack.hostId, ack.hostName)
        }
        switch c.via {
        case .usb(let peer, let paired, let secret):
            if recordForWiFi(hostId: ack.hostId, peer: peer, paired: paired, secret: secret) {
                wifi?.config.lastHost.set(ack.hostId)
            }
        case .wifi(let host):
            wifiSessionStarted(host)   // no secret is written: Wi-Fi never pairs (D13)
        }
        publish(info, generation: g)
        if statsInterval > 0 { sendStatsRequest() }   // the overlay is showing: the new Mac too
    }

    func hostList() -> ClientSession.HostList {
        var list = ClientSession.HostList()
        // The last host's, also while a new link comes up (a new scale reconnects): the setting stays put.
        list.displayScales = lastDisplayScales.scales
        list.displayScale = lastDisplayScales.applied
        guard let w = wifi else { return list }
        list.selected = w.config.lastHost.selected()
        if let c = current, c.via.isUSB { list.onCable = true }
        let seen = Set(w.hosts.map(\.hostId))
        list.hosts = w.config.lastHost.names()
            .filter { id, _ in storedSecret(PairingAccounts.mac(id)) != nil }
            .map { id, name in
                ClientSession.SavedHost(id: id, name: name, isCurrent: current?.hostId == id, isSeen: seen.contains(id))
            }
            .sorted { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
        return list
    }

    func selectHost(_ id: String?) {
        guard let w = wifi, !stopped else { return }
        w.config.lastHost.setSelected(id)
        log.notice("host picked: \(id ?? "automatic", privacy: .public)")
        // A Wi-Fi link to another Mac makes way at once; the cable always stays.
        if let id, let c = current, !c.via.isUSB, c.hostId != id { redialWiFi(because: "to switch hosts") }
        redialNow()
    }

    func setDesiredScale(_ scale: UInt16) {
        guard hello.desiredScale != scale else { return }
        hello.desiredScale = scale
        log.notice("display scale \(scale): reconnecting to take it")
        guard let c = current, !stopped else { return }
        // A new link says the new `Hello`. Over the cable the Mac dials again by itself; over Wi-Fi, at once.
        current = nil
        input.disconnect()
        video?.disconnect()
        c.link.close()
        release(c.link)
        if !c.via.isUSB { redialNow() }
        publish()
    }

    func setNetwork(path: WiFiPath, radioPriority: NetworkStreamOptions.RadioPriority) {
        guard let w = wifi, !stopped else { return }
        guard w.config.path != path || w.config.options.radioPriority != radioPriority else { return }
        w.config.path = path
        w.config.options.radioPriority = radioPriority
        log.notice("Wi-Fi: path \(path.rawValue, privacy: .public), radio priority \(radioPriority.rawValue, privacy: .public)")
        if let c = current, !c.via.isUSB { redialWiFi(because: "for the new path and radio priority") }
        redialNow()
    }

    /// Closes the current (Wi-Fi) link at once, as `closed` would, without its backoff.
    private func redialWiFi(because why: String) {
        guard let c = current else { return }
        current = nil
        input.disconnect()
        video?.disconnect()
        c.link.close()
        release(c.link)
        log.notice("Wi-Fi link closed \(why, privacy: .public)")
    }

    /// An explicit switch waits for no grace or backoff.
    private func redialNow() {
        guard let w = wifi else { return }
        w.graceUntil = 0
        w.backoffUntil = 0
        evaluateWiFi()
        publish()
    }

    func setStatsInterval(_ ms: UInt32) {
        guard statsInterval != ms else { return }
        statsInterval = ms
        if ms == 0 { hostStats.withLock { $0.stats = nil } }
        sendStatsRequest()
    }

    /// Tells the current link's Mac the interval, once its `HelloAck` is in and if its version has stats.
    private func sendStatsRequest() {
        guard let c = current, c.link.supports(.hostStats), c.state.outcome.withLock({ $0.gotHelloAck }) else { return }
        c.link.realtime.send(.statsRequest(StatsRequest(intervalMs: statsInterval)))
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
        guard !stopped, let gap = VersionGap(error, local: versions) else { return }
        log.error("the Mac on the cable shares no lain protocol version with this iPad (\(VersionList.offered, privacy: .public)): \(String(describing: gap), privacy: .public)")
        usbGap = gap
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
        emit(wifiStatus() ?? usbGap.map { .versionMismatch(hostName: nil, gap: $0) }
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
