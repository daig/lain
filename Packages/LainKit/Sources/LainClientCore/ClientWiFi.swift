import Dispatch
import Foundation
import LainProtocol
import LainTelemetry
import LainTransport
import Network
import Synchronization

/// How ClientSession finds paired Macs over Wi-Fi and dials them (§7.7 D29). The app passes Bonjour
/// discovery and the defaults; tests pass a fixed discovery, loopback options and short times.
public struct ClientWiFiConfig: Sendable {
    /// A new discovery each time the loop (re)starts browsing: `BonjourHostDiscovery(serviceType:
    /// LainProtocol.bonjourServiceType)` in the app, `FixedHostDiscovery` in tests (tests never browse).
    public var discovery: @Sendable () -> any HostDiscovery
    /// The dialer's connections: the defaults (peer-to-peer on) in the app, `.loopback` in tests.
    public var options: NetworkStreamOptions
    /// Seconds with no link before a Wi-Fi dial: at start, after a USB link, and after a Wi-Fi session
    /// that ran, so a cable that is (re)connecting comes first (USB is preferred).
    public var grace = 1.5
    /// After `Error(busy)` (the Mac has another session, e.g. over USB): at least this long.
    public var busyBackoff = 5.0
    /// After a link that ended before `HelloAck`: this, doubling up to `maxBackoff`; reset by a session
    /// that ran.
    public var failureBackoff = 0.5
    public var maxBackoff = 8.0
    /// After a failed dial (TLS, refused, timeout…), for that service (not host id: one id can be
    /// advertised twice): this, doubling up to `maxBackoff`. A service that keeps refusing this iPad's
    /// key is retried every `maxBackoff`. The end of a USB link clears all of it.
    public var serviceBackoff = 0.5
    /// A discovery that failed is recreated after this, doubling up to `maxDiscoveryBackoff`.
    public var discoveryBackoff = 1.0
    public var maxDiscoveryBackoff = 30.0
    /// Per connection of a dial.
    public var dialTimeout = NetworkStreamDialer.defaultTimeout
    /// The id of the Mac last connected, preferred when several paired Macs are visible, and each Mac's
    /// service that last answered, dialed first among its services.
    public var lastHost: LastConnectedHost
    /// Tests only: wraps each attempt's dialer (to hold a dial, or watch its streams).
    var interpose: (@Sendable (any StreamDialer) -> any StreamDialer)?

    public init(discovery: @escaping @Sendable () -> any HostDiscovery, options: NetworkStreamOptions = NetworkStreamOptions(),
                lastHost: LastConnectedHost = .memory()) {
        self.discovery = discovery
        self.options = options
        self.lastHost = lastHost
    }
}

/// Where the client remembers the Mac it last connected to and, per Mac, the Wi-Fi service that last
/// answered with `HelloAck` (a `WiFiDialPlan.serviceKey`): `UserDefaults` in the app, memory in tests.
public struct LastConnectedHost: Sendable {
    /// The last-connected Mac's host id.
    public var get: @Sendable () -> String?
    public var set: @Sendable (String) -> Void
    /// The service that last answered for a host id, if any.
    public var service: @Sendable (_ hostId: String) -> String?
    public var setService: @Sendable (_ hostId: String, _ service: String) -> Void

    public init(get: @escaping @Sendable () -> String?, set: @escaping @Sendable (String) -> Void,
                service: @escaping @Sendable (_ hostId: String) -> String? = { _ in nil },
                setService: @escaping @Sendable (_ hostId: String, _ service: String) -> Void = { _, _ in }) {
        self.get = get
        self.set = set
        self.service = service
        self.setService = setService
    }

    /// `servicesKey` holds a dictionary host id → service (one entry per Mac that answered over Wi-Fi).
    public static func userDefaults(key: String = "lain.lastHostId",
                                    servicesKey: String = "lain.lastHostServices") -> LastConnectedHost {
        LastConnectedHost(get: { UserDefaults.standard.string(forKey: key) },
                          set: { UserDefaults.standard.set($0, forKey: key) },
                          service: { id in UserDefaults.standard.dictionary(forKey: servicesKey)?[id] as? String },
                          setService: { id, service in
                              // Written on the session queue only: the read-modify-write can't interleave.
                              var all = UserDefaults.standard.dictionary(forKey: servicesKey) ?? [:]
                              all[id] = service
                              UserDefaults.standard.set(all, forKey: servicesKey)
                          })
    }

