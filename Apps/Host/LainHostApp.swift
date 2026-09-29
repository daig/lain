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

/// Menu-bar agent (LSUIElement). Runs the `HostSession`: the iPad is an extra display of this Mac
/// (the lain virtual display, streamed over USB, M3) and its keyboard and trackpad drive the whole
/// desktop. Accessibility is requested only from the menu, never at launch; Screen Recording is asked
/// for by macOS when the first session starts capture.
struct LainHostApp: App {
    @State private var host = HostController()

    var body: some Scene {
        MenuBarExtra("lain", systemImage: "ipad.landscape") {
            Text(host.status.title)
            if !host.hasAccessibility {
                Text("Input is off until lain has Accessibility")
                Button("Grant Accessibility…") { host.requestAccessibility() }
            }
            if let video = host.videoLines {
                Divider()
                ForEach(video, id: \.self) { Text($0) }
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
    /// The live session's video numbers (or why it has none), refreshed once a second.
    private(set) var videoLines: [String]?

    @ObservationIgnored private var session: HostSession?
    @ObservationIgnored private var accessPoll: Task<Void, Never>?

    init() {
        let session = HostSession(dependencies: .init(sink: InputInjector(), video: { HostVideoPipeline.live() })) {
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
                let lines = Self.videoLines(session)
                if self?.videoLines != lines { self?.videoLines = lines }
            }
        }
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
