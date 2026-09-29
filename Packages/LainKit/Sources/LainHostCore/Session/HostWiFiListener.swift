#if os(macOS)
import LainProtocol
import LainTelemetry
import LainTransport
import Synchronization

/// The host's Wi-Fi link source (§7.7 D29). `HostSession.Dependencies.wifi` nil: USB only (M1–M4).
public struct HostWiFiConfig: Sendable {
    /// The listener's parameters: the defaults in the app (wildcard bind, peer-to-peer on), `.loopback`
    /// in tests.
    public var options: NetworkStreamOptions
    /// Advertise Bonjour `_lain._tcp` with TXT `v` and `id` (needs the host identity). The app only:
    /// never tests or the test host (decision 12).
    public var advertise: Bool
    /// USB wins (decision 8): a Wi-Fi link from an iPad that is attached over USB, while its connect loop
    /// is younger than this (dialing since the attach, a hand-over or its last USB session's end, or
    /// waiting behind another device since its attach), is told `busy`. After it, USB counts as broken
    /// and Wi-Fi is let in.
    public var usbPreference: Duration = .seconds(5)
    /// How long an accepted link may take to send `Hello` (`HostLink.handshakeTimeout` over USB).
    public var helloTimeout: Double = HostLink.handshakeTimeout
    /// After `Error(busy)` the link is closed only after this, so the client reads the error first.
    public var busyDrain: Duration = .milliseconds(200)
    /// A failed secret read or a failed listener retries after this, doubling up to `retryMax`.
    public var retryInitial: Duration = .seconds(2)
    public var retryMax: Duration = .seconds(60)
    /// TLS must be done within this (`NetworkStreamListener`).
    public var handshakeTimeout: Double = NetworkStreamListener.handshakeTimeout

    public init(options: NetworkStreamOptions = NetworkStreamOptions(), advertise: Bool) {
        self.options = options
        self.advertise = advertise
    }
}

/// Feeds the session's one `LinkAcceptor` from a TLS-PSK `NetworkStreamListener` holding one PSK per
/// stored iPad secret, `WiFiPSK(secret:)` of every `allSecrets()` entry (§7.7 D29 decision 9). No
/// listener while no iPad has paired. `refresh()` re-reads the secrets and restarts the listener only if
/// the set of PSK identities changed (a restart swaps the listener, not the acceptor: accepted
/// connections are unaffected). A failed read or a failed listener retries with backoff. The listener
/// logs its identities at each start, never the keys. It is created, replaced and cancelled only under
/// the lock, and never once cancelled.
final class HostWiFiListener: Sendable {
    private let config: HostWiFiConfig
    private let secrets: any SecretStore
    private let advertisement: NetworkStreamListener.Advertisement?
    private let onAccept: @Sendable (NetworkStream) -> Void
    private let log = Telemetry.logger("wifi")

    private struct State {
        var cancelled = false
        /// The running listener; `generation` tells its events from a replaced one's.
        var listener: (generation: UInt64, listener: NetworkStreamListener)?
        var generation: UInt64 = 0
        /// The PSK identities of the last successful read (the listener's, while one runs).
        var identities: Set<String> = []
        var status = HostWiFiStatus.starting
        var port: UInt16?
        var name: String?
        var retry: Task<Void, Never>?
        /// The next retry's delay while failures continue; nil once the listener is ready (or needed none).
        var backoff: Duration?
        /// Listeners created so far (tests).
        var starts = 0
    }
    private let state = Mutex(State())

    /// Nothing listens until the first `refresh()`.
    init(config: HostWiFiConfig, secrets: any SecretStore, identity: HostIdentity?,
         onAccept: @escaping @Sendable (NetworkStream) -> Void) {
        self.config = config
        self.secrets = secrets
        self.onAccept = onAccept
        if config.advertise, let identity {
            advertisement = NetworkStreamListener.Advertisement(type: LainProtocol.bonjourServiceType,
                                                                txt: LainTXT.dictionary(hostId: identity.id))
        } else {
            if config.advertise { Telemetry.logger("wifi").error("Wi-Fi: no host id to advertise; listening unadvertised") }
            advertisement = nil
        }
    }

    var status: HostWiFiStatus { state.withLock { $0.status } }

    /// The bound port while listening.
    var port: UInt16? { state.withLock { $0.port } }

