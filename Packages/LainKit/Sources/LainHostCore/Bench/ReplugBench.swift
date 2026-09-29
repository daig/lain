#if os(macOS)
import Foundation
import LainProtocol
import LainTelemetry
import LainTransport
import LainUSBMux

/// `LainHost --bench replug` (M1 done criterion): keeps a session open, pinging every 100 ms, and
/// reconnects whenever the iPad comes back. Prints each detach, reattach and reconnect with timings.
/// Runs until `sessions` sessions have been established (or Ctrl-C).
public enum ReplugBench {
    public static func run(usbmux: USBMuxClient = USBMuxClient(), secrets: some SecretStore = KeychainSecretStore(),
                           sessions: Int = 3, log: @escaping @Sendable (String) -> Void = { print($0) }) async throws {
        let stamp: @Sendable () -> String = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f.string(from: Date())
        }
        log("\(stamp()) replug bench: keep LainClient in the foreground; unplug and replug when a session is up (Ctrl-C to stop)")
        var detachedAt: UInt64?
        var established = 0
        var current: (task: Task<Void, Never>, deviceID: Int)?

        for try await event in usbmux.events() {
            switch event {
            case .attached(let device):
                let attachedAt = MonotonicClock.now()
                let sinceDetach = detachedAt.map { String(format: " (%.0f ms after detach)", Double(attachedAt - $0) / 1e6) } ?? ""
                log("\(stamp()) attached: device \(device.deviceID)\(sinceDetach)")
                current?.task.cancel()
                let task = Task {
                    // The client's listener may need a moment after re-attach; retry briefly.
                    for attempt in 1...20 {
                        do {
                            let (link, _, paired) = try await HostLink.open(
                                dialer: USBMuxDialer(client: usbmux, deviceID: device.deviceID), secrets: secrets,
                                peerID: device.serialNumber, allowPairing: true)
                            log(String(format: "%@ session up in %.0f ms after attach (attempt %d, %@)", stamp(),
                                       Double(MonotonicClock.now() - attachedAt) / 1e6, attempt,
                                       paired ? "paired" : "authenticated"))
                            await keepAlive(link, log: log, stamp: stamp)
                            return
                        } catch {
                            if Task.isCancelled { return }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    log("\(stamp()) could not connect after 20 attempts")
                }
                current = (task, device.deviceID)
                established += 1
                if established > sessions { current?.task.cancel(); return }
            case .detached(let id):
                detachedAt = MonotonicClock.now()
                log("\(stamp()) detached: device \(id) (usbmuxd event)")
                if current?.deviceID == id { current?.task.cancel(); current = nil }
            }
        }
    }

    /// Pings every 100 ms until the link closes; reports RTT once a second.
    static func keepAlive(_ link: Link, log: @escaping @Sendable (String) -> Void, stamp: @escaping @Sendable () -> String) async {
        let pongs = AsyncStream<UInt64>.makeStream()
        link.realtime.setHandler { env in
            if case .pong(let p) = env.message { pongs.continuation.yield(MonotonicClock.now() - p.pingSentAtNs) }
        }
        link.realtime.setCloseHandler { _ in pongs.continuation.finish() }
        let pinger = Task {
            var id: UInt32 = 0
            while !Task.isCancelled {
                id += 1
                link.realtime.send(.ping(Ping(id: id, sentAtNs: MonotonicClock.now())))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            pinger.cancel()
            link.close()
        }
        var n = 0
        await withTaskCancellationHandler {
            for await rtt in pongs.stream {
                n += 1
                if n % 10 == 0 { log(String(format: "%@   alive, RTT %.0f µs", stamp(), Double(rtt) / 1000)) }
            }
            log("\(stamp()) session closed by the link")
        } onCancel: {
            pongs.continuation.finish()
        }
    }
}
#endif
