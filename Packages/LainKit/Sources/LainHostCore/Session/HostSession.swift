import CoreGraphics
import LainProtocol

extension HelloAck {
    /// The host's answer to `Hello` (§7.5 handshake step 3). `display` is the streamed display (M3: the
    /// lain virtual display) and `chroma` what the video pipeline streams; the audio fields state what
    /// M5 will use. `hostId` and `hostName` say which Mac this is (§7.7 D29: over USB the client keys its
    /// Wi-Fi secret by the id; empty without a host identity).
    public static func host(display: HostDisplay, settings: HostInputSettings, chroma: ChromaFormat = .yuv444,
                            hostId: String = "", hostName: String = "") -> HelloAck {
        HelloAck(codec: .hevc, chroma: chroma, bitDepth: chroma == .yuv444 ? 10 : 8, displayMode: .extend, bitrate: 60_000_000,
                 refreshRate: 120,
                 displayPointWidth: UInt32(max(display.pointSize.width, 0).rounded()),
                 displayPointHeight: UInt32(max(display.pointSize.height, 0).rounded()),
                 audioSampleRate: 48_000, audioChannels: 2, audioEncoding: .pcm16LE,
                 doubleClickIntervalMs: settings.doubleClickIntervalMs, keyRepeatDelayMs: settings.keyRepeatDelayMs,
                 keyRepeatIntervalMs: settings.keyRepeatIntervalMs, macInputSource: settings.inputSourceID,
                 hostId: hostId, hostName: hostName)
    }
}

#if os(macOS)
import Dispatch
import Foundation
import LainTelemetry
import LainTransport
import LainUSBMux
import Synchronization

/// The host runtime (§5.7): watches usbmuxd, dials lain on an attached iPad, starts the session's video
/// (M3: the lain virtual display, captured, encoded and streamed with frame-ack backpressure), answers
/// `Hello`, sends
/// the desktop's `DisplayLayout` (right after `HelloAck`, and again whenever the arrangement changes),
/// routes the client's input into the `InputSink` (global points), answers pings, reflects cursor
/// warps (§5.4, global) and holds the display awake while connected (§5.5 Power). Reconnects on its
/// own when the client comes back (app relaunched, cable replugged).
///
/// With `Dependencies.wifi` it also accepts sessions over Wi-Fi (§7.7 D29): the iPad dials a TLS-PSK
/// listener and the same session runs above the link. One session at a time, owned by a USB connect
/// loop or a Wi-Fi link (`Owner`); USB wins.
///
/// Invariant 3/4: input is handled synchronously on the realtime connection's queue (no awaits, one
/// uncontended lock per message); every session end (link close, USB detach, a USB session taking over
/// from Wi-Fi, `stop()`) calls `sink.releaseAll()` exactly once, after the last input of that session.
public final class HostSession: Sendable {
    public struct Dependencies: Sendable {
        public var usbmux: USBMuxClient
        public var secrets: any SecretStore
        public var sink: any InputSink
        public var display: any DisplayProvider
        public var power: any PowerAssertions
        public var settings: @Sendable () -> HostInputSettings
        /// Monotonic nanoseconds.
        public var now: @Sendable () -> UInt64
        /// Makes one session's video pipeline (`HostVideoPipeline.live()` in the app, fakes in tests).
        /// nil: no video (the M2 input-only session, streaming the main display's geometry).
        public var video: (@Sendable () -> HostVideoPipeline)?
        /// Who this Mac is (§7.7 D29): its id goes in `Pair` and, with the name, in every `HelloAck`, over
        /// USB and Wi-Fi. nil: empty ids (the M1–M4 behaviour).
        public var identity: HostIdentity?
        /// Sessions over Wi-Fi too (§7.7 D29). nil: USB only, exactly as before.
        public var wifi: HostWiFiConfig?

        public init(usbmux: USBMuxClient = USBMuxClient(), secrets: any SecretStore = KeychainSecretStore(),
                    sink: any InputSink, display: any DisplayProvider = DisplayLayoutProvider.system(),
                    power: any PowerAssertions = IOPMPowerAssertions(),
                    settings: @escaping @Sendable () -> HostInputSettings = { .current },
                    now: @escaping @Sendable () -> UInt64 = { MonotonicClock.now() },
                    video: (@Sendable () -> HostVideoPipeline)? = nil,
                    identity: HostIdentity? = nil, wifi: HostWiFiConfig? = nil) {
            self.video = video
            self.usbmux = usbmux
            self.secrets = secrets
            self.sink = sink
            self.display = display
            self.power = power
            self.settings = settings
            self.now = now
            self.identity = identity
            self.wifi = wifi
        }
    }

    public struct Tuning: Sendable {
        /// Real-cursor sampling for warp detection (§5.4).
        public var cursorSampleHz = 60.0
        /// Quick retries right after attach (the client's listener may lag the attach), then slow ones
        /// for as long as the iPad stays attached (lain may not be open yet).
        public var fastRetries = 20
        public var fastRetryInterval: Duration = .milliseconds(100)
        public var slowRetryInterval: Duration = .seconds(1)
        /// If usbmuxd's event stream ends, listen again after this.
        public var usbmuxRetryInterval: Duration = .seconds(1)
        /// `declareUserActivity` at most this often (§5.5 Power).
        public var userActivityIntervalNs: UInt64 = 1_000_000_000
        public var warp = CursorWarpDetector()
        /// How often a live session re-reads the display arrangement (off the realtime queue); a change
        /// (resolution, arrangement, displays added or removed, which one is streamed) is sent as a new
        /// `DisplayLayout`, and the session goes on.
        public var displayCheckIntervalNs: UInt64 = 500_000_000
        /// A session ended by a capture error lets the next one start at once the first time; each
        /// further one in a row waits this long, doubling (capped at 32×), so a recurring capture failure
        /// can't churn the virtual display and window placement in a tight loop. Session-wide: it holds
        /// whichever transport the next session comes over (§7.7 D29). Plugging in the iPad whose sessions
        /// failed is the owner's reset: its count starts over, and it is dialed at once, ahead of a device
        /// that is only waiting the backoff out (one dialing or in a session keeps its turn).
        public var captureRetryInterval: Duration = .seconds(1)
        /// lain on the iPad closing realtime right after our `ChannelHello` this many times in a row is
        /// taken for an app that speaks another protocol (a v1 app closes without answering).
        public var closesBeforeUpdateHint = 3
        /// Tests only: runs in `run()` right after the connection is registered.
        var afterRegistering: (@Sendable () -> Void)?
        public init() {}
    }

