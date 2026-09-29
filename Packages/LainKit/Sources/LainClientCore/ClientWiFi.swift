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
    /// advertised twice): this, doubling up to `maxBackoff`.
    public var serviceBackoff = 0.5
    /// A discovery that failed is recreated after this, doubling up to `maxDiscoveryBackoff`.
    public var discoveryBackoff = 1.0
    public var maxDiscoveryBackoff = 30.0
    /// Per connection of a dial.
    public var dialTimeout = NetworkStreamDialer.defaultTimeout
    /// The id of the Mac last connected, preferred when several paired Macs are visible.
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

/// Where the client remembers the Mac it last connected to: `UserDefaults` in the app, memory in tests.
public struct LastConnectedHost: Sendable {
    public var get: @Sendable () -> String?
    public var set: @Sendable (String) -> Void

    public init(get: @escaping @Sendable () -> String?, set: @escaping @Sendable (String) -> Void) {
        self.get = get
        self.set = set
    }

    public static func userDefaults(key: String = "lain.lastHostId") -> LastConnectedHost {
        LastConnectedHost(get: { UserDefaults.standard.string(forKey: key) },
                          set: { UserDefaults.standard.set($0, forKey: key) })
    }

    public static func memory(_ initial: String? = nil) -> LastConnectedHost {
        let box = Box(initial)
        return LastConnectedHost(get: { box.value.withLock { $0 } }, set: { id in box.value.withLock { $0 = id } })
    }

    private final class Box: Sendable {
        let value: Mutex<String?>
        init(_ initial: String?) { value = Mutex(initial) }
    }
}

/// Which discovered Macs the client may dial (§7.7 D29): a canonical host id, the client's protocol
/// major version, and a Wi-Fi secret (`mac:<hostId>`) in the store. Every service of such a Mac is a
/// candidate (one id can be advertised twice, e.g. after a Bonjour rename), the last-connected Mac's
/// first. What can't be dialed is kept, for the status. Hosts with a malformed id are ignored.
struct WiFiDialPlan: Equatable {
    struct Candidate: Equatable {
        var host: DiscoveredHost
        var secret: [UInt8]
    }

    struct OtherVersion: Equatable {
        var host: DiscoveredHost
        /// This iPad holds its secret: probably its own Mac, one side needs an update.
        var paired: Bool
    }

    var candidates: [Candidate] = []
    /// The right version, but no Wi-Fi secret yet: one USB session records it (the migration path).
    var needsCable: [DiscoveredHost] = []
    var otherVersion: [OtherVersion] = []

    init() {}

