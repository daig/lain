import CoreGraphics
import LainHostCore
import Observation
import Synchronization
import SwiftUI

@main
enum LainHostEntry {
    static func main() {
        raiseOpenFileLimit()
        if let bench = BenchCommand.requested() { BenchCommand.run(bench) }
        if CommandLine.arguments.contains("--agent-status") {   // diagnostics: SMAppService state (+ --register)
            print("login agent: \(LoginAgent.state), installed: \(LoginAgent.isInstalled), bundle: \(Bundle.main.bundlePath)")
            if CommandLine.arguments.contains("--register") {
                do { try LoginAgent.register(); print("register: ok → \(LoginAgent.state)") }
                catch { print("register failed: \(error)") }
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--unregister-agent") {   // Scripts/install-host.sh --uninstall
            try? LoginAgent.unregister()
            exit(0)
        }
        // As a test host (LainHostTests) the app must neither hand over to the installed agent nor start a
        // session that would compete with the real host for the iPad.
        if !isTestHost { LoginAgent.settleInstance() }   // one host only; the launchd-managed agent wins (§5.7)
        LainHostApp.main()
    }

    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

    /// launchd starts the agent with a soft limit of 256 descriptors. Every USB dial opens a socket to
    /// usbmuxd and every Wi-Fi connection one of its own, so raise it to `wanted` (or the hard limit, if
    /// lower): defence in depth against a flood of unauthenticated Wi-Fi handshakes starving the USB
    /// path (§7.7).
    static func raiseOpenFileLimit(to wanted: rlim_t = 4096) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target = min(wanted, limit.rlim_max)
        guard limit.rlim_cur < target else { return }
        limit.rlim_cur = target
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            NSLog("lain: couldn't raise the open-file limit to \(target) (errno \(errno))")
        }
    }
}

/// Menu-bar agent (LSUIElement). Runs the `HostSession`: the iPad is an extra display of this Mac
/// (the lain virtual display, streamed over USB, M3, or Wi-Fi, M6) and its keyboard and trackpad drive
/// the whole desktop. Accessibility is requested only from the menu, never at launch; Screen Recording is
/// asked for by macOS when the first session starts capture, Local Network when the Wi-Fi listener first
/// advertises.
struct LainHostApp: App {
    @State private var host = HostController()