    /// Who owns the live session (§7.7 D29 decision 8): a USB connect loop or an accepted Wi-Fi link,
    /// numbered from the one generation counter, so a stale owner can't claim or end a session.
    enum Owner: Equatable, Sendable {
        case usb(generation: UInt64)
        case wifi(generation: UInt64)
    }

    private let deps: Dependencies
    private let tuning: Tuning
    private let onStatus: @Sendable (HostStatus) -> Void
    private let log = Telemetry.logger("session")

    private struct State {
        var status = HostStatus.waitingForIPad
        /// Numbers status changes; only the newest reaches `onStatus` (`publish`).
        var statusSequence: UInt64 = 0
        var started = false
        var stopped = false
        var runTask: Task<Void, Never>?
        /// The USB device being dialed or connected. `generation` identifies its connect loop, so a loop
        /// that has been replaced or cancelled can't register a connection or change the status.
        var device: (id: Int, generation: UInt64, task: Task<Void, Never>)?
        /// The one counter behind USB connect loops and accepted Wi-Fi links (`Owner`).
        var generation: UInt64 = 0
        /// Every USB device usbmuxd reports, in attach order. Only `device` is dialed; the others are
        /// tried when it detaches or lain doesn't answer on it (an iPhone charging, say).
        var attached: [USBMuxDevice] = []
        /// When each attached device's USB attempt began (the USB preference window, decision 8): its
        /// attach, its first dial if it waited its turn behind another device, and the end of each of its
        /// USB sessions. Hand-over re-dials leave it alone, so two devices failing over USB in turn can't
        /// keep an iPad's Wi-Fi busy for good.
        var usbSince: [Int: ContinuousClock.Instant] = [:]
        /// Attached devices not dialed since their attach.
        var undialed: Set<Int> = []
        /// The live session: its owner, its connection, what it runs over and the iPad (its USB serial,
        /// the account its secret is stored under).
        var live: (owner: Owner, connection: HostConnection, transport: LinkTransport, peer: String)?
        /// The live session's device model once its `HelloAck` went out: the status says connected.
        var liveModel: String?
        /// The newest accepted Wi-Fi link's task: its `Hello` wait, then its session.
        var wifi: (generation: UInt64, task: Task<Void, Never>)?
        /// The Wi-Fi link source, for the session's lifetime (without `Dependencies.wifi`, none).
        var acceptor: LinkAcceptor?
        var wifiListener: HostWiFiListener?
        /// The latest session's video pipeline, for the menu.
        var video: HostVideoPipeline?
        /// Every claimed session's pipeline until that session has waited out its teardown (capture
        /// stopped, virtual display removed): a new session waits for all of them before creating its own
        /// display, including one whose session was displaced before it got to wait (one lain display at a
        /// time: they share the persistent identity).
        var retiring: [HostVideoPipeline] = []
        /// Why the latest session has no video (Screen Recording missing, say), for the menu.
        var videoError: String?
        /// Sessions ended by a capture error in a row, over either transport, and when the next one may
        /// start (`Tuning.captureRetryInterval`).
        var captureFailures = 0
        var captureBackoffUntil: ContinuousClock.Instant?
        /// The iPad (its USB serial, the account its secret is stored under) whose session ended the
        /// latest capture failure: plugging it in resets the backoff.
        var captureFailedPeer: String?
        /// The USB connect loop (its generation) waiting out the capture backoff, asleep with no link: the
        /// status says so, and the owner's reset goes ahead of it (`attached`).
        var backingOff: UInt64?
        /// usbmuxd's event stream failed; cleared by the next attach it reports.
        var usbmuxDown = false
        /// lain on the iPad speaks another protocol (§7.7 D29 decision 4); cleared by the next link that
        /// comes up, or when the device dialed detaches.
        var peerOutdated = false

        /// The status is derived, never pushed (decision 8): connected only while the session whose
        /// `HelloAck` went out is live; otherwise what the USB side is doing.
        var derivedStatus: HostStatus {
            if let live, let model = liveModel { return .connected(deviceModel: model, via: live.transport) }
            if usbmuxDown { return .error("usbmuxd unavailable") }
            if peerOutdated { return HostStatus.iPadNeedsUpdate }
            guard let device else { return .waitingForIPad }
            return backingOff == device.generation ? HostStatus.captureBackingOff : .connecting
        }

        /// Recomputes the status: the new one, numbered, if it changed. Once stopped, only
        /// `.waitingForIPad` is taken.
        mutating func refreshStatus() -> (status: HostStatus, sequence: UInt64)? {
            let new = derivedStatus
            guard status != new, !stopped || new == .waitingForIPad else { return nil }
            status = new
            statusSequence &+= 1
            return (new, statusSequence)
        }

