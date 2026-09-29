import CoreGraphics
import LainProtocol

extension HelloAck {
    /// The host's answer to `Hello` (§7.5 handshake step 3). M2 streams no video yet; the codec,
    /// display-mode, bitrate and audio fields state what M3–M5 will use.
    public static func host(display: HostDisplay, settings: HostInputSettings) -> HelloAck {
        HelloAck(codec: .hevc, chroma: .yuv444, bitDepth: 10, displayMode: .extend, bitrate: 60_000_000,
                 refreshRate: 120,
                 displayPointWidth: UInt32(max(display.pointSize.width, 0).rounded()),
                 displayPointHeight: UInt32(max(display.pointSize.height, 0).rounded()),
                 audioSampleRate: 48_000, audioChannels: 2, audioEncoding: .pcm16LE,
                 doubleClickIntervalMs: settings.doubleClickIntervalMs, keyRepeatDelayMs: settings.keyRepeatDelayMs,
                 keyRepeatIntervalMs: settings.keyRepeatIntervalMs, macInputSource: settings.inputSourceID)
    }
}

#if os(macOS)
import Dispatch
import Foundation
import LainTelemetry
import LainTransport
import LainUSBMux
import Synchronization

/// The M2 host runtime (§5.7): watches usbmuxd, dials lain on an attached iPad, answers `Hello`,
/// routes the client's input into the `InputSink`, answers pings, reflects cursor warps (§5.4) and
/// holds the display awake while connected (§5.5 Power). Reconnects on its own when the client comes
/// back (app relaunched, cable replugged).
///
/// Invariant 3/4: input is handled synchronously on the realtime connection's queue (no awaits, one
/// uncontended lock per message); every session end (link close, USB detach, `stop()`) calls
/// `sink.releaseAll()` exactly once, after the last input of that session.
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

        public init(usbmux: USBMuxClient = USBMuxClient(), secrets: any SecretStore = KeychainSecretStore(),
                    sink: any InputSink, display: any DisplayProvider = MainDisplayProvider(),
                    power: any PowerAssertions = IOPMPowerAssertions(),
                    settings: @escaping @Sendable () -> HostInputSettings = { .current },
                    now: @escaping @Sendable () -> UInt64 = { MonotonicClock.now() }) {
            self.usbmux = usbmux
            self.secrets = secrets
            self.sink = sink
            self.display = display
            self.power = power
            self.settings = settings
            self.now = now
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
        public init() {}
    }

    private let deps: Dependencies
    private let tuning: Tuning
    private let onStatus: @Sendable (HostStatus) -> Void
    private let log = Telemetry.logger("session")

    private struct State {
        var status = HostStatus.waitingForIPad
        var started = false
        var stopped = false
        var runTask: Task<Void, Never>?
        var device: (id: Int, task: Task<Void, Never>)?
        var connection: HostConnection?
    }
    private let state = Mutex(State())

    public init(dependencies: Dependencies, tuning: Tuning = Tuning(),
                onStatus: @escaping @Sendable (HostStatus) -> Void = { _ in }) {
        deps = dependencies
        self.tuning = tuning
        self.onStatus = onStatus
    }

    public var status: HostStatus { state.withLock { $0.status } }

    /// Starts watching usbmuxd. Idempotent.
    public func start() {
        let go = state.withLock { s -> Bool in
            guard !s.started, !s.stopped else { return false }
            s.started = true
            return true
        }
        guard go else { return }
        let task = Task { [self] in await watchUSB() }
        state.withLock { $0.runTask = task }
        onStatus(.waitingForIPad)
    }

    /// Ends everything: releases all input (invariant 4) and the power assertion before returning.
    public func stop() {
        let (run, device, connection) = state.withLock { s in
            s.stopped = true
            defer { s.runTask = nil; s.device = nil; s.connection = nil }
            return (s.runTask, s.device, s.connection)
        }
        run?.cancel()
        device?.task.cancel()
        connection?.finish()
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
                setStatus(.error("usbmuxd unavailable"))
            }
            if Task.isCancelled { return }
            // The daemon went away (restart?): forget the device; its events will be replayed.
            if let id = state.withLock({ $0.device?.id }) { detached(id) }
            try? await Task.sleep(for: tuning.usbmuxRetryInterval)
        }
    }

    private func attached(_ device: USBMuxDevice) {
        let previous = state.withLock { s -> (id: Int, task: Task<Void, Never>)?? in
            guard !s.stopped else { return .none }
            // One iPad at a time: a second one is ignored; the same one re-attaching replaces itself.
            if let current = s.device, current.id != device.deviceID { return .none }
            let previous = s.device
            s.device = (device.deviceID, Task { [self] in await connectLoop(device) })
            return .some(previous)
        }
        guard let previous else {
            log.notice("ignoring device \(device.deviceID): another iPad is in use")
            return
        }
        previous?.task.cancel()
        log.notice("iPad attached: device \(device.deviceID)")
    }

    private func detached(_ id: Int) {
        let (task, connection) = state.withLock { s -> (Task<Void, Never>?, HostConnection?) in
            guard s.device?.id == id else { return (nil, nil) }
            defer { s.device = nil }
            return (s.device?.task, s.connection)
        }
        guard let task else { return }
        log.notice("iPad detached: device \(id)")
        task.cancel()
        connection?.finish()   // release now; don't wait for the socket to notice
        setStatus(.waitingForIPad)
    }

    // MARK: Connection

    private func connectLoop(_ device: USBMuxDevice) async {
        var failures = 0
        while !Task.isCancelled {
            setStatus(.connecting)
            do {
                let (link, hello, paired) = try await HostLink.open(
                    dialer: USBMuxDialer(client: deps.usbmux, deviceID: device.deviceID), secrets: deps.secrets,
                    peerID: device.serialNumber, allowPairing: true)
                if Task.isCancelled { link.close(); return }
                failures = 0
                log.notice("link up with \(hello.deviceModel, privacy: .public) (\(paired ? "paired" : "authenticated", privacy: .public))")
                await run(link, hello: hello)
            } catch {
                if Task.isCancelled { return }
                failures += 1
                if failures == tuning.fastRetries + 1 {
                    log.notice("still can't reach lain on the iPad: \(String(describing: error), privacy: .public)")
                }
                try? await Task.sleep(for: failures <= tuning.fastRetries ? tuning.fastRetryInterval : tuning.slowRetryInterval)
            }
        }
    }

    /// One connected session; returns when it has ended and been torn down.
    private func run(_ link: Link, hello: Hello) async {
        guard hello.protocolVersion == LainProtocol.majorVersion else {
            link.realtime.send(.error(ErrorMessage(code: .versionMismatch, message: "host speaks v\(LainProtocol.majorVersion)")))
            link.close()
            return
        }
        let display = deps.display.targetDisplay()
        deps.sink.setKeyboardType(hello.keyboardType)
        deps.sink.setDisplayOrigin(display.origin)
        let connection = HostConnection(link: link, display: display, deps: deps, tuning: tuning)
        let registered = state.withLock { s -> Bool in
            guard !s.stopped else { return false }
            s.connection = connection
            return true
        }
        guard registered else { link.close(); return }

        deps.power.beginPreventingDisplaySleep()
        link.realtime.send(.helloAck(.host(display: display, settings: deps.settings())))
        setStatus(.connected(deviceModel: hello.deviceModel))

        await withTaskCancellationHandler {
            await connection.run()
        } onCancel: {
            link.close()
        }
        connection.finish()
        state.withLock { s in if s.connection === connection { s.connection = nil } }
        log.notice("session ended")
    }

    private func setStatus(_ new: HostStatus) {
        let changed = state.withLock { s -> Bool in
            guard s.status != new, !s.stopped || new == .waitingForIPad else { return false }
            s.status = new
            return true
        }
        if changed { onStatus(new) }
    }
}