    public static func memory(_ initial: String? = nil) -> LastConnectedHost {
        let box = Box(initial)
        return LastConnectedHost(get: { box.value.withLock { $0.id } }, set: { id in box.value.withLock { $0.id = id } },
                                 service: { id in box.value.withLock { $0.services[id] } },
                                 setService: { id, service in box.value.withLock { $0.services[id] = service } })
    }

    private final class Box: Sendable {
        let value: Mutex<(id: String?, services: [String: String])>
        init(_ initial: String?) { value = Mutex((initial, [:])) }
    }
}

/// Which discovered Macs the client may dial (§7.7 D29): a canonical host id, a protocol version this
/// iPad also offers (TXT `vs`, PROTOCOL-VERSIONING §3.2), and a Wi-Fi secret (`mac:<hostId>`) in the store. Every service of such a Mac is a
/// candidate (one id can be advertised twice, e.g. after a Bonjour rename), the last-connected Mac's
/// first. What can't be dialed is kept, for the status. Hosts with a malformed id are ignored.
struct WiFiDialPlan: Equatable {
    struct Candidate: Equatable {
        var host: DiscoveredHost
        var secret: [UInt8]
    }

    struct OtherVersion: Equatable {
        var host: DiscoveredHost
        /// Which side needs the update.
        var gap: VersionGap
        /// This iPad holds its secret: probably its own Mac, one side needs an update.
        var paired: Bool
    }

    var candidates: [Candidate] = []
    /// The right version, but no Wi-Fi secret yet: one USB session records it (the migration path).
    var needsCable: [DiscoveredHost] = []
    var otherVersion: [OtherVersion] = []

    init() {}

    /// `secret` reads an account of the client's store; `versions` nil: `VersionList.offered`.
    init(hosts: [DiscoveredHost], preferring lastHostId: String?, versions: VersionList? = nil,
         secret: (String) -> [UInt8]?) {
        for host in hosts where PairingAccounts.isCanonicalHostId(host.hostId) {
            let stored = secret(PairingAccounts.mac(host.hostId))
            if let gap = VersionGap(local: versions, advertised: host.versions) {
                otherVersion.append(OtherVersion(host: host, gap: gap, paired: stored != nil))
            } else if let stored {
                candidates.append(Candidate(host: host, secret: stored))
            } else {
                needsCable.append(host)
            }
        }
        if let lastHostId {
            candidates = candidates.filter { $0.host.hostId == lastHostId } + candidates.filter { $0.host.hostId != lastHostId }
        }
    }

    /// The plan with `candidates` in dial order: Macs as listed (the last-connected first); among one
    /// Mac's services, the one that last answered with `HelloAck` (`lastGood(hostId)`, a `serviceKey`)
    /// first, then the least recently tried (`lastTried`; ties keep discovery order). The host id is
    /// public, so anyone can advertise it: a round-robin keeps services that stall TLS from starving
    /// the real one, which a fixed order by name wouldn't.
    func ordered(lastGood: (_ hostId: String) -> String?, lastTried: (NWEndpoint) -> UInt64) -> WiFiDialPlan {
        var ids: [String] = []
        for c in candidates where !ids.contains(c.host.hostId) { ids.append(c.host.hostId) }
        let good = Dictionary(uniqueKeysWithValues: ids.map { ($0, lastGood($0)) })
        // Sorted by (the Mac's place, last answered first, least recently tried, discovery order).
        let ranked = candidates.enumerated().map { i, c in
            let answered = Self.serviceKey(c.host.endpoint) == (good[c.host.hostId] ?? nil)
            return (key: (ids.firstIndex(of: c.host.hostId) ?? 0, answered ? 0 : 1, lastTried(c.host.endpoint), i), candidate: c)
        }
        var plan = self
        plan.candidates = ranked.sorted { $0.key < $1.key }.map(\.candidate)
        return plan
    }