        /// Registers `connection` as the live session for `owner` (decision 8). Refused (nil) when the
        /// session is stopped, the claiming task cancelled, or the owner stale: `.usb(g)` needs its connect
        /// loop to still own the device; `.wifi(g)` needs to be the newest accepted link, with no USB session
        /// live. A USB claim displaces a live Wi-Fi session; a Wi-Fi claim displaces an older Wi-Fi session
        /// (the same iPad's: another iPad's link was answered `busy` first). The displaced session's video
        /// stops here, so a claim right after this one finds its teardown under way; the claimer then
        /// finishes the displaced connection and waits for every pipeline in `previousVideo` (`serve`).
        mutating func claim(_ connection: HostConnection, _ owner: Owner, transport: LinkTransport, peer: String)
            -> (displaced: HostConnection?, previousVideo: [HostVideoPipeline])? {
            guard !stopped, !Task.isCancelled else { return nil }
            switch owner {
            case .usb(let g):
                guard device?.generation == g else { return nil }
            case .wifi(let g):
                guard wifi?.generation == g else { return nil }
                if case .usb? = live?.owner { return nil }
            }
            let displaced = live?.connection
            displaced?.video?.stop()   // now, not once the claimer finishes it: synchronous, never takes this lock
            live = (owner, connection, transport, peer)
            liveModel = nil
            let previousVideo = retiring
            if let v = connection.video {
                retiring.append(v)
                video = v
                videoError = nil
            }
            return (displaced, previousVideo)
        }

        /// The live connection if `owner` owns it, taken out (detach, re-attach and a usbmuxd restart end
        /// only their own loop's session: an iPhone coming and going leaves a Wi-Fi session alone).
        mutating func takeLive(ownedBy owner: Owner) -> HostConnection? {
            guard let current = live, current.owner == owner else { return nil }
            live = nil
            liveModel = nil
            return current.connection
        }

        /// Why a Wi-Fi link from `peer` may not start a session now (answered `Error(busy)`), or nil.
        /// USB wins: a live USB session, or this iPad attached over USB with its connect loop younger than
        /// `preference`; the capture backoff holds every transport; and one iPad at a time.
        func wifiBusy(peer: String, now: ContinuousClock.Instant, preference: Duration) -> String? {
            if case .usb? = live?.owner { return "a USB session is live" }
            if let until = captureBackoffUntil, now < until { return "backing off after capture failures" }
            for d in attached where d.serialNumber == peer {
                if let since = usbSince[d.deviceID], now - since < preference { return "this iPad is on USB" }
            }
            if let live, live.peer != peer { return "another iPad is connected" }
            return nil
        }

        /// The session-wide capture backoff, when `peer`'s session has ended.
        mutating func sessionEnded(peer: String, captureFailed: Bool, retryInterval: Duration) {
            guard captureFailed else {
                captureFailures = 0
                captureFailedPeer = nil
                return
            }
            captureFailures += 1
            captureFailedPeer = peer
            guard captureFailures > 1 else { return }
            captureBackoffUntil = .now + retryInterval * (1 << min(captureFailures - 2, 5))
        }

        /// The owner plugged in the iPad whose sessions kept failing capture: its next session starts at
        /// once, and the count starts over.
        mutating func resetCaptureBackoff() {
            captureFailures = 0
            captureBackoffUntil = nil
            captureFailedPeer = nil
        }
    }
    private let state = Mutex(State())
    /// The sequence number of the last status delivered to `onStatus`.
    private let published = Mutex<UInt64>(0)

    public init(dependencies: Dependencies, tuning: Tuning = Tuning(),
                onStatus: @escaping @Sendable (HostStatus) -> Void = { _ in }) {
        deps = dependencies
        self.tuning = tuning
        self.onStatus = onStatus
    }

    public var status: HostStatus { state.withLock { $0.status } }

    /// The live session's video numbers (nil when no session has video).
    public var videoStats: HostVideoStats? {
        state.withLock { s in s.live != nil ? s.video : nil }.flatMap { $0.isRunning ? $0.stats : nil }
    }

    /// Why the current session streams no video, if it failed to start.
    public var videoError: String? { state.withLock { $0.videoError } }

    /// The Wi-Fi listener, for the menu (§7.7 D29 decision 9).
    public var wifiStatus: HostWiFiStatus {
        guard deps.wifi != nil else { return .off("not enabled") }
        return state.withLock { $0.wifiListener }?.status ?? .off("not started")
    }

    /// The Wi-Fi listener's port while it listens (tests dial it on loopback).
    public var wifiPort: UInt16? { state.withLock { $0.wifiListener }?.port }

    /// Tests: an accepted Wi-Fi link is waiting for its `Hello` or running a session.
    var hasWiFiLink: Bool { state.withLock { $0.wifi != nil } }

    /// Tests: the USB device whose connect loop runs.
    var usbDeviceDialed: Int? { state.withLock { $0.device?.id } }

    /// Tests: that connect loop's generation (a re-attach or a usbmuxd restart starts a new one).
    var usbConnectLoop: UInt64? { state.withLock { $0.device?.generation } }

    /// Tests: Wi-Fi listeners created so far.
    var wifiListenerStarts: Int { state.withLock { $0.wifiListener }?.starts ?? 0 }

    /// Starts watching usbmuxd and, with `Dependencies.wifi`, listening for Wi-Fi links (once an iPad
    /// has paired). Idempotent.
    public func start() {
        let (go, wifi, initial) = state.withLock { s -> (Bool, HostWiFiListener?, (status: HostStatus, sequence: UInt64)?) in
            guard !s.started, !s.stopped else { return (false, nil, nil) }
            s.started = true
            if let config = deps.wifi {
                // One acceptor for the session's lifetime: candidates are every stored iPad secret (no
                // primary account), and wireless never pairs (D13).
                let acceptor = LinkAcceptor(secrets: deps.secrets, label: "lain.host.wifi",
                                            onReject: { [weak self] error in self?.wifiRefused(error) },
                                            onLink: { [weak self] accepted in self?.wifiAccepted(accepted) })
                s.acceptor = acceptor
                s.wifiListener = HostWiFiListener(config: config, secrets: deps.secrets, identity: deps.identity,
                                                  onAccept: { acceptor.accept($0) })
            }
            // Numbered before anything can change it: a newer status always wins over this one.
            s.statusSequence &+= 1
            return (true, s.wifiListener, (s.status, s.statusSequence))
        }
        guard go else { return }
        let task = Task { [self] in await watchUSB() }
        state.withLock { s in if s.stopped { task.cancel() } else { s.runTask = task } }
        publish(initial)
        if let wifi { Task { wifi.refresh() } }   // the Keychain read stays off the caller's thread
    }

