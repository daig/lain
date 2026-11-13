import AVFAudio
import Foundation
import LainProtocol
import LainTelemetry
import LainTransport
import Synchronization

/// Plays the host's sound (v6 `AudioConfig`, `AudioPacket`) on the iPad: packets go into an
/// `AudioJitterBuffer`, which an `AVAudioEngine` source node drains on the render thread. The engine starts
/// with the first `AudioConfig` and keeps running; with no packets it plays silence.
public final class ClientAudioPlayer: Sendable {
    private struct State {
        var engine: AVAudioEngine?
        var buffer: AudioJitterBuffer?
        var config: AudioConfig?
        var muted = false
        /// The host's clock minus the iPad's (ns), from pings on the audio channel; nil until the first answer.
        var clockOffsetNs: Int64?
        var pingsSent: UInt32 = 0
        var packetsSincePing = 0
        /// How old a packet's sound is when it arrives (ms): smoothed, and the worst of the last few seconds.
        var arrivalMs = 0.0
        var worstArrivalMs = 0.0
        var worstResetAtNs: UInt64 = 0
    }

    /// How late the host's sound plays, in parts, for the panel.
    public struct Delay: Sendable, Equatable {
        /// From the host capturing a sound to its packet arriving (capture buffering and the network).
        public var arrivalMs: Double
        public var worstArrivalMs: Double
        /// Held in the jitter buffer before it plays, and how much it aims to hold (it follows the network).
        public var bufferedMs: Double
        public var targetMs: Double
        /// The iPad's own output path.
        public var outputMs: Double
        public var underruns: Int
        public var droppedMs: Double
        public var totalMs: Double { arrivalMs + bufferedMs + outputMs }
    }

    /// nil until sound is flowing and the clocks are lined up.
    public var delay: Delay? {
        let (buffer, config, offset, arrival, worst) = state.withLock { ($0.buffer, $0.config, $0.clockOffsetNs, $0.arrivalMs, $0.worstArrivalMs) }
        guard let buffer, let config, offset != nil else { return nil }
        let stats = buffer.stats, perMs = Double(config.sampleRate) / 1000
        var output = 0.0
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        output = (session.outputLatency + session.ioBufferDuration) * 1000
        #endif
        return Delay(arrivalMs: arrival, worstArrivalMs: worst, bufferedMs: Double(stats.bufferedFrames) / perMs, targetMs: Double(stats.targetFrames) / perMs, outputMs: output,
                     underruns: stats.underruns, droppedMs: Double(stats.dropped) / perMs)
    }
    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "lain.client.audio")
    private let log = Telemetry.logger("audio")

    public init() {
        // A route or session change stops the engine (dictation taking the microphone, headphones): start it again.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            guard let self, let engine = note.object as? AVAudioEngine, self.state.withLock({ $0.engine === engine }) else { return }
            self.queue.async { self.restart() }
        }
    }

    /// A message from the session's audio channel, on its queue; the player pings the host on `channel` to
    /// line the clocks up (nil: no delay reading).
    public func handle(_ message: Message, on channel: MessageChannel? = nil) {
        let now = MonotonicClock.now()
        switch message {
        case .audioConfig(let config):
            state.withLock { s in
                s.clockOffsetNs = nil
                s.packetsSincePing = 0
            }
            ping(channel, at: now)
            queue.async { self.configure(config) }
        case .audioPacket(let packet):
            let (buffer, muted, pingDue) = state.withLock { s -> (AudioJitterBuffer?, Bool, Bool) in
                if let offset = s.clockOffsetNs {
                    let age = Double(Int64(now) + offset - Int64(packet.captureTimeNs)) / 1e6
                    s.arrivalMs = s.arrivalMs == 0 ? age : s.arrivalMs * 0.95 + age * 0.05
                    if now - s.worstResetAtNs > 3_000_000_000 { s.worstArrivalMs = 0; s.worstResetAtNs = now }
                    s.worstArrivalMs = max(s.worstArrivalMs, age)
                }
                s.packetsSincePing += 1
                let due = s.packetsSincePing >= 100   // every couple of seconds: clocks drift
                if due { s.packetsSincePing = 0 }
                return (s.buffer, s.muted, due)
            }
            if pingDue { ping(channel, at: now) }
            if !muted { buffer?.push(packet.samples, at: now) }
        case .pong(let pong):
            // The host stamped the ping's arrival and its answer; half the round trip each way.
            let offset = (Int64(pong.receivedAtNs) - Int64(pong.pingSentAtNs) + Int64(pong.sentAtNs) - Int64(now)) / 2
            state.withLock { $0.clockOffsetNs = offset }
        default:
            break
        }
    }

    private func ping(_ channel: MessageChannel?, at now: UInt64) {
        guard let channel else { return }
        let id = state.withLock { s -> UInt32 in s.pingsSent &+= 1; return s.pingsSent }
        channel.send(.ping(Ping(id: id, sentAtNs: now)))
    }

    /// While muted (dictation is listening) the host's sound is dropped, so the microphone doesn't hear it.
    public func setMuted(_ muted: Bool) {
        let buffer = state.withLock { s -> AudioJitterBuffer? in
            s.muted = muted
            return s.buffer
        }
        buffer?.reset()
    }

    public var stats: AudioJitterBuffer.Stats? { state.withLock { $0.buffer }?.stats }

    private func configure(_ config: AudioConfig) {
        guard config.encoding == .pcm16LE, config.channels > 0, config.sampleRate > 0 else { return }
        if state.withLock({ $0.config == config && $0.engine?.isRunning == true }) {
            state.withLock { $0.buffer }?.reset()   // a new session in the same format
            return
        }
        stop()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(config.sampleRate), channels: AVAudioChannelCount(config.channels)) else { return }
        let buffer = AudioJitterBuffer(sampleRate: Int(config.sampleRate), channels: Int(config.channels))
        let engine = AVAudioEngine()
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var outputs: [UnsafeMutablePointer<Float>] = []
            for b in list { if let data = b.mData { outputs.append(data.assumingMemoryBound(to: Float.self)) } }
            buffer.pull(frames: Int(frameCount), into: outputs)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        state.withLock { s in
            s.engine = engine
            s.buffer = buffer
            s.config = config
        }
        start(engine)
    }

    private func start(_ engine: AVAudioEngine) {
        #if os(iOS)
        // Plays beside the iPad's own audio, with a short hardware buffer. Dictation switches the category for
        // the microphone and back (`Dictation`).
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
        #endif
        engine.prepare()
        do { try engine.start() } catch { log.error("the audio engine didn't start: \(String(describing: error), privacy: .public)") }
    }

    private func restart() {
        guard let engine = state.withLock({ $0.engine }), !engine.isRunning else { return }
        state.withLock { $0.buffer }?.reset()
        start(engine)
    }

    private func stop() {
        let engine = state.withLock { s -> AVAudioEngine? in
            defer { s.engine = nil; s.buffer = nil; s.config = nil }
            return s.engine
        }
        engine?.stop()
    }
}
