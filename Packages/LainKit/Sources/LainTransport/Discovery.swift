import Dispatch
import LainTelemetry
import Network
import Synchronization

private let log = Telemetry.logger("wifi")

/// The host's Bonjour TXT record (§7.7, D29): `v` = the protocol major version, `id` = the host id.
public enum LainTXT {
    /// The iPad dials only hosts that speak its major version.
    public static let versionKey = "v"
    /// A canonical UUID; the iPad dials only ids it holds a Wi-Fi secret for (`mac:<id>`).
    public static let hostIdKey = "id"
    /// `bench=1` marks `--bench wifi` (for logs).
    public static let benchKey = "bench"

    public static func dictionary(hostId: String, version: UInt8 = LainProtocol.majorVersion,
                                  bench: Bool = false) -> [String: String] {
        var txt = [versionKey: String(version), hostIdKey: hostId]
        if bench { txt[benchKey] = "1" }
        return txt
    }

    public static func record(hostId: String, version: UInt8 = LainProtocol.majorVersion, bench: Bool = false) -> NWTXTRecord {
        NWTXTRecord(dictionary(hostId: hostId, version: version, bench: bench))
    }
}

/// A lain host seen over Bonjour. Which one to dial (known id, matching version, most recently
/// connected, backoff per service) is the client's policy.
public struct DiscoveredHost: Sendable, Hashable, CustomStringConvertible {
    public var hostId: String
    /// The Bonjour instance name: the Mac's computer name unless renamed after a conflict.
    public var name: String
    /// The TXT `v`; nil if missing or not a number.
    public var protocolVersion: UInt8?
    /// What to dial: the `.service` endpoint, resolved when a connection starts (so a listener that
    /// moved to a new port is still found).
    public var endpoint: NWEndpoint
    /// The interfaces it was seen on (e.g. en0 and awdl0).
    public var interfaceNames: [String]
    public var isBench: Bool

    public init(hostId: String, name: String, protocolVersion: UInt8?, endpoint: NWEndpoint,
                interfaceNames: [String] = [], isBench: Bool = false) {
        self.hostId = hostId
        self.name = name
        self.protocolVersion = protocolVersion
        self.endpoint = endpoint
        self.interfaceNames = interfaceNames
        self.isBench = isBench
    }

    /// Maps one browse result: a pure function of the endpoint, the TXT record and the interface
    /// names. Nil without an `id`: nothing a client could match against its secrets.
    public init?(endpoint: NWEndpoint, txt: [String: String], interfaceNames: [String]) {
        guard let hostId = txt[LainTXT.hostIdKey], !hostId.isEmpty else { return nil }
        let name: String
        if case .service(let serviceName, _, _, _) = endpoint { name = serviceName } else { name = endpoint.debugDescription }
        self.init(hostId: hostId, name: name, protocolVersion: txt[LainTXT.versionKey].flatMap { UInt8($0) },
                  endpoint: endpoint, interfaceNames: interfaceNames, isBench: txt[LainTXT.benchKey] == "1")
    }

    /// For logs: "Mac mini [<id> v2 on en0,awdl0]".
    public var description: String {
        let version = protocolVersion.map { String($0) } ?? "?"
        return "\(name) [\(hostId) v\(version) on \(interfaceNames.joined(separator: ","))\(isBench ? ", bench" : "")]"
    }

    init?(_ result: NWBrowser.Result) {
        let txt: [String: String]
        if case .bonjour(let record) = result.metadata { txt = record.dictionary } else { txt = [:] }
        self.init(endpoint: result.endpoint, txt: txt, interfaceNames: result.interfaces.map(\.name))
    }
}

public enum DiscoveryState: Equatable, Sendable {
    case searching
    /// Local Network access is off for this app (`kDNSServiceErr_PolicyDenied`, -65570).
    case denied
    /// The browser is dead (e.g. mDNSResponder's connection went defunct while suspended): recreate it.
    case failed(String)

    /// Nil for states that change nothing (setup, cancelled). A browser waiting for any other reason
    /// is still searching.
    public init?(_ state: NWBrowser.State) {
        switch state {
        case .ready: self = .searching
        case .waiting(let error): self = NetworkStreamError.classify(error) == .localNetworkDenied ? .denied : .searching
        case .failed(let error):
            self = NetworkStreamError.classify(error) == .localNetworkDenied ? .denied : .failed(error.debugDescription)
        default: return nil
        }
    }
}

