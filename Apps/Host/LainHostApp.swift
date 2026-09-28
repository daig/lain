import LainHostCore
import SwiftUI

/// Menu-bar agent (LSUIElement). Capture, injection and session wiring arrive with M1–M3;
/// nothing here requests Screen Recording or Accessibility yet.
@main
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