    /// Names a discovered service across browses and launches: a Bonjour service by name, type and
    /// domain (not the interface it was seen on), anything else by its address.
    static func serviceKey(_ endpoint: NWEndpoint) -> String {
        if case .service(let name, let type, let domain, _) = endpoint { return "\(name).\(type).\(domain)" }
        return endpoint.debugDescription
    }
}

/// A delay that doubles each time it is taken, up to `max`, until `reset`.
struct Backoff {
    let initial: Double
    let max: Double
    private(set) var next: Double

    init(initial: Double, max: Double) {
        self.initial = initial
        self.max = max
        next = initial
    }

    mutating func take() -> Double {
        defer { next = Swift.min(next * 2, max) }
        return next
    }

    mutating func reset() { next = initial }
}

/// The Wi-Fi loop's state (§7.7 D29). Touched only on the session queue; its logic is `SessionCore`'s.
final class WiFiLoop {
    /// Dials in a row a service refused this iPad's key on (TLS: unknown PSK identity, wrong key) before
    /// the status says the Mac doesn't recognize it: one alone can be a Mac reloading its keys.
    static let refusedAfter = 2

    struct Attempt {
        let id: UInt64
        let host: DiscoveredHost
        /// The session's epoch when the loop decided to dial.
        let epoch: UInt64
        let task: Task<Void, Never>
    }

    /// A discovered service's dial history, kept while discovery lists it; its failures are cleared by a
    /// session with it that got `HelloAck`, and by the end of a USB link.
    struct Service {
        var backoff: Backoff
        /// No dial to it before this (`MonotonicClock` ns).
        var until: UInt64 = 0
        /// When it was last dialed, or first seen if never (ns): among one Mac's services the least
        /// recently tried goes first, and a service that keeps reappearing under new names waits behind
        /// the ones already listed.
        var lastAttemptAt: UInt64
        /// Dials in a row TLS refused this iPad's key on.
        var keyRefusals = 0
        /// Its handshake found no common protocol version (its TXT suggested one): which side to update.
        var versionGap: VersionGap?

        var refusesKey: Bool { keyRefusals >= WiFiLoop.refusedAfter }

        /// Forgets its failures (backoff, wait, refusals), not its turn: `lastAttemptAt` stays.
        mutating func clearFailures() {
            backoff.reset()
            until = 0
            keyRefusals = 0
            versionGap = nil
        }
    }

    let config: ClientWiFiConfig
    var discovery: (any HostDiscovery)?
    /// Numbers discoveries, so a replaced one's late reports are ignored.
    var discoverySerial: UInt64 = 0
    var discoveryState: DiscoveryState?
    var hosts: [DiscoveredHost] = []
    /// `hosts` as the dial policy sees them, re-read from the secret store at each evaluation.
    var plan = WiFiDialPlan()
    var discoveryRetry: Backoff
    /// A failed discovery is recreated from this time on (ns; 0: whenever wanted).
    var discoveryRestartAt: UInt64 = 0
    /// The scene is in the background: no browsing, no new dials.
    var paused = false
    var dialing: Attempt?
    var attempts: UInt64 = 0
    /// No dial before these (ns): the grace after a link that ran, the backoff after one that didn't.
    var graceUntil: UInt64 = 0
    var backoffUntil: UInt64 = 0
    var linkFailures: Backoff
    var services: [NWEndpoint: Service] = [:]
    /// The Mac that answered `Error(busy)`, shown while `backoffUntil` runs.
    var busyHost: String?
    /// A dial found Local Network access off.
    var dialDenied = false
    var timer: DispatchWorkItem?
    var timerAt: UInt64 = 0

    init(config: ClientWiFiConfig) {
        self.config = config
        discoveryRetry = Backoff(initial: config.discoveryBackoff, max: config.maxDiscoveryBackoff)
        linkFailures = Backoff(initial: config.failureBackoff, max: config.maxBackoff)
    }

    func newService(seenAt now: UInt64) -> Service {
        Service(backoff: Backoff(initial: config.serviceBackoff, max: config.maxBackoff), lastAttemptAt: now)
    }

