import LainHostCore
import Observation
import SwiftUI

@main
enum LainHostEntry {
    static func main() {
        if let bench = BenchCommand.requested() { BenchCommand.run(bench) }
        LainHostApp.main()
    }
}

/// Menu-bar agent (LSUIElement). Runs the M2 `HostSession`: the iPad's keyboard and trackpad drive
/// this Mac over USB. Accessibility is requested only from the menu, never at launch.
struct LainHostApp: App {
    @State private var host = HostController()

    var body: some Scene {
        MenuBarExtra("lain", systemImage: "ipad.landscape") {
            Text(host.status.title)
            if !host.hasAccessibility {
                Text("Input is off until lain has Accessibility")
                Button("Grant Accessibility…") { host.requestAccessibility() }
            }
            Divider()
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
    private(set) var hasAccessibility = InputInjector.hasAccess

    @ObservationIgnored private var session: HostSession?
    @ObservationIgnored private var accessPoll: Task<Void, Never>?

    init() {
        let session = HostSession(dependencies: .init(sink: InputInjector())) { [weak self] status in
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
                try? await Task.sleep(for: .seconds(2))
                let granted = InputInjector.hasAccess
                if self?.hasAccessibility != granted { self?.hasAccessibility = granted }
            }
        }
    }

    func requestAccessibility() {
        hasAccessibility = InputInjector.requestAccess()
    }
}