/// One live link: the realtime handler, the warp sampler and teardown. Everything that touches the
/// sink happens under `rt`, which only the realtime queue takes (teardown aside), so input handling
/// is uncontended and no input can slip in after `releaseAll`.
final class HostConnection: Sendable {
    let link: Link
    let display: HostDisplay
    private let deps: HostSession.Dependencies
    private let tuning: HostSession.Tuning
    private let activityQueue = DispatchQueue(label: "lain.host.activity", qos: .utility)

    private struct Realtime {
        var router: HostInputRouter
        var warp: CursorWarpDetector
        var lastActivityNs: UInt64?
        var finished = false
    }
    private let rt: Mutex<Realtime>
    private let timer: Mutex<(any DispatchSourceTimer)?> = Mutex(nil)
    /// Set once the realtime connection has closed or the session was finished; `waiter` is `run()`.
    private let ended = Mutex<(done: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    init(link: Link, display: HostDisplay, deps: HostSession.Dependencies, tuning: HostSession.Tuning) {
        self.link = link
        self.display = display
        self.deps = deps
        self.tuning = tuning
        var warp = tuning.warp
        warp.reset()
        rt = Mutex(Realtime(router: HostInputRouter(sink: deps.sink), warp: warp))
    }

    /// Installs the handlers and waits until the realtime connection closes.
    func run() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let alreadyEnded = ended.withLock { e -> Bool in
                if !e.done { e.waiter = c }
                return e.done
            }
            if alreadyEnded { return c.resume() }
            link.realtime.setHandler { [self] env in handle(env) }
            link.video.setHandler { _ in }
            link.audio.setHandler { _ in }
            // Realtime carries the input: the session ends when it closes, after its last message has
            // been handled. If video or audio drop alone, close the rest shortly after.
            link.realtime.setCloseHandler { [self] _ in signalEnded() }
            for channel in [link.video, link.audio] {
                channel.setCloseHandler { [link] _ in
                    link.realtime.queue.asyncAfter(deadline: .now() + 0.2) { link.close() }
                }
            }
            startWarpSampler()
        }
    }

    private func signalEnded() {
        let waiter = ended.withLock { e in
            defer { e = (true, nil) }
            return e.waiter
        }
        waiter?.resume()
    }

    /// Idempotent teardown: stop sampling, close the link, release everything, drop the assertion.
    func finish() {
        timer.withLock { t in
            t?.cancel()
            t = nil
        }
        link.close()
        let first = rt.withLock { s -> Bool in
            guard !s.finished else { return false }
            s.finished = true
            s.router.sink.releaseAll()
            return true
        }
        if first { deps.power.endPreventingDisplaySleep() }
        signalEnded()
        // Break the channel → handler → self cycles.
        for channel in link.channels {
            channel.setHandler { _ in }
            channel.setCloseHandler { _ in }
        }
    }

    // MARK: Realtime queue

    private func handle(_ env: Envelope) {
        switch env.message {
        case .ping(let p):
            let received = deps.now()
            link.realtime.send(.pong(Pong(id: p.id, pingSentAtNs: p.sentAtNs, receivedAtNs: received, sentAtNs: deps.now())))
            return
        default:
            break
        }
        let now = deps.now()
        let declare = rt.withLock { s -> Bool in
            guard !s.finished else { return false }
            switch s.router.handle(env) {
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

    private func startWarpSampler() {
        let source = DispatchSource.makeTimerSource(queue: link.realtime.queue)
        let interval = 1.0 / max(tuning.cursorSampleHz, 1)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        source.setEventHandler { [self] in sampleCursor() }
        let started = timer.withLock { t -> Bool in
            guard !ended.withLock({ $0.done }) else { return false }
            t = source
            return true
        }
        if started { source.resume() }
    }

    private func sampleCursor() {
        guard let global = deps.display.cursorLocation() else { return }
        let local = CGPoint(x: min(max(global.x - display.origin.x, 0), display.pointSize.width),
                            y: min(max(global.y - display.origin.y, 0), display.pointSize.height))
        let now = deps.now()
        let warp = rt.withLock { s -> CGPoint? in
            guard !s.finished else { return nil }
            return s.warp.sample(local, atNs: now)
        }
        if let warp { link.realtime.send(.cursorWarp(CursorWarp(x: warp.x, y: warp.y))) }
    }
}
#endif