    var body: some Scene {
        MenuBarExtra("lain", systemImage: "ipad.landscape") {
            Text(host.status.title)
            Text(host.wifiLine)
            if let note = host.peerVersionNote { Text(note) }
            if !host.hasAccessibility {
                Text("Input is off until lain has Accessibility")
                Button("Grant Accessibility…") { host.requestAccessibility() }
            }
            if let video = host.videoLines {
                Divider()
                ForEach(video, id: \.self) { Text($0) }
            }
            if host.videoStoppedOnTheMac {
                Button("Resume Video") { host.resumeVideo() }
            }
            Divider()
            Menu("Display Scale") {
                ForEach(HostPreferences.scaleChoices, id: \.self) { scale in
                    Button((host.preferences.displayScale == scale ? "✓ " : "") + HostController.scaleTitle(scale)) {
                        host.update { $0.displayScale = scale }
                    }
                }
            }
            Menu("Color") {
                ForEach(HostPreferences.ColorFormat.allCases, id: \.self) { format in
                    Button((host.preferences.colorFormat == format ? "✓ " : "") + format.title) {
                        host.update { $0.colorFormat = format }
                    }
                }
            }
            Menu("Keep Display After Disconnect") {
                ForEach(HostPreferences.keepAliveChoices, id: \.self) { seconds in
                    Button((host.preferences.displayKeepAliveSeconds == seconds ? "✓ " : "") + HostController.keepAliveTitle(seconds)) {
                        host.update { $0.displayKeepAliveSeconds = seconds }
                    }
                }
            }
            Button((host.preferences.resumeAfterStop ? "✓ " : "") + "Resume Video After Stop") {
                host.update { $0.resumeAfterStop.toggle() }
            }
            Button((host.preferences.systemKey ? "✓ " : "") + "Right Option Is the System Key") {
                host.update { $0.systemKey.toggle() }
            }
            Divider()
            switch host.loginAgent {
            case .enabled:
                Button("✓ Start at Login") { host.setStartAtLogin(false) }
            case .requiresApproval:
                Text("Start at Login needs approval")
                Button("Allow in Login Items…") { LoginAgent.openLoginItemsSettings() }
            case .notRegistered:
                Button("Start at Login") { host.setStartAtLogin(true) }
            case .notFound:
                Text("Start at Login: install with Scripts/install-host.sh")
            }
            Text(HostStatus.protocolDescription)
            Button("Quit lain") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// Owns the session and mirrors its status for the menu.
@MainActor @Observable
final class HostController {
    private(set) var status = HostStatus.waitingForIPad
    /// The Wi-Fi listener (§7.7): advertising, blocked by Local Network privacy, off or failed.
    private(set) var wifiLine = HostWiFiStatus.starting.title
    private(set) var hasAccessibility = InputInjector.hasAccess
    private(set) var loginAgent = LoginAgent.state
    /// The live session's video format (or why it has none): fixed for a session.
    private(set) var videoLines: [String]?
    /// lain on the iPad runs an older protocol version (it works): what updating it adds.
    private(set) var peerVersionNote: String?
    /// The owner's settings, kept in the app's defaults.
    private(set) var preferences = HostPreferences.load()
    /// The live session's capture was stopped from the Mac's menu bar.
    private(set) var videoStoppedOnTheMac = false
    /// Read by the session's queues as each session starts.
    @ObservationIgnored private let livePreferences = LivePreferences(HostPreferences.load())
    @ObservationIgnored private let keeper = DisplayKeeper(keepFor: .seconds(HostPreferences.load().displayKeepAliveSeconds))

    @ObservationIgnored private var session: HostSession?
    @ObservationIgnored private var accessPoll: Task<Void, Never>?

    init() {
        guard !LainHostEntry.isTestHost else { return }
        // Who this Mac is to its iPads over Wi-Fi (§7.7 D29). Without it the session stays USB-only rather
        // than advertise an id that changes.
        let identity: HostIdentity?
        do {
            identity = try HostIdentity.load()
        } catch {
            NSLog("lain: couldn't load this Mac's host id (\(error)); Wi-Fi stays off")
            identity = nil
        }
        // The Wi-Fi listener exists only here, after the test-host guard: a test host never listens or
        // advertises (§7.7 D29 decision 12).
        let preferences = livePreferences, keeper = keeper
        let session = HostSession(dependencies: .init(sink: InputInjector(),
                                                      video: { HostVideoPipeline.live(keeper: keeper,
                                                                                      scale: preferences.value.displayScale,
                                                                                      colorFormat: preferences.value.colorFormat) },
                                                      identity: identity,
                                                      wifi: identity.map { _ in HostWiFiConfig(advertise: true) },
                                                      setup: Self.probeSetup,
                                                      preferences: { preferences.value },
                                                      displayKeeper: keeper)) {
            [weak self] status in
            // Main-queue hops keep status updates in order.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.status = status } }
        }
        self.session = session
        session.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { _ in session.stop() }
        // The grant happens in System Settings; notice it without restarting.
        accessPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                // A grant, a display attached: the iPad hears about it (if its version has HostSetup).
                session.setupChanged()
                // Each assignment below that changes a value rebuilds the menu (closing an open submenu), so
                // the menu shows only what stays put during a session.
                let granted = InputInjector.hasAccess
                if self?.hasAccessibility != granted { self?.hasAccessibility = granted }
                let agent = LoginAgent.state
                if self?.loginAgent != agent { self?.loginAgent = agent }
                let lines = Self.videoLines(session)
                if self?.videoLines != lines { self?.videoLines = lines }
                let wifi = identity == nil ? "Wi-Fi: off: this Mac's lain id couldn't be loaded" : session.wifiStatus.title
                if self?.wifiLine != wifi { self?.wifiLine = wifi }
                let note = session.peerVersionNote
                if self?.peerVersionNote != note { self?.peerVersionNote = note }
                let stopped = session.isVideoStoppedOnTheMac
                if self?.videoStoppedOnTheMac != stopped { self?.videoStoppedOnTheMac = stopped }
            }
        }
    }

    /// The Mac's setup for the iPad (`HostSetup`, v4): permissions and whether a real display is attached.
    /// Called from the session's queues.
    nonisolated static func probeSetup() -> HostSetup {
        let login: HostSetup.State = switch LoginAgent.state {
        case .enabled: .granted
        case .notFound: .unknown
        default: .missing
        }
        return HostSetupProbe.setup(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: InputInjector.hasAccess,
                                    startAtLogin: login)
    }

    /// Registering loads the agent (RunAtLoad): launchd then starts the managed instance, which replaces
    /// this one. Unregistering leaves this instance running until Quit.
    func setStartAtLogin(_ on: Bool) {
        do {
            if on { try LoginAgent.register() } else { try LoginAgent.unregister() }
        } catch {
            NSLog("lain: login agent \(on ? "register" : "unregister") failed: \(error)")
        }
        loginAgent = LoginAgent.state
    }

    private static func videoLines(_ session: HostSession) -> [String]? {
        guard session.status.isConnected else { return nil }
        guard let d = session.streamedDisplay, let v = session.videoStats else {
            return ["No video: \(session.videoError ?? "starting")"]
        }
        // Fixed for the session: live numbers would rebuild the menu every second (the iPad's HUD has them).
        return [
            "Video \(d.pixelWidth)×\(d.pixelHeight) px, \(v.chroma == .yuv444 ? "4:4:4 10-bit" : "4:2:0"), \(d.refreshRate) Hz",
            "lain display \(Int(d.bounds.width))×\(Int(d.bounds.height)) points",
        ]
    }

    /// Changes a setting: saved, and applied to the live session where it can't wait for the next one
    /// (the scale, the color format and the system key reconnect it; the keep-alive applies to the next display kept).
    func update(_ change: (inout HostPreferences) -> Void) {
        var new = preferences
        change(&new)
        guard new != preferences else { return }
        let old = preferences
        preferences = new
        new.save()
        livePreferences.value = new
        keeper.keepFor = .seconds(new.displayKeepAliveSeconds)
        if new.displayScale != old.displayScale || new.systemKey != old.systemKey || new.colorFormat != old.colorFormat {
            session?.reconnect()
        }
    }

    func resumeVideo() {
        session?.resumeVideo()
    }

    nonisolated static func scaleTitle(_ scale: Double) -> String {
        let spec = { var s = VirtualDisplay.Spec(); s.scale = scale; return s }()
        let name = switch scale {
        case ..<1.9: "More Space"
        case 1.9..<2.1: "Default"
        default: "Larger"
        }
        return "\(name): \(spec.pointWidth)×\(spec.pointHeight)"
    }

    nonisolated static func keepAliveTitle(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Off"
        case ..<60: "\(seconds) s"
        default: "\(seconds / 60) min"
        }
    }

    func requestAccessibility() {
        hasAccessibility = InputInjector.requestAccess()
    }
}

/// The settings the session's queues read as each session starts.
final class LivePreferences: Sendable {
    private let preferences: Mutex<HostPreferences>
    init(_ preferences: HostPreferences) { self.preferences = Mutex(preferences) }
    var value: HostPreferences {
        get { preferences.withLock { $0 } }
        set { preferences.withLock { $0 = newValue } }
    }
}
