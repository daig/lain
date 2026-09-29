import CoreGraphics
import LainProtocol

extension HelloAck {
    /// The host's answer to `Hello` (§7.5 handshake step 3). `display` is the streamed display (M3: the
    /// lain virtual display) and `chroma` what the video pipeline streams; the audio fields state what
    /// M5 will use.
    public static func host(display: HostDisplay, settings: HostInputSettings, chroma: ChromaFormat = .yuv444) -> HelloAck {
        HelloAck(codec: .hevc, chroma: chroma, bitDepth: chroma == .yuv444 ? 10 : 8, displayMode: .extend, bitrate: 60_000_000,
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

/// The host runtime (§5.7): watches usbmuxd, dials lain on an attached iPad, starts the session's video
/// (M3: the lain virtual display, captured, encoded and streamed with frame-ack backpressure), answers
/// `Hello`, sends
/// the desktop's `DisplayLayout` (right after `HelloAck`, and again whenever the arrangement changes),
/// routes the client's input into the `InputSink` (global points), answers pings, reflects cursor
/// warps (§5.4, global) and holds the display awake while connected (§5.5 Power). Reconnects on its
/// own when the client comes back (app relaunched, cable replugged).
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
        /// Makes one session's video pipeline (`HostVideoPipeline.live()` in the app, fakes in tests).
        /// nil: no video (the M2 input-only session, streaming the main display's geometry).
        public var video: (@Sendable () -> HostVideoPipeline)?

        public init(usbmux: USBMuxClient = USBMuxClient(), secrets: any SecretStore = KeychainSecretStore(),
                    sink: any InputSink, display: any DisplayProvider = DisplayLayoutProvider.system(),
                    power: any PowerAssertions = IOPMPowerAssertions(),
                    settings: @escaping @Sendable () -> HostInputSettings = { .current },
                    now: @escaping @Sendable () -> UInt64 = { MonotonicClock.now() },
                    video: (@Sendable () -> HostVideoPipeline)? = nil) {
            self.video = video
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
        /// How often a live session re-reads the display arrangement (off the realtime queue); a change
        /// (resolution, arrangement, displays added or removed, which one is streamed) is sent as a new
        /// `DisplayLayout`, and the session goes on.
        public var displayCheckIntervalNs: UInt64 = 500_000_000
        /// Tests only: runs in `run()` right after the connection is registered.
        var afterRegistering: (@Sendable () -> Void)?
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
        /// The device being dialed or connected. `generation` identifies its connect loop, so a loop
        /// that has been replaced or cancelled can't register a connection or change the status.
        var device: (id: Int, generation: UInt64, task: Task<Void, Never>)?
        var generation: UInt64 = 0
        /// Every USB device usbmuxd reports, in attach order. Only `device` is dialed; the others are
        /// tried when it detaches or lain doesn't answer on it (an iPhone charging, say).
        var attached: [USBMuxDevice] = []
        var connection: HostConnection?
        /// The latest session's video pipeline: a new session waits for its teardown (capture stopped,
        /// virtual display removed) before creating its own display.
        var video: HostVideoPipeline?
        /// Why the latest session has no video (Screen Recording missing, say), for the menu.
        var videoError: String?

        /// Returns whether the status changed.
        mutating func set(_ new: HostStatus) -> Bool {
            guard status != new, !stopped || new == .waitingForIPad else { return false }
            status = new
            return true
        }
    }
    private let state = Mutex(State())

    public init(dependencies: Dependencies, tuning: Tuning = Tuning(),
                onStatus: @escaping @Sendable (HostStatus) -> Void = { _ in }) {
        deps = dependencies
        self.tuning = tuning
        self.onStatus = onStatus
    }

    public var status: HostStatus { state.withLock { $0.status } }

    /// The live session's video numbers (nil when no session has video).
    public var videoStats: HostVideoStats? {
        state.withLock { s in s.connection != nil ? s.video : nil }.flatMap { $0.isRunning ? $0.stats : nil }
    }

    /// Why the current session streams no video, if it failed to start.
    public var videoError: String? { state.withLock { $0.videoError } }

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
            defer { s.runTask = nil; s.device = nil; s.connection = nil; s.attached = [] }
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
            // The daemon went away (restart?): forget the devices; their events will be replayed.
            let active = state.withLock { s -> Int? in
                s.attached.removeAll()
                return s.device?.id
            }
            if let active { detached(active) }
            try? await Task.sleep(for: tuning.usbmuxRetryInterval)
        }
    }