    /// Whether the loop browses while `link` is current (§7.7 D29): with none, and over a peer-to-peer
    /// Wi-Fi link (AWDL is busy anyway, and the Mac is found again at once if the link drops). Not over
    /// USB or a Wi-Fi link through the LAN: nothing is dialed meanwhile, and a peer-to-peer browse keeps
    /// AWDL active, which time-shares the radio with the LAN's channel.
    static func browses(during link: (via: Via, transport: LinkTransport)?) -> Bool {
        guard let link else { return true }
        if case .wifi = link.via, case .network(_, peerToPeer: true) = link.transport { return true }
        return false
    }
}

/// The Wi-Fi loop (§7.7 D29), on the session queue: browse while the scene is in front and no link is
/// current, or the current one is a peer-to-peer Wi-Fi link (`WiFiLoop.browses(during:)`); dial a
/// paired Mac once no link is current, the grace and backoffs have passed and its service isn't backing
/// off, taking one Mac's services in turn (`WiFiDialPlan.ordered`); learn from each dial and each
/// link's end. Without a `ClientWiFiConfig` all of it is a no-op.
extension SessionCore {
    func startWiFi() {
        guard let w = wifi else { return }
        w.graceUntil = MonotonicClock.now() + Self.ns(w.config.grace)
        evaluateWiFi()
    }

    /// `stop()`: the loop, the discovery and any dial in flight (its link, if it still comes, is closed).
    func stopWiFi() {
        guard let w = wifi else { return }
        w.timer?.cancel()
        w.timer = nil
        stopDiscovery()
        w.dialing?.task.cancel()
        w.dialing = nil
    }

    func sceneBecameActive() {
        guard let w = wifi, !stopped else { return }
        // Back from the background, the browser may have died while suspended (mDNSResponder's connection
        // goes defunct); a denied one may have been allowed in Settings meanwhile.
        if w.paused || w.discoveryState == .denied || w.dialDenied {
            stopDiscovery()
            w.discoveryRestartAt = 0
            w.discoveryRetry.reset()
        }
        w.paused = false
        w.dialDenied = false
        evaluateWiFi()
        publish()
    }

    /// No browsing and no new dials; a dial under way finishes, and `adoptWiFi` closes its link unused.
    func sceneEnteredBackground() {
        guard let w = wifi, !stopped else { return }
        w.paused = true
        evaluateWiFi()
        publish()
    }

    /// A link was adopted: the loop stops browsing unless it is a peer-to-peer Wi-Fi link.
    func wifiLinkAdopted() {
        guard let w = wifi else { return }
        w.busyHost = nil
        updateDiscovery(now: MonotonicClock.now())
    }

    /// A Wi-Fi session got its `HelloAck`: its Mac is the last connected, its service is fine and the
    /// first of the Mac's to dial next time.
    func wifiSessionStarted(_ host: DiscoveredHost) {
        guard let w = wifi else { return }
        w.config.lastHost.set(host.hostId)
        w.config.lastHost.setService(host.hostId, WiFiDialPlan.serviceKey(host.endpoint))
        w.services[host.endpoint]?.clearFailures()
    }

    /// The current link ended: when the next dial may happen.
    func wifiLinkEnded(_ via: Via, outcome: LinkOutcome) {
        guard let w = wifi, !stopped else { return }
        let now = MonotonicClock.now()
        switch via {
        case .usb:
            w.graceUntil = now + Self.ns(w.config.grace)
            // The Mac reloads its Wi-Fi keys at each USB link-up (§7.7 D29 decision 9), which is what fixes
            // a listener that refused this iPad's key (its service keeps its name): each service is dialed
            // again after the grace, in turn. At the end, not the start: a dial in flight when the cable
            // came may be refused after it.
            for endpoint in w.services.keys { w.services[endpoint]?.clearFailures() }
        case .wifi(let host):
            if outcome.error == .busy {
                let delay = Swift.max(w.config.busyBackoff, w.linkFailures.take())
                w.backoffUntil = now + Self.ns(delay)
                w.busyHost = host.name
                log.notice("Wi-Fi: \(host.name, privacy: .public) is busy with another session; next dial in \(delay) s")
            } else if !outcome.gotHelloAck {
                let delay = w.linkFailures.take()
                w.backoffUntil = now + Self.ns(delay)
                if outcome.wrongHost { penalize(host) }
                log.notice("Wi-Fi: the link to \(host.name, privacy: .public) ended before HelloAck; next dial in \(delay) s")
            } else {
                w.linkFailures.reset()
                w.graceUntil = now + Self.ns(w.config.grace)
            }
        }
        evaluateWiFi()
    }