/// Finds lain hosts (§7.7). Callbacks run on the discovery's private queue: `onChange` with the full
/// current list each time, `onState` when the search state changes. Nothing is reported after
/// `cancel()`.
public protocol HostDiscovery: AnyObject, Sendable {
    /// Call once.
    func start(onChange: @escaping @Sendable ([DiscoveredHost]) -> Void,
               onState: @escaping @Sendable (DiscoveryState) -> Void)
    func cancel()
}

/// Browses Bonjour for the host service with peer-to-peer on (AWDL as well as the LAN). The apps
/// only: tests never browse. The browser is created at `start`.
public final class BonjourHostDiscovery: HostDiscovery {
    public let serviceType: String
    public let includePeerToPeer: Bool
    private let queue = DispatchQueue(label: "lain.wifi.discovery", qos: .userInitiated)
    private let browser = Mutex<(browser: NWBrowser?, cancelled: Bool)>((nil, false))

    /// `serviceType`: `LainProtocol.bonjourServiceType` ("_lain._tcp").
    public init(serviceType: String, includePeerToPeer: Bool = true) {
        self.serviceType = serviceType
        self.includePeerToPeer = includePeerToPeer
    }

    deinit { cancel() }

    public func start(onChange: @escaping @Sendable ([DiscoveredHost]) -> Void,
                      onState: @escaping @Sendable (DiscoveryState) -> Void) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = includePeerToPeer
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, !isCancelled, let mapped = DiscoveryState(state) else { return }
            log.notice("discovery \(String(describing: mapped), privacy: .public)")
            onState(mapped)
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !isCancelled else { return }
            let hosts = results.compactMap(DiscoveredHost.init).sorted { ($0.name, $0.hostId) < ($1.name, $1.hostId) }
            log.notice("discovered \(hosts.map(\.description).joined(separator: "; "), privacy: .public)")
            onChange(hosts)
        }
        let go = self.browser.withLock { b -> Bool in
            guard b.browser == nil, !b.cancelled else { return false }
            b.browser = browser
            return true
        }
        if go { browser.start(queue: queue) }
    }

    public func cancel() {
        let browser = browser.withLock { b -> NWBrowser? in
            b.cancelled = true
            return b.browser
        }
        browser?.cancel()
    }

    private var isCancelled: Bool { browser.withLock { $0.cancelled } }
}

/// Reports a given list and state, then whatever `update` sets (tests and diagnostics; never browses).
public final class FixedHostDiscovery: HostDiscovery {
    private struct State {
        var hosts: [DiscoveredHost]
        var state: DiscoveryState
        var onChange: (@Sendable ([DiscoveredHost]) -> Void)?
        var onState: (@Sendable (DiscoveryState) -> Void)?
        var starts = 0
        var cancelled = false
    }

    private let queue = DispatchQueue(label: "lain.wifi.discovery.fixed")
    private let state: Mutex<State>

    public init(hosts: [DiscoveredHost] = [], state: DiscoveryState = .searching) {
        self.state = Mutex(State(hosts: hosts, state: state))
    }

    /// Reports the state, then the list.
    public func start(onChange: @escaping @Sendable ([DiscoveredHost]) -> Void,
                      onState: @escaping @Sendable (DiscoveryState) -> Void) {
        state.withLock { s in
            s.starts += 1
            guard !s.cancelled else { return }
            s.onChange = onChange
            s.onState = onState
            let (current, hosts) = (s.state, s.hosts)
            deliver { onState(current); onChange(hosts) }
        }
    }

    public func update(hosts: [DiscoveredHost]) {
        state.withLock { s in
            s.hosts = hosts
            if let onChange = s.onChange { deliver { onChange(hosts) } }
        }
    }

    public func update(state newState: DiscoveryState) {
        state.withLock { s in
            s.state = newState
            if let onState = s.onState { deliver { onState(newState) } }
        }
    }

    public func cancel() {
        state.withLock { s in
            s.cancelled = true
            s.onChange = nil
            s.onState = nil
        }
    }

    public var startCount: Int { state.withLock { $0.starts } }
    public var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Enqueued under the lock, so reports keep their order; dropped if cancelled meanwhile.
    private func deliver(_ report: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if !state.withLock({ $0.cancelled }) { report() }
        }
    }
}