    /// Listeners created so far (tests: a refresh with the same keys must not restart it).
    var starts: Int { state.withLock { $0.starts } }

    /// Re-reads the stored secrets: starts the listener if there are some and none runs, restarts it if
    /// the identities changed, stops it if there are none left.
    func refresh() {
        let stored: [String: [UInt8]]
        do {
            stored = try secrets.allSecrets()
        } catch {
            log.error("Wi-Fi: could not read the pairing secrets (\(String(describing: error), privacy: .public)); retrying")
            state.withLock { s in
                guard !s.cancelled else { return }
                if s.listener == nil { s.status = .off("can't read the pairing secrets") }
                retryLater(&s)
            }
            return
        }
        let psks = stored.values.map(WiFiPSK.init(secret:)).sorted { $0.identity < $1.identity }
        let identities = Set(psks.map(\.identity))
        state.withLock { s in
            guard !s.cancelled else { return }
            let changed = identities != s.identities
            s.identities = identities
            if !changed, s.listener != nil {
                s.backoff = nil   // the read works and the listener runs: nothing is failing
                return
            }
            if changed {
                let what = identities.isEmpty ? "stopping" : s.listener == nil ? "starting" : "restarting"
                log.notice("Wi-Fi: \(identities.count) paired iPad(s); \(what, privacy: .public) the listener")
            }
            s.listener?.listener.cancel()
            s.listener = nil
            s.port = nil
            s.name = nil
            guard !identities.isEmpty else {
                s.status = .off("no paired iPad yet")
                s.backoff = nil
                return
            }
            s.generation &+= 1
            let generation = s.generation
            do {
                let listener = try NetworkStreamListener(
                    psks: psks, options: config.options, advertisement: advertisement,
                    handshakeTimeout: config.handshakeTimeout,
                    onEvent: { [weak self] event in self?.handle(event, generation: generation) }, onAccept: onAccept)
                s.listener = (generation, listener)
                s.status = .starting
                s.starts += 1
            } catch {
                log.error("Wi-Fi listener could not start: \(String(describing: error), privacy: .public)")
                s.status = .failed(String(describing: error))
                retryLater(&s)
            }
        }
    }

    /// Stops listening for good (`HostSession.stop()`); a pending retry is cancelled.
    func cancel() {
        state.withLock { s in
            s.cancelled = true
            s.retry?.cancel()
            s.retry = nil
            s.listener?.listener.cancel()
            s.listener = nil
            s.port = nil
            s.status = .off("stopped")
        }
    }

    /// The listener's queue.
    private func handle(_ event: NetworkStreamListener.Event, generation: UInt64) {
        state.withLock { s in
            guard !s.cancelled, s.listener?.generation == generation else { return }
            switch event {
            case .state(.ready(let port)):
                s.port = port
                s.backoff = nil
                s.status = .advertising(name: s.name, port: port, pairedCount: s.identities.count)
            case .state(.waiting(.localNetworkDenied)):
                s.status = .denied
            case .state(.waiting(let error)):
                s.status = .off("waiting for the network (\(error))")
            case .state(.failed(let error)):
                // Dead: a new listener after the backoff (the next `refresh` sees none running).
                log.error("Wi-Fi listener failed: \(String(describing: error), privacy: .public); restarting with backoff")
                s.listener?.listener.cancel()
                s.listener = nil
                s.port = nil
                s.name = nil
                s.status = .failed(String(describing: error))
                retryLater(&s)
            case .registered(let name):
                s.name = name
                if case .advertising(_, let port, let count) = s.status {
                    s.status = .advertising(name: name, port: port, pairedCount: count)
                }
            case .unregistered(let name):
                guard s.name == name else { break }
                s.name = nil
                if case .advertising(_, let port, let count) = s.status {
                    s.status = .advertising(name: nil, port: port, pairedCount: count)
                }
            case .state(.setup), .state(.cancelled), .rejected:
                break
            }
        }
    }

    /// Schedules a `refresh()` after the backoff (under the lock), unless one is pending.
    private func retryLater(_ s: inout State) {
        guard !s.cancelled, s.retry == nil else { return }
        let delay = s.backoff ?? config.retryInitial
        s.backoff = min(delay * 2, config.retryMax)
        s.retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            state.withLock { $0.retry = nil }
            refresh()
        }
    }
}
#endif
