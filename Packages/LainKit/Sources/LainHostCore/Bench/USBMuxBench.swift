#if os(macOS)
import Foundation
import LainProtocol
import LainTelemetry
import LainTransport
import LainUSBMux

/// `LainHost --bench usbmux` (M1, S1): over the real USB link, measures handshake time, ping RTT,
/// keyframe-sized transfer time and sustained throughput. Needs the client app in the foreground.
public enum USBMuxBench {
    public struct Report: Sendable, CustomStringConvertible {
        public var device: USBMuxDevice
        /// true: this run paired over USB; false: authenticated with the stored secret.
        public var paired: Bool
        public var handshakeMs: Double
        public var rttUs: (p50: Double, p95: Double, max: Double)
        public var keyframeBytes: Int
        public var keyframeMs: (p50: Double, p95: Double, max: Double)
        public var sustainedMBps: Double
        public var sustainedFrameBytes: Int

        public var description: String {
            let speed = device.connectionSpeed.map { "\($0 / 1_000_000) Mbps" } ?? "?"
            return String(format: """
                usbmux bench — device %d (%@), usbmuxd link speed %@
                  handshake (3 connections + ChannelHello + Hello, %@): %.1f ms
                  ping RTT: p50 %.0f µs  p95 %.0f µs  max %.0f µs
                  keyframe-size transfer (%d KB, send → FrameAck, one in flight): p50 %.1f ms  p95 %.1f ms  max %.1f ms
                  sustained (%d KB frames, 3 in flight): %.1f MB/s (%.0f Mbps)
                """, device.deviceID, device.serialNumber.isEmpty ? "no serial" : "serial …" + device.serialNumber.suffix(4),
                speed, paired ? "paired over USB" : "authenticated with stored secret", handshakeMs, rttUs.p50, rttUs.p95, rttUs.max, keyframeBytes / 1024, keyframeMs.p50, keyframeMs.p95,
                keyframeMs.max, sustainedFrameBytes / 1024, sustainedMBps, sustainedMBps * 8)
        }
    }

    public struct Options: Sendable {
        public var pings = 200
        public var keyframes = 30
        /// The M6's real-time 4:4:4 keyframes are 0.8–1.7 MB (§13).
        public var keyframeBytes = 1_300_000
        public var sustainSeconds = 2.0
        public var sustainedFrameBytes = 1_000_000
        public var waitForDeviceSeconds = 30.0
        public init() {}
    }

    public enum Failure: Error { case noDevice }

    public static func run(usbmux: USBMuxClient = USBMuxClient(), secrets: some SecretStore = InMemorySecretStore(),
                           options: Options = Options(), log: @Sendable (String) -> Void = { print($0) }) async throws -> Report {
        log("waiting for a USB device (keep LainClient open and in the foreground on the iPad)…")
        let device = try await firstDevice(usbmux, within: options.waitForDeviceSeconds)
        log("device \(device.deviceID) attached; connecting")

        let t0 = MonotonicClock.now()
        let (link, hello, paired) = try await HostLink.open(dialer: USBMuxDialer(client: usbmux, deviceID: device.deviceID),
                                                   secrets: secrets, peerID: device.serialNumber, allowPairing: true)
        let handshakeMs = Double(MonotonicClock.now() - t0) / 1e6
        defer { link.close() }
        log("connected to \(hello.deviceModel) \(hello.pixelWidth)×\(hello.pixelHeight)")

        let pongs = AsyncStream<(Pong, UInt64)>.makeStream()
        link.realtime.setHandler { env in if case .pong(let p) = env.message { pongs.continuation.yield((p, MonotonicClock.now())) } }
        var rtt = RollingPercentiles(capacity: options.pings)
        var maxRtt = 0.0
        var pongIterator = pongs.stream.makeAsyncIterator()
        for i in 0..<options.pings {
            link.realtime.send(.ping(Ping(id: UInt32(i), sentAtNs: MonotonicClock.now())))
            guard let (p, t3) = await pongIterator.next() else { throw TransportError.closed }
            let us = Double(t3 - p.pingSentAtNs - (p.sentAtNs - p.receivedAtNs)) / 1000
            rtt.record(us)
            maxRtt = max(maxRtt, us)
        }

        let acks = AsyncStream<(FrameAck, UInt64)>.makeStream()
        link.video.setHandler { env in if case .frameAck(let a) = env.message { acks.continuation.yield((a, MonotonicClock.now())) } }
        var ackIterator = acks.stream.makeAsyncIterator()
        var frameId: UInt32 = 0
        func frame(_ bytes: [UInt8]) -> Message {
            frameId += 1
            return .videoFrame(VideoFrame(frameId: frameId, configId: 0, captureTimeNs: MonotonicClock.now(),
                                          encodeDoneNs: MonotonicClock.now(), isKeyframe: true, data: bytes))
        }

        let keyframe = [UInt8](repeating: 0x5A, count: options.keyframeBytes)
        var kf = RollingPercentiles(capacity: options.keyframes)
        var maxKf = 0.0
        for _ in 0..<options.keyframes {
            let sent = MonotonicClock.now()
            link.video.send(frame(keyframe))
            guard let (_, at) = await ackIterator.next() else { throw TransportError.closed }
            let ms = Double(at - sent) / 1e6
            kf.record(ms)
            maxKf = max(maxKf, ms)
        }

        let big = [UInt8](repeating: 0xA5, count: options.sustainedFrameBytes)
        var window = FrameAckWindow(maxInFlight: 3)
        var bytes = 0
        let start = MonotonicClock.now()
        let end = start + UInt64(options.sustainSeconds * 1e9)
        while MonotonicClock.now() < end || window.inFlightCount > 0 {
            if MonotonicClock.now() < end, window.canSend {
                let m = frame(big)
                window.sent(frameId: frameId, bytes: big.count, at: MonotonicClock.now())
                link.video.send(m)
                continue
            }
            guard let (a, at) = await ackIterator.next() else { throw TransportError.closed }
            if let done = window.acked(frameId: a.frameId, at: at) { bytes += done.bytes }
        }
        let seconds = Double(MonotonicClock.now() - start) / 1e9

        return Report(device: device, paired: paired, handshakeMs: handshakeMs, rttUs: (rtt.p50 ?? 0, rtt.p95 ?? 0, maxRtt),
                      keyframeBytes: options.keyframeBytes, keyframeMs: (kf.p50 ?? 0, kf.p95 ?? 0, maxKf),
                      sustainedMBps: Double(bytes) / seconds / 1e6, sustainedFrameBytes: options.sustainedFrameBytes)
    }

    static func firstDevice(_ usbmux: USBMuxClient, within seconds: Double) async throws -> USBMuxDevice {
        try await withThrowingTaskGroup(of: USBMuxDevice?.self) { group in
            group.addTask {
                for try await event in usbmux.events() { if case .attached(let d) = event { return d } }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let device = first else { throw Failure.noDevice }
            return device
        }
    }
}
#endif