    /// Decides what the loop does now, and wakes itself when a wait ends.
    func evaluateWiFi() {
        guard let w = wifi, !stopped else { return }
        let now = MonotonicClock.now()
        updateDiscovery(now: now)
        w.plan = current == nil && w.discovery != nil
            ? WiFiDialPlan(hosts: w.hosts, preferring: w.config.lastHost.get(), versions: versions, secret: storedSecret)
                .ordered(lastGood: w.config.lastHost.service, lastTried: { w.services[$0]?.lastAttemptAt ?? now })
            : WiFiDialPlan()
        guard current == nil, w.dialing == nil, !w.paused, !w.plan.candidates.isEmpty else { return }
        let notBefore = Swift.max(w.graceUntil, w.backoffUntil)
        guard now >= notBefore else { return wakeWiFi(at: notBefore) }
        guard let pick = w.plan.candidates.first(where: { (w.services[$0.host.endpoint]?.until ?? 0) <= now }) else {
            let next = w.plan.candidates.compactMap { w.services[$0.host.endpoint]?.until }.min() ?? now
            return wakeWiFi(at: next)
        }
        dial(pick)
    }

    /// The loop's part of the status while no link is current, strongest first: what it is doing
    /// (dialing, refused Local Network access, a busy Mac, a paired Mac it will dial, or one that
    /// refuses this iPad's key), then the USB listener's version mismatch, then what it merely saw.
    func wifiStatus() -> ClientSession.Status? {
        guard let w = wifi, current == nil else { return nil }
        // Only when every paired Mac in sight refuses the key; then also while one is redialed, so the
        // status doesn't flip back to "Connecting" at each retry.
        let refuses = { (host: DiscoveredHost) in w.services[host.endpoint]?.refusesKey == true }
        let allRefuse = !w.plan.candidates.isEmpty && w.plan.candidates.allSatisfy { refuses($0.host) }
        if let a = w.dialing {
            if allRefuse, refuses(a.host) { return .pairingRefused(hostName: a.host.name) }
            return .connecting(hostName: a.host.name, interfaces: a.host.interfaceNames)
        }
        if w.paused { return nil }
        if w.discoveryState == .denied || w.dialDenied { return .localNetworkDenied }
        if let busy = w.busyHost, MonotonicClock.now() < w.backoffUntil { return .hostBusy(hostName: busy) }
        let gap = { (host: DiscoveredHost) in w.services[host.endpoint]?.versionGap }
        if let next = w.plan.candidates.first(where: { !refuses($0.host) && gap($0.host) == nil }) {
            return .connecting(hostName: next.host.name, interfaces: next.host.interfaceNames)
        }
        if let gapped = w.plan.candidates.first(where: { gap($0.host) != nil }), let g = gap(gapped.host) {
            return .versionMismatch(hostName: gapped.host.name, gap: g)
        }
        if let refusing = w.plan.candidates.first { return .pairingRefused(hostName: refusing.host.name) }
        if let usbGap { return .versionMismatch(hostName: nil, gap: usbGap) }
        if let other = w.plan.otherVersion.first(where: \.paired) {
            return .versionMismatch(hostName: other.host.name, gap: other.gap)
        }
        if let host = w.plan.needsCable.first { return .needsCable(hostName: host.name) }
        if let other = w.plan.otherVersion.first {
            return .versionMismatch(hostName: other.host.name, gap: other.gap)
        }
        if w.discovery != nil || w.discoveryRestartAt != 0 { return .searching }
        return nil
    }

    // MARK: Private