    /// Ends everything: releases all input (invariant 4) and the power assertion before returning, and
    /// stops listening for Wi-Fi.
    public func stop() {
        let (run, device, connection, wifi, listener, acceptor) = state.withLock { s in
            s.stopped = true
            defer {
                s.runTask = nil; s.device = nil; s.live = nil; s.liveModel = nil; s.attached = []; s.usbSince = [:]
                s.undialed = []; s.wifi = nil
            }
            return (s.runTask, s.device?.task, s.live?.connection, s.wifi?.task, s.wifiListener, s.acceptor)
        }
        run?.cancel()
        device?.cancel()
        wifi?.cancel()   // a link waiting for its Hello is closed by the cancellation
        listener?.cancel()
        acceptor?.cancel()
        connection?.finish()
    }

    /// Delivers status changes in order: one computed before a newer one that already went out is
    /// dropped, so a finished session's late status can't overwrite the current one.
    private func publish(_ change: (status: HostStatus, sequence: UInt64)?) {
        guard let change else { return }
        published.withLock { last in
            guard change.sequence > last else { return }
            last = change.sequence
            onStatus(change.status)
        }
    }

    private func updateStatus(_ update: (inout State) -> Void) {
        publish(state.withLock { s in
            update(&s)
            return s.refreshStatus()
        })
    }

    // MARK: usbmuxd

