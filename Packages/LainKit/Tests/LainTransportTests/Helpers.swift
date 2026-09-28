import Dispatch
import LainProtocol
import Synchronization
@testable import LainTransport

/// Collects values from callbacks and lets tests await them.
final class Inbox<T: Sendable>: Sendable {
    private let state = Mutex<(items: [T], waiters: [CheckedContinuation<T?, Never>])>(([], []))

    func put(_ v: T) {
        let waiter = state.withLock { s -> CheckedContinuation<T?, Never>? in
            if s.waiters.isEmpty { s.items.append(v); return nil }
            return s.waiters.removeFirst()
        }
        waiter?.resume(returning: v)
    }

    /// The next value, or nil after `seconds`.
    func next(within seconds: Double = 5) async -> T? {
        await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let ready = state.withLock { s -> T? in
                if !s.items.isEmpty { return s.items.removeFirst() }
                s.waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
                let timedOut = state.withLock { s -> CheckedContinuation<T?, Never>? in
                    guard let i = s.waiters.firstIndex(where: { _ in true }) else { return nil }
                    return s.waiters.remove(at: i)
                }
                timedOut?.resume(returning: nil)
            }
        }
    }

    var count: Int { state.withLock { $0.items.count } }
}

let sampleHello = Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                        decodeCapabilities: [.hevcMain, .hevcMain44410Hardware], keyboardType: .ansi)

let sampleHelloAck = HelloAck(codec: .hevc, chroma: .yuv444, bitDepth: 10, displayMode: .extend, bitrate: 60_000_000,
                              refreshRate: 120, displayPointWidth: 1376, displayPointHeight: 1032,
                              audioSampleRate: 48_000, audioChannels: 2, audioEncoding: .pcm16LE,
                              doubleClickIntervalMs: 500, keyRepeatDelayMs: 225, keyRepeatIntervalMs: 30,
                              macInputSource: "com.apple.keylayout.Colemak")