    /// Browses when `WiFiLoop.browses(during:)` allows it and the scene is in front; a failed discovery
    /// is recreated once its backoff has passed.
    private func updateDiscovery(now: UInt64) {
        guard let w = wifi else { return }
        if w.paused || !WiFiLoop.browses(during: current.map { ($0.via, $0.link.transport) }) {
            stopDiscovery()
        } else if w.discovery == nil {
            if now >= w.discoveryRestartAt { startDiscovery() } else { wakeWiFi(at: w.discoveryRestartAt) }
        }
    }

    private func startDiscovery() {
        guard let w = wifi else { return }
        let discovery = w.config.discovery()
        w.discoverySerial &+= 1
        let serial = w.discoverySerial
        w.discovery = discovery
        w.discoveryState = nil
        w.hosts = []
        log.notice("Wi-Fi: looking for paired Macs")
        discovery.start(onChange: { [weak self] hosts in
            guard let self else { return }
            queue.async { self.discovered(hosts, serial: serial) }
        }, onState: { [weak self] state in
            guard let self else { return }
            queue.async { self.discoveryStateChanged(state, serial: serial) }
        })
    }

    private func stopDiscovery() {
        guard let w = wifi, let discovery = w.discovery else { return }
        discovery.cancel()
        w.discovery = nil
        w.discoveryState = nil
        w.hosts = []
    }

    private func discovered(_ hosts: [DiscoveredHost], serial: UInt64) {
        guard let w = wifi, w.discovery != nil, w.discoverySerial == serial, !stopped else { return }
        w.hosts = hosts
        // A service keeps its history while listed; one listed for the first time counts as tried now.
        let now = MonotonicClock.now()
        let listed = Set(hosts.map(\.endpoint))
        w.services = w.services.filter { listed.contains($0.key) }
        for host in hosts where w.services[host.endpoint] == nil { w.services[host.endpoint] = w.newService(seenAt: now) }
        for (id, services) in Dictionary(grouping: hosts, by: \.hostId) where services.count > 1 {
            let names = services.map(\.description).joined(separator: "; ")
            log.notice("Wi-Fi: \(services.count) services claim host \(id, privacy: .public): \(names, privacy: .public)")
        }
        for host in hosts where !PairingAccounts.isCanonicalHostId(host.hostId) {
            log.notice("Wi-Fi: ignoring \(host.description, privacy: .public): not a canonical host id")
        }
        evaluateWiFi()
        publish()
    }

    private func discoveryStateChanged(_ state: DiscoveryState, serial: UInt64) {
        guard let w = wifi, w.discovery != nil, w.discoverySerial == serial, !stopped else { return }
        w.discoveryState = state
        switch state {
        case .searching:
            w.discoveryRetry.reset()
        case .denied:
            log.error("Wi-Fi: Local Network access is off for lain (Settings › Privacy & Security › Local Network)")
        case .failed(let why):
            let delay = w.discoveryRetry.take()
            log.error("Wi-Fi: discovery failed (\(why, privacy: .public)); a new one in \(delay) s")
            stopDiscovery()
            w.discoveryRestartAt = MonotonicClock.now() + Self.ns(delay)
        }
        evaluateWiFi()
        publish()
    }

    private func dial(_ candidate: WiFiDialPlan.Candidate) {
        guard let w = wifi else { return }
        let host = candidate.host, secret = candidate.secret
        w.attempts &+= 1
        let id = w.attempts
        let now = MonotonicClock.now()
        w.services[host.endpoint, default: w.newService(seenAt: now)].lastAttemptAt = now
        // One pairing secret for the TLS PSK and the ChannelHello HMAC: the host refuses a hello under
        // another pairing than its TLS key proved.
        var dialer: any StreamDialer = WiFiLinkDialer(endpoint: host.endpoint, psk: WiFiPSK(secret: secret),
                                                      options: w.config.options, timeout: w.config.dialTimeout)
        if let interpose = w.config.interpose { dialer = interpose(dialer) }
        let links = LinkDialer(dialer: dialer, label: "lain.client.wifi", versions: versions)
        log.notice("Wi-Fi: dialing \(host.description, privacy: .public)")
        let task = Task { [weak self] in
            let result: Result<Link, any Error>
            do {
                result = .success(try await links.open(secret: secret))
            } catch {
                result = .failure(error)
            }
            guard let self else {
                if case .success(let link) = result { link.close() }
                return
            }
            queue.async { self.dialFinished(result, attempt: id) }
        }
        w.dialing = WiFiLoop.Attempt(id: id, host: host, epoch: epoch, task: task)
    }