    /// `secret` reads an account of the client's store.
    init(hosts: [DiscoveredHost], preferring lastHostId: String?, secret: (String) -> [UInt8]?) {
        for host in hosts where PairingAccounts.isCanonicalHostId(host.hostId) {
            let stored = secret(PairingAccounts.mac(host.hostId))
            if host.protocolVersion != LainProtocol.majorVersion {
                otherVersion.append(OtherVersion(host: host, paired: stored != nil))
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
    struct Attempt {
        let id: UInt64
        let host: DiscoveredHost
        /// The session's epoch when the loop decided to dial.
        let epoch: UInt64
        let task: Task<Void, Never>
    }

    struct ServiceBackoff {
        var backoff: Backoff
        /// No dial to the service before this (`MonotonicClock` ns).
        var until: UInt64 = 0
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
    var services: [NWEndpoint: ServiceBackoff] = [:]
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
}

/// The Wi-Fi loop (§7.7 D29), on the session queue: browse while no USB link is current and the scene
/// is in front; dial a paired Mac once no link is current, the grace and backoffs have passed and its
/// service isn't backing off; learn from each link's end. Without a `ClientWiFiConfig` all of it is a
/// no-op.
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

    func sceneEnteredBackground() {
        guard let w = wifi, !stopped else { return }
        w.paused = true
        evaluateWiFi()
        publish()
    }

    /// A link was adopted: the loop stops browsing while it's USB.
    func wifiLinkAdopted(_ via: Via) {
        guard let w = wifi else { return }
        w.busyHost = nil
        if via.isUSB { stopDiscovery() }
    }

    /// A Wi-Fi session got its `HelloAck`: its service is fine.
    func wifiSessionStarted(_ host: DiscoveredHost) {
        wifi?.services[host.endpoint] = nil
    }

    /// The current link ended: when the next dial may happen.
    func wifiLinkEnded(_ via: Via, outcome: LinkOutcome) {
        guard let w = wifi, !stopped else { return }
        let now = MonotonicClock.now()
        switch via {
        case .usb:
            w.graceUntil = now + Self.ns(w.config.grace)
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
        if current?.via.isUSB == true || w.paused {
            stopDiscovery()
        } else if w.discovery == nil {
            if now >= w.discoveryRestartAt { startDiscovery() } else { wakeWiFi(at: w.discoveryRestartAt) }
        }
        w.plan = current == nil && w.discovery != nil
            ? WiFiDialPlan(hosts: w.hosts, preferring: w.config.lastHost.get(), secret: storedSecret)
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
    /// (dialing, refused Local Network access, a busy Mac, a paired Mac it will dial), then the USB
    /// listener's version mismatch, then what it merely saw.
    func wifiStatus() -> ClientSession.Status? {
        guard let w = wifi, current == nil else { return nil }
        if let a = w.dialing { return .connecting(hostName: a.host.name, interfaces: a.host.interfaceNames) }
        if w.paused { return nil }
        if w.discoveryState == .denied || w.dialDenied { return .localNetworkDenied }
        if let busy = w.busyHost, MonotonicClock.now() < w.backoffUntil { return .hostBusy(hostName: busy) }
        if let next = w.plan.candidates.first {
            return .connecting(hostName: next.host.name, interfaces: next.host.interfaceNames)
        }
        if let usbMismatch { return .versionMismatch(hostName: nil, remote: usbMismatch) }
        if let other = w.plan.otherVersion.first(where: \.paired) {
            return .versionMismatch(hostName: other.host.name, remote: other.host.protocolVersion)
        }
        if let host = w.plan.needsCable.first { return .needsCable(hostName: host.name) }
        if let other = w.plan.otherVersion.first {
            return .versionMismatch(hostName: other.host.name, remote: other.host.protocolVersion)
        }
        if w.discovery != nil || w.discoveryRestartAt != 0 { return .searching }
        return nil
    }

    // MARK: Private

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
        // One pairing secret for the TLS PSK and the ChannelHello HMAC: the host refuses a hello under
        // another pairing than its TLS key proved.
        var dialer: any StreamDialer = WiFiLinkDialer(endpoint: host.endpoint, psk: WiFiPSK(secret: secret),
                                                      options: w.config.options, timeout: w.config.dialTimeout)
        if let interpose = w.config.interpose { dialer = interpose(dialer) }
        let links = LinkDialer(dialer: dialer, label: "lain.client.wifi")
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
            if adoptWiFi(link, host: attempt.host, decidedAt: attempt.epoch) { w.dialDenied = false }
        case .failure(let error as CancellationError):
            log.notice("Wi-Fi: dial to \(attempt.host.name, privacy: .public) cancelled (\(String(describing: error), privacy: .public))")
        case .failure(let error):
            if case .localNetworkDenied? = error as? NetworkStreamError { w.dialDenied = true }
            let delay = penalize(attempt.host)
            log.notice("Wi-Fi: dialing \(attempt.host.name, privacy: .public) failed (\(String(describing: error), privacy: .public)); that service again in \(delay) s")
        }
        evaluateWiFi()
        publish()
    }

    /// Backs off one service; returns the delay.
    @discardableResult
    private func penalize(_ host: DiscoveredHost) -> Double {
        guard let w = wifi else { return 0 }
        var entry = w.services[host.endpoint]
            ?? WiFiLoop.ServiceBackoff(backoff: Backoff(initial: w.config.serviceBackoff, max: w.config.maxBackoff))
        let delay = entry.backoff.take()
        entry.until = MonotonicClock.now() + Self.ns(delay)
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
