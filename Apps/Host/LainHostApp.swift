import LainHostCore
import SwiftUI

@main
enum LainHostEntry {
    static func main() {
        if let bench = BenchCommand.requested() { BenchCommand.run(bench) }
        LainHostApp.main()
    }
}

/// Menu-bar agent (LSUIElement). Capture, injection and session wiring arrive with M1–M3;
/// nothing here requests Screen Recording or Accessibility yet.
struct LainHostApp: App {
    @State private var status = HostStatus.waitingForIPad

    var body: some Scene {
        MenuBarExtra("lain", systemImage: "ipad.landscape") {
            Text(status.title)
            Text(HostStatus.protocolDescription)
            Divider()
            Button("Quit lain") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