    private func attached(_ device: USBMuxDevice) {
        let replaced = state.withLock { s -> (task: Task<Void, Never>, connection: HostConnection?)?? in
            guard !s.stopped else { return .none }
            s.attached.removeAll { $0.deviceID == device.deviceID }
            s.attached.append(device)
            // One iPad at a time: another device waits its turn; the same one re-attaching replaces itself.
            if let current = s.device, current.id != device.deviceID { return .none }
            let previous = s.device.map { d -> (task: Task<Void, Never>, connection: HostConnection?) in
                defer { s.connection = nil }
                return (d.task, s.connection)
            }
            dial(device, in: &s)
            return .some(previous)
        }
        guard let replaced else {
            log.notice("device \(device.deviceID) attached; waiting its turn (another device is in use)")
            return
        }
        if let replaced {
            replaced.task.cancel()
            replaced.connection?.finish()   // before the new loop can connect: the sink and power are shared
        }
        log.notice("iPad attached: device \(device.deviceID)")
    }

    private func detached(_ id: Int) {
        let (task, connection, next, changed) = state.withLock {
            s -> (Task<Void, Never>?, HostConnection?, Int?, Bool) in
            s.attached.removeAll { $0.deviceID == id }
            guard let current = s.device, current.id == id else { return (nil, nil, nil, false) }
            let connection = s.connection
            s.device = nil
            s.connection = nil
            if !s.stopped, let next = s.attached.first {
                dial(next, in: &s)
                return (current.task, connection, next.deviceID, false)
            }
            return (current.task, connection, nil, s.set(.waitingForIPad))
        }
        guard let task else { return }
        log.notice("iPad detached: device \(id)")
        task.cancel()
        connection?.finish()   // release now; don't wait for the socket to notice
        if let next { log.notice("trying device \(next)") }
        if changed { onStatus(.waitingForIPad) }
    }

