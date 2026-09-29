#if os(macOS)
import AppKit
import Foundation
import ServiceManagement

/// The host as an installed login service (§5.7, D12): a LaunchAgent bundled in the app
/// (`Contents/Library/LaunchAgents/sub.dev.lain.host.agent.plist`) and registered with `SMAppService`.
/// launchd starts it at login and restarts it after a crash; a clean Quit stays quit.
///
/// Exactly one host runs: the launchd-managed instance ("the agent") wins. A manually opened copy hands
/// over to the agent (or registers it) and exits.
public enum LoginAgent {
    public static let label = "sub.dev.lain.host.agent"
    public static let plistName = "sub.dev.lain.host.agent.plist"
    public static let bundleID = "sub.dev.lain.host"

    public enum State: Sendable, Equatable {
        case enabled
        /// Registered, but the user must allow it in System Settings › General › Login Items.
        case requiresApproval
        case notRegistered
        /// The plist isn't in this bundle (e.g. an old build).
        case notFound
    }

    static var service: SMAppService { .agent(plistName: plistName) }

    public static var state: State {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        // macOS 27 reports .notFound for a bundled agent until its first registration (observed
        // 2026-09-28: notFound → register() → enabled), so it means "not registered" when the plist ships.
        case .notFound: plistInBundle ? .notRegistered : .notFound
        default: .notRegistered
        }
    }

    public static func register() throws { try service.register() }

    static var plistInBundle: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents/\(plistName)").path)
    }
    public static func unregister() throws { try service.unregister() }
    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// This process was started by launchd for the agent job.
    public static var isAgentInstance: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label
    }

    /// The bundle is installed (not a build-folder copy): only an installed copy registers itself.
    public static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Asks launchd to (re)start the agent now. False if launchctl failed (e.g. not loaded).
    @discardableResult
    public static func kickstart(restart: Bool = false) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart"] + (restart ? ["-k"] : []) + ["gui/\(getuid())/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Other running LainHost processes (not this one).
    public static func otherInstances() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    // MARK: Single instance

    public enum Decision: Sendable, Equatable {
        /// Run the host here.
        case run
        /// The agent starts up while a manual copy runs: stop that copy, then run.
        case terminateOthersAndRun
        /// Another host is already running: leave it alone and exit.
        case exitAlreadyRunning
        /// The agent is enabled but not running: start it and exit.
        case startAgentAndExit
        /// An installed copy whose agent isn't registered yet: register (launchd then starts it) and exit.
        case registerAgentAndExit
    }

    /// Pure decision for a starting (non-bench) process.
    public static func decide(isAgent: Bool, othersRunning: Bool, state: State, installed: Bool) -> Decision {
        if isAgent { return othersRunning ? .terminateOthersAndRun : .run }
        if othersRunning { return .exitAlreadyRunning }
        switch state {
        case .enabled: return .startAgentAndExit
        case .notRegistered where installed: return .registerAgentAndExit
        default: return .run
        }
    }

    /// Applies `decide` at process start. Returns only if this process should run the host.
    public static func settleInstance() {
        let others = otherInstances()
        let decision = decide(isAgent: isAgentInstance, othersRunning: !others.isEmpty, state: state, installed: isInstalled)
        switch decision {
        case .run:
            return
        case .terminateOthersAndRun:
            // Graceful first (the other host releases input and removes its display), then forced.
            others.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(3)
            while others.contains(where: { !$0.isTerminated }) && Date() < deadline { usleep(50_000) }
            others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
            usleep(200_000)
        case .exitAlreadyRunning:
            exit(0)
        case .startAgentAndExit:
            if kickstart() { exit(0) }
            return                                   // launchctl failed: run here instead
        case .registerAgentAndExit:
            do {
                try register()
                if state == .enabled {
                    kickstart()
                    exit(0)
                }
            } catch {
                NSLog("lain: login agent registration failed: \(error)")
            }
            return                                   // needs approval or failed: run here for now
        }
    }
}
#endif
