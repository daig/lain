import LainHostCore
import Observation
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
            if !host.hasAccessibility {
                Text("Input is off until lain has Accessibility")
                Button("Grant Accessibility…") { host.requestAccessibility() }
            }
            if let video = host.videoLines {
                Divider()
                ForEach(video, id: \.self) { Text($0) }
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
    /// The live session's video numbers (or why it has none), refreshed once a second.
    private(set) var videoLines: [String]?

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
        let session = HostSession(dependencies: .init(sink: InputInjector(), video: { HostVideoPipeline.live() },
                                                      identity: identity,
                                                      wifi: identity.map { _ in HostWiFiConfig(advertise: true) })) {
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
                let granted = InputInjector.hasAccess
                if self?.hasAccessibility != granted { self?.hasAccessibility = granted }
                let agent = LoginAgent.state
                if self?.loginAgent != agent { self?.loginAgent = agent }
                let lines = Self.videoLines(session)
                if self?.videoLines != lines { self?.videoLines = lines }
                let wifi = identity == nil ? "Wi-Fi: off: this Mac's lain id couldn't be loaded" : session.wifiStatus.title
                if self?.wifiLine != wifi { self?.wifiLine = wifi }
            }
        }
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
        guard let v = session.videoStats else {
            return ["No video: \(session.videoError ?? "starting")"]
        }
        func ms(_ x: Double?) -> String { x.map { String(format: "%.1f", $0) } ?? "–" }
        return [
            "Video \(v.pixelWidth)×\(v.pixelHeight) \(v.chroma == .yuv444 ? "4:4:4 10-bit" : "4:2:0")",
            String(format: "%.1f Mb/s, %d sent, %d keyframes, %d refinements", v.bytesPerSecond * 8 / 1e6, v.sent,
                   v.keyframes, v.refinements),
            "Encode p50 \(ms(v.encodeMsP50)) / p95 \(ms(v.encodeMsP95)) ms, ack RTT p50 \(ms(v.ackRttMsP50)) ms",
            "Dropped before encode \(v.droppedBeforeEncode), in flight \(v.inFlight) (peak \(v.peakInFlight))",
        ]
    }

    func requestAccessibility() {
        hasAccessibility = InputInjector.requestAccess()
    }
}