    private func dialFinished(_ result: Result<Link, any Error>, attempt id: UInt64) {
        guard let w = wifi, let attempt = w.dialing, attempt.id == id else {
            // Abandoned by `stop()`: nothing is installed.
            if case .success(let link) = result {
                log.notice("Wi-Fi: closing a link whose dial finished after the session stopped")
                link.close()
            }
            return
        }
        w.dialing = nil
        switch result {
        case .success(let link):
            w.services[attempt.host.endpoint]?.keyRefusals = 0   // TLS took this iPad's key
            if adoptWiFi(link, host: attempt.host, decidedAt: attempt.epoch) { w.dialDenied = false }
        case .failure(let error as CancellationError):
            log.notice("Wi-Fi: dial to \(attempt.host.name, privacy: .public) cancelled (\(String(describing: error), privacy: .public))")
        case .failure(let error):
            let keyRefused: Bool
            switch error as? NetworkStreamError {
            case .localNetworkDenied?:
                w.dialDenied = true
                keyRefused = false
            case .unknownIdentity?, .wrongKey?:
                keyRefused = true
            default:
                keyRefused = false
            }
            let gap = VersionGap(error, local: versions)
            let delay = penalize(attempt.host, keyRefused: keyRefused, versionGap: gap)
            if let gap { log.error("Wi-Fi: \(attempt.host.name, privacy: .public) shares no protocol version with this iPad: \(String(describing: gap), privacy: .public)") }
            log.notice("Wi-Fi: dialing \(attempt.host.name, privacy: .public) failed (\(String(describing: error), privacy: .public)); that service again in \(delay) s")
            if w.services[attempt.host.endpoint]?.keyRefusals == WiFiLoop.refusedAfter {
                log.error("Wi-Fi: \(attempt.host.name, privacy: .public) keeps refusing this iPad's key: it doesn't hold this pairing (a USB session pairs again)")
            }
        }
        evaluateWiFi()
        publish()
    }

    /// Backs off one service after a failed dial; returns the delay. `keyRefused`: TLS refused this
    /// iPad's key (any other outcome resets the count). A service that keeps refusing it is still
    /// retried, every `maxBackoff`: the Mac may load the key again by itself (it retries a failed read).
    @discardableResult
    private func penalize(_ host: DiscoveredHost, keyRefused: Bool = false, versionGap: VersionGap? = nil) -> Double {
        guard let w = wifi else { return 0 }
        let now = MonotonicClock.now()
        var entry = w.services[host.endpoint] ?? w.newService(seenAt: now)
        entry.keyRefusals = keyRefused ? entry.keyRefusals + 1 : 0
        entry.versionGap = versionGap
        // A Mac on another version won't change until someone updates one side: retry rarely.
        let delay = entry.refusesKey || versionGap != nil ? w.config.maxBackoff : entry.backoff.take()
        entry.until = now + Self.ns(delay)
        w.services[host.endpoint] = entry
        return delay
    }

    /// The loop's one timer: fires at the earliest wait that is due.
    private func wakeWiFi(at deadline: UInt64) {
        guard let w = wifi else { return }
        if w.timer != nil, w.timerAt <= deadline { return }
        w.timer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.wifiTimerFired() }
        w.timer = item
        w.timerAt = deadline
        let now = MonotonicClock.now()
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(deadline > now ? deadline - now : 0)), execute: item)
    }

    private func wifiTimerFired() {
        guard let w = wifi else { return }
        w.timer = nil
        evaluateWiFi()
        publish()
    }

    private func storedSecret(_ account: String) -> [UInt8]? {
        do {
            return try secrets.secret(for: account)
        } catch {
            log.error("Wi-Fi: can't read \(account, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func ns(_ seconds: Double) -> UInt64 { UInt64(Swift.max(seconds, 0) * 1e9) }
}