    private func watchUSB() async {
        while !Task.isCancelled {
            do {
                for try await event in deps.usbmux.events() {
                    switch event {
                    case .attached(let device): attached(device)
                    case .detached(let id): detached(id)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                log.error("usbmuxd events failed: \(String(describing: error), privacy: .public)")
                updateStatus { $0.usbmuxDown = true }
            }
            if Task.isCancelled { return }
            // The daemon went away (restart?): forget the devices; their events will be replayed.
            let active = state.withLock { s -> Int? in
                s.attached.removeAll()
                s.usbSince.removeAll()
                s.undialed.removeAll()
                return s.device?.id
            }
            if let active { detached(active) }
            try? await Task.sleep(for: tuning.usbmuxRetryInterval)
        }
    }

    private func attached(_ device: USBMuxDevice) {
        let now = ContinuousClock.now
        let (replaced, ahead, change) = state.withLock {
            s -> ((task: Task<Void, Never>, connection: HostConnection?)??, Int?, (status: HostStatus, sequence: UInt64)?) in
            guard !s.stopped else { return (.none, nil, nil) }
            s.usbmuxDown = false
            s.attached.removeAll { $0.deviceID == device.deviceID }
            s.attached.append(device)
            s.usbSince[device.deviceID] = now
            s.undialed.insert(device.deviceID)
            // Plugging in the iPad whose sessions kept failing capture is the owner's reset, even when it waits
            // its turn. Automatic redials, the next device in line and Wi-Fi links still wait the backoff out.
            let ownersReset = device.serialNumber == s.captureFailedPeer
            if ownersReset { s.resetCaptureBackoff() }
            // One iPad at a time: another device waits its turn; the same one re-attaching replaces itself.
            // The owner's reset goes ahead of a device whose loop is only waiting the backoff out (asleep: no
            // link, no handshake), which would sleep until the old deadline; that device keeps its place in line.
            var ahead: Int?
            if let current = s.device, current.id != device.deviceID {
                guard ownersReset, s.backingOff == current.generation else { return (.none, nil, s.refreshStatus()) }
                ahead = current.id
            }
            let previous = s.device.map { d in (d.task, s.takeLive(ownedBy: .usb(generation: d.generation))) }
            dial(device, in: &s)
            return (.some(previous), ahead, s.refreshStatus())
        }
        guard let replaced else {
            publish(change)
            log.notice("device \(device.deviceID) attached; waiting its turn (another device is in use)")
            return
        }
        if let replaced {
            replaced.task.cancel()
            replaced.connection?.finish()   // before the new loop can connect: the sink and power are shared
        }
        publish(change)
        if let ahead {
            log.notice("iPad attached: device \(device.deviceID), dialed ahead of device \(ahead) (waiting out the capture backoff)")
        } else {
            log.notice("iPad attached: device \(device.deviceID)")
        }
    }

    private func detached(_ id: Int) {
        let (task, connection, next, change) = state.withLock {
            s -> (Task<Void, Never>?, HostConnection?, Int?, (status: HostStatus, sequence: UInt64)?) in
            s.attached.removeAll { $0.deviceID == id }
            s.usbSince[id] = nil
            s.undialed.remove(id)
            guard let current = s.device, current.id == id else { return (nil, nil, nil, nil) }
            // Only this loop's session ends; a Wi-Fi session goes on (§7.7 D29 decision 8).
            let connection = s.takeLive(ownedBy: .usb(generation: current.generation))
            s.device = nil
            s.peerOutdated = false
            var next: Int?
            if !s.stopped, let first = s.attached.first {
                dial(first, in: &s)
                next = first.deviceID
            }
            return (current.task, connection, next, s.refreshStatus())
        }
        guard let task else { return }
        log.notice("iPad detached: device \(id)")
        task.cancel()
        connection?.finish()   // release now; don't wait for the socket to notice
        if let next { log.notice("trying device \(next)") }
        publish(change)
    }

    /// Starts the connect loop for `device` (under `state`). Its first dial since its attach restarts its USB
    /// preference window (it may have waited its turn behind another device); a hand-over back to it
    /// doesn't.
    private func dial(_ device: USBMuxDevice, in s: inout State) {
        s.generation &+= 1
        let generation = s.generation
        if s.undialed.remove(device.deviceID) != nil { s.usbSince[device.deviceID] = .now }
        s.device = (device.deviceID, generation, Task { [self] in await connectLoop(device, generation: generation) })
    }

    /// lain didn't answer on the current device: if another device is attached, dial that one instead
    /// (this one goes to the back of the line). Returns whether it handed off.
    private func handOff(from device: USBMuxDevice, generation: UInt64) -> Bool {
        state.withLock { s -> Bool in
            guard !s.stopped, s.device?.generation == generation, s.attached.count > 1,
                  let i = s.attached.firstIndex(where: { $0.deviceID == device.deviceID }) else { return false }
            s.attached.append(s.attached.remove(at: i))
            dial(s.attached[0], in: &s)
            return true
        }
    }

    // MARK: USB connection

    private func connectLoop(_ device: USBMuxDevice, generation: UInt64) async {
        var failures = 0
        var closedInARow = 0
        while !Task.isCancelled {
            // No session starts inside the session-wide capture backoff, whatever its transport.
            await waitOutCaptureBackoff(generation: generation)
            if Task.isCancelled { return }
            do {
                let (link, hello, paired) = try await HostLink.open(
                    dialer: USBMuxDialer(client: deps.usbmux, deviceID: device.deviceID), secrets: deps.secrets,
                    peerID: device.serialNumber, allowPairing: true, hostId: deps.identity?.id ?? "")
                if Task.isCancelled { link.close(); return }
                failures = 0
                closedInARow = 0
                log.notice("link up with \(hello.deviceModel, privacy: .public) (\(paired ? "paired" : "authenticated", privacy: .public))")
                updateStatus { $0.peerOutdated = false }
                // A pairing (this one, or a bench's in another process) may have changed the stored
                // secrets: the Wi-Fi listener re-reads them after every USB link-up (§7.7 D29 decision 9).
                state.withLock { $0.wifiListener }?.refresh()
                let served = await run(link, hello: hello, generation: generation, peer: device.serialNumber)
                // USB answered: the preference window restarts. A session restarted it as it ended (`serve`);
                // a link turned away before serving restarts it here.
                if !served {
                    state.withLock { s in if s.device?.generation == generation { s.usbSince[device.deviceID] = .now } }
                }
            } catch {
                if Task.isCancelled { return }
                failures += 1
                closedInARow = noteUSBFailure(error, closedInARow: closedInARow)
                if failures == tuning.fastRetries + 1 {
                    log.notice("still can't reach lain on device \(device.deviceID): \(String(describing: error), privacy: .public)")
                }
                if failures > tuning.fastRetries, handOff(from: device, generation: generation) { return }
                try? await Task.sleep(for: failures <= tuning.fastRetries ? tuning.fastRetryInterval : tuning.slowRetryInterval)
            }
        }
    }

    /// A failed USB link attempt: lain on the iPad speaks another protocol if it said so
    /// (`versionMismatch`) or if it keeps closing realtime right after our `ChannelHello` (a v1 app
    /// can't parse it and closes without a word). Returns the updated count of such closes in a row.
    private func noteUSBFailure(_ error: any Error, closedInARow: Int) -> Int {
        switch error as? TransportError {
        case .versionMismatch?:
            log.error("lain on the iPad speaks another protocol: \(String(describing: error), privacy: .public)")
            updateStatus { $0.peerOutdated = true }
            return 0
        case .closed?:
            let count = closedInARow + 1
            if count == tuning.closesBeforeUpdateHint {
                log.error("lain on the iPad closed the link right after ChannelHello \(count) times: another protocol?")
            }
            if count >= tuning.closesBeforeUpdateHint { updateStatus { $0.peerOutdated = true } }
            return count
        default:
            return 0
        }
    }

    /// Sleeps until the session-wide capture backoff is over. Meanwhile the status says so (instead of
    /// "open lain on the iPad"), for as long as this loop's device is the one dialed.
    private func waitOutCaptureBackoff(generation: UInt64) async {
        while !Task.isCancelled {
            var until: ContinuousClock.Instant?
            updateStatus { s in
                if let u = s.captureBackoffUntil, ContinuousClock.now < u, s.device?.generation == generation {
                    until = u
                    s.backingOff = generation
                } else if s.backingOff == generation {
                    s.backingOff = nil
                }
            }
            guard let until else { return }
            try? await Task.sleep(until: until, clock: .continuous)
        }
        updateStatus { s in if s.backingOff == generation { s.backingOff = nil } }
    }

    /// One USB session; returns when it has ended and been torn down: true, or false if the link was
    /// turned away before serving (another protocol, or the claim refused).
    private func run(_ link: Link, hello: Hello, generation: UInt64, peer: String) async -> Bool {
        guard acceptsVersion(of: hello, on: link) else { return false }
        let connection = makeConnection(link)
        let (claimed, change) = state.withLock { s in
            (s.claim(connection, .usb(generation: generation), transport: link.transport, peer: peer), s.refreshStatus())
        }
        publish(change)
        guard let claimed else {
            link.close()
            return false
        }
        tuning.afterRegistering?()
        await serve(connection, hello: hello, peer: peer, displaced: claimed.displaced, previousVideo: claimed.previousVideo)
        return true
    }

    // MARK: Wi-Fi connection

    /// A link the Wi-Fi acceptor authenticated (on its queue). The newest link takes the Wi-Fi slot: an
    /// older one still waiting for its `Hello` is dropped (closed); a live Wi-Fi session is left for the
    /// decision after this link's `Hello`.
    private func wifiAccepted(_ accepted: AcceptedLink) {
        let admitted = state.withLock { s -> Bool in
            guard !s.stopped else { return false }
            s.generation &+= 1
            let generation = s.generation
            if let previous = s.wifi, s.live?.owner != .wifi(generation: previous.generation) { previous.task.cancel() }
            s.wifi = (generation, Task { [self] in await wifiSession(accepted, generation: generation) })
            return true
        }
        guard admitted else { return accepted.link.close() }
        log.notice("Wi-Fi link from \(accepted.peer, privacy: .public) over \(accepted.link.transport.menuName, privacy: .public)")
    }

    /// A connection the Wi-Fi acceptor refused (after TLS, so a paired iPad): one on another protocol
    /// is worth telling the owner about.
    private func wifiRefused(_ error: any Error) {
        guard case .versionMismatch? = error as? TransportError else { return }
        updateStatus { $0.peerOutdated = true }
    }

    /// One accepted Wi-Fi link (§7.7 D29 decision 8): the client's `Hello` within `helloTimeout`, then,
    /// under the lock, a close (stopped or superseded), `Error(busy)` (`State.wifiBusy`) or a claim, and
    /// its session.
    private func wifiSession(_ accepted: AcceptedLink, generation: UInt64) async {
        guard let config = deps.wifi else { return }
        let link = accepted.link, peer = accepted.peer
        defer { state.withLock { s in if s.wifi?.generation == generation { s.wifi = nil } } }
        let hello: Hello
        do {
            // `next` ignores task cancellation: a cancel (stop, a newer link) closes the link, which ends it.
            let first = try await withTaskCancellationHandler {
                try await link.realtime.next(timeoutSeconds: config.helloTimeout)
            } onCancel: {
                link.close()
            }
            guard case .hello(let h) = first.message else {
                log.error("Wi-Fi link from \(peer, privacy: .public) sent \(String(describing: first.message.type), privacy: .public) before Hello")
                return link.close()
            }
            hello = h
        } catch {
            if case .versionMismatch? = error as? TransportError { updateStatus { $0.peerOutdated = true } }
            log.notice("Wi-Fi link from \(peer, privacy: .public) ended before its Hello: \(String(describing: error), privacy: .public)")
            return link.close()
        }
        guard acceptsVersion(of: hello, on: link) else { return }

        enum Admission: Sendable { case refused, busy(String), claimed(displaced: HostConnection?, previousVideo: [HostVideoPipeline]) }
        let connection = makeConnection(link)
        let now = ContinuousClock.now
        let (admission, change) = state.withLock { s -> (Admission, (status: HostStatus, sequence: UInt64)?) in
            guard !s.stopped else { return (.refused, nil) }
            if let why = s.wifiBusy(peer: peer, now: now, preference: config.usbPreference) { return (.busy(why), nil) }
            guard let claimed = s.claim(connection, .wifi(generation: generation), transport: link.transport, peer: peer) else {
                return (.refused, nil)
            }
            s.peerOutdated = false
            return (.claimed(displaced: claimed.displaced, previousVideo: claimed.previousVideo), s.refreshStatus())
        }
        publish(change)
        switch admission {
        case .refused:
            link.close()
        case .busy(let why):
            // Closed only after a short drain, so the client reads the error before the close (and backs
            // off as for busy, not as for a failed link).
            log.notice("Wi-Fi link from \(peer, privacy: .public): busy (\(why, privacy: .public))")
            link.realtime.send(.error(ErrorMessage(code: .busy, message: why)))
            try? await Task.sleep(for: config.busyDrain)
            link.close()
        case .claimed(let displaced, let previousVideo):
            log.notice("Wi-Fi session with \(hello.deviceModel, privacy: .public) (\(peer, privacy: .public))")
            await serve(connection, hello: hello, peer: peer, displaced: displaced, previousVideo: previousVideo)
        }
    }

    // MARK: Session

    /// A `Hello` in another protocol version is answered and closed, and the owner told to update the
    /// iPad (§7.7 D29 decision 4).
    private func acceptsVersion(of hello: Hello, on link: Link) -> Bool {
        guard hello.protocolVersion != LainProtocol.majorVersion else { return true }
        link.realtime.send(.error(ErrorMessage(code: .versionMismatch, message: "host speaks v\(LainProtocol.majorVersion)")))
        link.close()
        updateStatus { $0.peerOutdated = true }
        return false
    }

    private func makeConnection(_ link: Link) -> HostConnection {
        // The streamed display is the session's virtual display once video is up (§5.1); until then, or
        // without video, the provider falls back to the main display.
        let video = deps.video?()
        let provider = video.map { v in deps.display.streaming { v.streamedDisplayID } } ?? deps.display
        return HostConnection(link: link, display: provider.targetDisplay(), provider: provider, video: video,
                              deps: deps, tuning: tuning)
    }

    /// A claimed session of `peer`, over either transport (§7.7 D29 decision 8), strictly in order: the
    /// connection starts (it takes the display-sleep assertion before the displaced session drops its
    /// own, so a hand-over never lets it lapse), the displaced session is finished (its video stops, its
    /// input is released under its lock and its power assertion ends, synchronously), the new client's
    /// keyboard type is set, every earlier session's display is waited out (one lain display at a time:
    /// they share the persistent identity), then video, `HelloAck` and the first layout. Returns when the
    /// session has ended and been torn down.
    private func serve(_ connection: HostConnection, hello: Hello, peer: String, displaced: HostConnection?,
                       previousVideo: [HostVideoPipeline]) async {
        // A detach, stop or takeover from here on finishes `connection`; `start()` then refuses, so the
        // power assertion is only taken by a connection that will also release it.
        let started = connection.start()
        displaced?.finish()
        deps.sink.setKeyboardType(hello.keyboardType)
        if started {
            for video in previousVideo where video !== connection.video { await video.waitUntilStopped() }
        }
        // Taken over (or stopped) while it waited: it never starts its video or answers.
        if started, !connection.isFinished {
            let chroma = await startVideo(connection, hello: hello)
            // HelloAck after video start, so it carries the virtual display's point size and the chroma
            // actually streamed. The first frames may overtake it on the video connection; the client
            // decodes them regardless.
            let display = connection.provider.targetDisplay()
            connection.link.realtime.send(.helloAck(.host(display: display, settings: deps.settings(), chroma: chroma ?? .yuv444,
                                                          hostId: deps.identity?.id ?? "", hostName: deps.identity?.name ?? "")))
            connection.sendLayoutIfChanged()   // the first one always goes
            updateStatus { s in if s.live?.connection === connection { s.liveModel = hello.deviceModel } }
            await withTaskCancellationHandler {
                await connection.run()
            } onCancel: {
                connection.link.close()
            }
        }
        connection.finish()
        let captureFailed = connection.captureFailed.load(ordering: .acquiring)
        updateStatus { s in
            if let live = s.live, live.connection === connection {
                // A USB session's end restarts its iPad's USB preference window in the step that ends it,
                // so a Wi-Fi link decided after the session is gone always sees the new window.
                if case .usb(let g) = live.owner, let d = s.device, d.generation == g { s.usbSince[d.id] = .now }
                s.live = nil
                s.liveModel = nil
            }
            s.sessionEnded(peer: peer, captureFailed: captureFailed, retryInterval: tuning.captureRetryInterval)
        }
        if let video = connection.video {
            await video.waitUntilStopped()
            state.withLock { s in s.retiring.removeAll { $0 === video } }
        }
        log.notice("session ended")
    }

    /// Starts the connection's video, if it has any. Returns the chroma streamed, or nil without video.
    /// A failure (no Screen Recording grant, say) leaves an input-only session on the main display.
    private func startVideo(_ connection: HostConnection, hello: Hello) async -> ChromaFormat? {
        guard let video = connection.video else { return nil }
        let link = connection.link, log = self.log
        do {
            try await video.start(hello: hello, videoChannel: link.video, sendRealtime: { link.realtime.send($0) },
                                  onError: { [weak self, weak connection] error in
                                      if error is CaptureStoppedByUser {
                                          // The owner stopped it: keep the session, input only, until the next attach.
                                          log.notice("video capture stopped by the user; input only until the next attach")
                                          video.stop()
                                          self?.state.withLock { s in if s.video === video { s.videoError = "capture stopped on the Mac" } }
                                          return
                                      }
                                      // Capture stopped on its own: end the session; the reconnect starts afresh.
                                      log.error("video capture stopped: \(String(describing: error), privacy: .public); ending the session")
                                      connection?.captureFailed.store(true, ordering: .releasing)
                                      link.close()
                                  })
            return video.chroma
        } catch HostVideoError.stopped {
            return nil
        } catch {
            log.error("video unavailable: \(String(describing: error), privacy: .public); input only")
            state.withLock { s in if s.video === video { s.videoError = String(describing: error) } }
            // The failed start's display is being removed: HelloAck and the first layout must not see it.
            await video.waitUntilStopped()
            return nil
        }
    }
}

/// One live link: the realtime handler, the warp sampler, layout updates and teardown. Everything that touches the
/// sink happens under `rt`, which only the realtime queue takes (teardown aside), so input handling
/// is uncontended and no input can slip in after `releaseAll`.
final class HostConnection: Sendable {
    let link: Link
    let display: HostDisplay
    /// The session's displays and cursor, with the streamed display bound to `video`'s virtual display.
    let provider: any DisplayProvider
    /// The session's video (M3); stopped by `finish()`.
    let video: HostVideoPipeline?
    /// Capture stopped on its own and closed the link (the connect loop backs off before the next).
    let captureFailed = Atomic<Bool>(false)
    private let deps: HostSession.Dependencies
    private let tuning: HostSession.Tuning
    private let activityQueue = DispatchQueue(label: "lain.host.activity", qos: .utility)
    private let log = Telemetry.logger("session")

    private struct Realtime {
        var router: HostInputRouter
        var warp: CursorWarpDetector
        var lastActivityNs: UInt64?
        /// This connection took the display-sleep assertion (`start()`), so `finish()` must drop it.
        var holdsPower = false
        var finished = false
    }
    private let rt: Mutex<Realtime>
    /// The warp sampler (realtime queue) and the layout check (`layoutQueue`).
    private let timers: Mutex<[any DispatchSourceTimer]> = Mutex([])
    private let layoutQueue = DispatchQueue(label: "lain.host.layout", qos: .utility)
    /// The last `DisplayLayout` sent; taken only by the handshake and the layout check.
    private let lastLayout = Mutex<DisplayLayout?>(nil)
    /// Set once the realtime connection has closed or the session was finished; `waiter` is `run()`.
    private let ended = Mutex<(done: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    init(link: Link, display: HostDisplay, provider: (any DisplayProvider)? = nil, video: HostVideoPipeline? = nil,
         deps: HostSession.Dependencies, tuning: HostSession.Tuning) {
        self.link = link
        self.display = display
        self.provider = provider ?? deps.display
        self.video = video
        self.deps = deps
        self.tuning = tuning
        var warp = tuning.warp
        warp.reset()
        rt = Mutex(Realtime(router: HostInputRouter(sink: deps.sink), warp: warp))
    }

    /// Takes the display-sleep assertion unless the connection has already been finished (a detach or
    /// stop raced the handshake). Returns whether the session should go on.
    func start() -> Bool {
        rt.withLock { s -> Bool in
            guard !s.finished else { return false }
            s.holdsPower = true
            deps.power.beginPreventingDisplaySleep()
            return true
        }
    }

    /// `finish()` has run: a takeover, detach or stop ended the session.
    var isFinished: Bool { rt.withLock { $0.finished } }

    /// Installs the handlers and waits until the realtime connection closes.
    func run() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let alreadyEnded = ended.withLock { e -> Bool in
                if !e.done { e.waiter = c }
                return e.done
            }
            if alreadyEnded { return c.resume() }
            link.realtime.setHandler { [self] env in handle(env) }
            // Frame acks (and any KeyframeRequest) go to the video pipeline, which installed this same
            // routing when it started; without video they're dropped.
            link.video.setHandler { [video] env in video?.handleVideo(env) }
            link.audio.setHandler { _ in }
            // Realtime carries the input: the session ends when it closes, after its last message has
            // been handled. If video or audio drop alone, close the rest shortly after.
            link.realtime.setCloseHandler { [self] _ in signalEnded() }
            for channel in [link.video, link.audio] {
                channel.setCloseHandler { [link] _ in
                    link.realtime.queue.asyncAfter(deadline: .now() + 0.2) { link.close() }
                }
            }
            startTimers()
        }
    }

    private func signalEnded() {
        let waiter = ended.withLock { e in
            defer { e = (true, nil) }
            return e.waiter
        }
        waiter?.resume()
    }

    /// Idempotent teardown: stop video (the virtual display goes in the background), stop sampling,
    /// close the link, release everything, drop the assertion.
    func finish() {
        video?.stop()
        timers.withLock { t in
            for timer in t { timer.cancel() }
            t = []
        }
        link.close()
        let endPower = rt.withLock { s -> Bool in
            guard !s.finished else { return false }
            s.finished = true
            s.router.releaseAll()
            defer { s.holdsPower = false }
            return s.holdsPower
        }
        if endPower { deps.power.endPreventingDisplaySleep() }
        signalEnded()
        // Break the channel → handler → self cycles.
        for channel in link.channels {
            channel.setHandler { _ in }
            channel.setCloseHandler { _ in }
        }
    }

    // MARK: Realtime queue

    private func handle(_ env: Envelope) { handle(env.message) }

    func handle(_ message: Message) {
        switch message {
        case .ping(let p):
            let received = deps.now()
            link.realtime.send(.pong(Pong(id: p.id, pingSentAtNs: p.sentAtNs, receivedAtNs: received, sentAtNs: deps.now())))
            return
        case .keyframeRequest(let r):
            // D22: loss recovery (and the client coming back to the foreground) is a keyframe.
            video?.requestKeyframe(reason: r.reason)
            return
        default:
            break
        }
        let now = deps.now()
        let declare = rt.withLock { s -> Bool in
            guard !s.finished else { return false }
            switch s.router.handle(message) {
            case .notInput, .ignored:
                return false
            case .injected(let pointer):
                s.warp.noteInput(pointer: pointer, atNs: now)
            case .released:
                s.warp.noteInput(pointer: nil, atNs: now)
            }
            if let last = s.lastActivityNs, now < last &+ tuning.userActivityIntervalNs { return false }
            s.lastActivityNs = now
            return true
        }
        if declare { activityQueue.async { [deps] in deps.power.declareUserActivity() } }
    }

    private func startTimers() {
        let interval = 1.0 / max(tuning.cursorSampleHz, 1)
        let check = Double(max(tuning.displayCheckIntervalNs, 1_000_000)) / 1e9
        // Created only if they will run: libdispatch traps on releasing a source that was never activated,
        // which a session ended meanwhile (a takeover finishing it, say) would otherwise do.
        let started = timers.withLock { t -> [any DispatchSourceTimer] in
            guard !ended.withLock({ $0.done }) else { return [] }
            let sampler = DispatchSource.makeTimerSource(queue: link.realtime.queue)
            sampler.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
            sampler.setEventHandler { [self] in sampleCursor() }
            // The arrangement is re-read off the realtime queue so input never waits behind CoreGraphics.
            let layout = DispatchSource.makeTimerSource(queue: layoutQueue)
            layout.schedule(deadline: .now() + check, repeating: check, leeway: .milliseconds(20))
            layout.setEventHandler { [self] in sendLayoutIfChanged() }
            t = [sampler, layout]
            return t
        }
        started.forEach { $0.resume() }   // `finish()` may have cancelled them since: that's fine
    }

    /// The real cursor in global points, anywhere on the desktop: a warp for the client when it moved on
    /// its own (§5.4).
    private func sampleCursor() {
        guard let global = provider.cursorLocation() else { return }
        let now = deps.now()
        let warp = rt.withLock { s -> CGPoint? in
            guard !s.finished else { return nil }
            return s.warp.sample(global, atNs: now)
        }
        if let warp { link.realtime.send(.cursorWarp(CursorWarp(x: warp.x, y: warp.y))) }
    }

    // MARK: Layout

    /// Sends the desktop's `DisplayLayout` if it differs from the last one sent (the first always
    /// goes). A resolution change, a display added or removed, a new arrangement or a new streamed
    /// display just updates the client, which re-clamps its cursor; the session goes on.
    func sendLayoutIfChanged() {
        let layout = provider.desktopLayout()
        guard !layout.displays.isEmpty else { return }
        let sent = lastLayout.withLock { last -> Bool in
            guard layout != last, !ended.withLock({ $0.done }) else { return false }
            if last != nil {
                log.notice("display arrangement changed: \(layout.displays.count) display(s); sending the new layout")
            }
            last = layout
            link.realtime.send(.displayLayout(layout))
            return true
        }
        // A warp sent just before this layout was snapped against the old one on the client (the
        // cursor may only exist in the new arrangement): report the cursor again, after the layout.
        if sent { rt.withLock { $0.warp.resync() } }
    }
}
#endif