    /// Starts the connect loop for `device` (under `state`).
    private func dial(_ device: USBMuxDevice, in s: inout State) {
        s.generation &+= 1
        let generation = s.generation
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

    // MARK: Connection

    private func connectLoop(_ device: USBMuxDevice, generation: UInt64) async {
        var failures = 0
        while !Task.isCancelled {
            setStatus(.connecting, generation: generation)
            do {
                let (link, hello, paired) = try await HostLink.open(
                    dialer: USBMuxDialer(client: deps.usbmux, deviceID: device.deviceID), secrets: deps.secrets,
                    peerID: device.serialNumber, allowPairing: true)
                if Task.isCancelled { link.close(); return }
                failures = 0
                log.notice("link up with \(hello.deviceModel, privacy: .public) (\(paired ? "paired" : "authenticated", privacy: .public))")
                await run(link, hello: hello, generation: generation)
            } catch {
                if Task.isCancelled { return }
                failures += 1
                if failures == tuning.fastRetries + 1 {
                    log.notice("still can't reach lain on device \(device.deviceID): \(String(describing: error), privacy: .public)")
                }
                if failures > tuning.fastRetries, handOff(from: device, generation: generation) { return }
                try? await Task.sleep(for: failures <= tuning.fastRetries ? tuning.fastRetryInterval : tuning.slowRetryInterval)
            }
        }
    }

    /// One connected session; returns when it has ended and been torn down.
    private func run(_ link: Link, hello: Hello, generation: UInt64) async {
        guard hello.protocolVersion == LainProtocol.majorVersion else {
            link.realtime.send(.error(ErrorMessage(code: .versionMismatch, message: "host speaks v\(LainProtocol.majorVersion)")))
            link.close()
            return
        }
        // The streamed display is the session's virtual display once video is up (§5.1); until then, or
        // without video, the provider falls back to the main display.
        let video = deps.video?()
        let provider = video.map { v in deps.display.streaming { v.streamedDisplayID } } ?? deps.display
        deps.sink.setKeyboardType(hello.keyboardType)
        let connection = HostConnection(link: link, display: provider.targetDisplay(), provider: provider, video: video,
                                        deps: deps, tuning: tuning)
        let previousVideo = state.withLock { s -> HostVideoPipeline?? in
            guard !s.stopped, !Task.isCancelled, s.device?.generation == generation else { return .none }
            s.connection = connection
            defer { if video != nil { s.video = video; s.videoError = nil } }
            return .some(s.video)
        }
        guard let previousVideo else { link.close(); return }
        tuning.afterRegistering?()

        // A detach or stop from here on finishes `connection`; `start()` then refuses, so the power
        // assertion is only taken by a connection that will also release it.
        if connection.start() {
            // One lain display at a time: the last session's display must be gone before this one's
            // appears (they share the persistent identity macOS remembers the arrangement by).
            if let previousVideo, previousVideo !== video { await previousVideo.waitUntilStopped() }
            let chroma = await startVideo(connection, hello: hello)
            // HelloAck after video start, so it carries the virtual display's point size and the chroma
            // actually streamed. The first frames may overtake it on the video connection; the client
            // decodes them regardless.
            let display = provider.targetDisplay()
            link.realtime.send(.helloAck(.host(display: display, settings: deps.settings(), chroma: chroma ?? .yuv444)))
            connection.sendLayoutIfChanged()   // the first one always goes
            setStatus(.connected(deviceModel: hello.deviceModel), generation: generation)
            await withTaskCancellationHandler {
                await connection.run()
            } onCancel: {
                link.close()
            }
        }
        connection.finish()
        state.withLock { s in if s.connection === connection { s.connection = nil } }
        await video?.waitUntilStopped()
        log.notice("session ended")
    }

    /// Starts the connection's video, if it has any. Returns the chroma streamed, or nil without video.
    /// A failure (no Screen Recording grant, say) leaves an input-only session on the main display.
    private func startVideo(_ connection: HostConnection, hello: Hello) async -> ChromaFormat? {
        guard let video = connection.video else { return nil }
        let link = connection.link, log = self.log
        do {
            try await video.start(hello: hello, videoChannel: link.video, sendRealtime: { link.realtime.send($0) },
                                  onError: { error in
                                      // Capture stopped on its own: end the session; the reconnect starts afresh.
                                      log.error("video capture stopped: \(String(describing: error), privacy: .public); ending the session")
                                      link.close()
                                  })
            return video.chroma
        } catch HostVideoError.stopped {
            return nil
        } catch {
            log.error("video unavailable: \(String(describing: error), privacy: .public); input only")
            state.withLock { s in if s.video === video { s.videoError = String(describing: error) } }
            return nil
        }
    }

    /// With `generation`, only while that connect loop still owns the device (a detached or replaced
    /// loop must not overwrite the status).
    private func setStatus(_ new: HostStatus, generation: UInt64? = nil) {
        let changed = state.withLock { s -> Bool in
            if let generation, s.device?.generation != generation { return false }
            return s.set(new)
        }
        if changed { onStatus(new) }
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
        let sampler = DispatchSource.makeTimerSource(queue: link.realtime.queue)
        let interval = 1.0 / max(tuning.cursorSampleHz, 1)
        sampler.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        sampler.setEventHandler { [self] in sampleCursor() }
        // The arrangement is re-read off the realtime queue so input never waits behind CoreGraphics.
        let layout = DispatchSource.makeTimerSource(queue: layoutQueue)
        let check = Double(max(tuning.displayCheckIntervalNs, 1_000_000)) / 1e9
        layout.schedule(deadline: .now() + check, repeating: check, leeway: .milliseconds(20))
        layout.setEventHandler { [self] in sendLayoutIfChanged() }
        let started = timers.withLock { t -> Bool in
            guard !ended.withLock({ $0.done }) else { return false }
            t = [sampler, layout]
            return true
        }
        if started {
            sampler.resume()
            layout.resume()
        }
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
        lastLayout.withLock { last in
            guard layout != last, !ended.withLock({ $0.done }) else { return }
            if last != nil {
                log.notice("display arrangement changed: \(layout.displays.count) display(s); sending the new layout")
            }
            last = layout
            link.realtime.send(.displayLayout(layout))
        }
    }
}
#endif
