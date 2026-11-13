import Synchronization

/// The few tens of milliseconds of the host's sound that the iPad holds before playing it: what turns packets
/// that arrive unevenly into sound that doesn't stutter. Tuned for low delay and no stutter over fidelity.
///
/// It doesn't play until `target` frames have come (so one late packet doesn't make a gap). `target` follows
/// the network: each packet's lateness (how much longer it took to come than the sound it carries lasts) sets
/// the jitter, which is the worst lateness lately, fading over about 20 seconds; `target` is the floor plus
/// that. So a steady link (USB) plays about 40 ms behind, and a Wi-Fi link that stalls for 200 ms now and then
/// holds 200 ms more, which is what not stuttering costs there. If it runs dry anyway it plays silence, waits
/// for `target` again, and raises it a step. If more than twice `target` plus `slack` piles up (the host's
/// clock runs faster than the iPad's), the oldest sound is dropped down to `target`, so delay never builds up.
///
/// Samples are interleaved 16-bit. `push` is called from the network queue and `pull` from the audio render
/// thread; both take one short lock and never allocate once the store is made.
public final class AudioJitterBuffer: Sendable {
    public struct Stats: Sendable, Equatable {
        public var underruns = 0
        /// Frames dropped to hold the delay down.
        public var dropped = 0
        public var bufferedFrames = 0
        public var targetFrames = 0
    }

    private struct State {
        var store: [Int16]
        var channels: Int
        var read = 0
        var count = 0          // samples (frames × channels)
        var primed = false
        var target: Int        // frames
        let minTarget: Int, maxTarget: Int, step: Int, slack: Int
        let sampleRate: Int
        /// The worst lateness lately (frames), fading; and the step added by underruns, fading with it.
        var jitter = 0.0, bump = 0.0
        var lastPushNs: UInt64 = 0
        var stats = Stats()
    }
    private let state: Mutex<State>

    /// `targetMs`: sound held before playing starts; `maxTargetMs`: how far underruns may raise it;
    /// `slackMs`: how much beyond the target may pile up before the oldest is dropped.
    public init(sampleRate: Int, channels: Int, targetMs: Int = 40, maxTargetMs: Int = 400, stepMs: Int = 10, slackMs: Int = 80) {
        let perMs = Double(sampleRate) / 1000
        let frames = { (ms: Int) in Int(Double(ms) * perMs) }
        state = Mutex(State(store: [Int16](repeating: 0, count: max(sampleRate, 8_000) * 2 * max(channels, 1)), channels: max(channels, 1),
                            target: frames(targetMs), minTarget: frames(targetMs), maxTarget: frames(maxTargetMs),
                            step: frames(stepMs), slack: frames(slackMs), sampleRate: sampleRate))
    }

    public var stats: Stats {
        state.withLock { s in
            var out = s.stats
            out.bufferedFrames = s.count / s.channels
            out.targetFrames = s.target
            return out
        }
    }

    /// Interleaved 16-bit little-endian PCM from a packet. `timeNs`: when it arrived (a monotonic clock), from
    /// which the target follows the network's jitter; nil leaves the target alone.
    public func push(_ bytes: [UInt8], at timeNs: UInt64? = nil) {
        state.withLock { s in
            let incoming = bytes.count / 2
            guard incoming > 0 else { return }
            if let timeNs {
                let frames = Double(incoming / s.channels)
                // Fade over about 20 s of sound, then take this packet's lateness if it is worse.
                let fade = 1 - frames / (20 * Double(s.sampleRate))
                s.jitter *= fade
                s.bump *= fade
                if s.lastPushNs != 0, timeNs > s.lastPushNs {
                    let gap = Double(timeNs - s.lastPushNs) / 1e9 * Double(s.sampleRate)
                    if gap < 2 * Double(s.sampleRate) { s.jitter = max(s.jitter, gap - frames) }   // not across a pause
                }
                s.lastPushNs = timeNs
                s.target = min(s.minTarget + Int(s.jitter + s.bump), s.maxTarget)
            }
            let capacity = s.store.count
            bytes.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Int16.self)
                var write = (s.read + s.count) % capacity
                for i in 0..<min(incoming, capacity) {
                    s.store[write] = Int16(littleEndian: src[i])
                    write = (write + 1) % capacity
                }
            }
            s.count += min(incoming, capacity)
            if s.count > capacity {   // overran the store itself: the oldest was overwritten
                s.read = (s.read + s.count - capacity) % capacity
                s.count = capacity
            }
            let limit = (2 * s.target + s.slack) * s.channels
            if s.count > limit {
                let drop = s.count - s.target * s.channels
                s.read = (s.read + drop) % capacity
                s.count -= drop
                s.stats.dropped += drop / s.channels
            }
        }
    }

    /// Fills `frames` frames of each of `outputs` (one buffer per channel, floats in −1…1), with silence where
    /// there is no sound to play. A host channel beyond the outputs is skipped; an output beyond the host's
    /// channels repeats the last one.
    public func pull(frames: Int, into outputs: [UnsafeMutablePointer<Float>]) {
        state.withLock { s in
            if !s.primed, s.count >= s.target * s.channels { s.primed = true }
            let available = s.primed ? min(frames, s.count / s.channels) : 0
            let capacity = s.store.count
            for i in 0..<available {
                let base = (s.read + i * s.channels) % capacity
                for (c, out) in outputs.enumerated() {
                    out[i] = Float(s.store[(base + min(c, s.channels - 1)) % capacity]) / 32768
                }
            }
            for out in outputs where available < frames {
                for i in available..<frames { out[i] = 0 }
            }
            s.read = (s.read + available * s.channels) % capacity
            s.count -= available * s.channels
            if s.primed, available < frames {   // ran dry: wait for a fuller buffer next time
                s.primed = false
                s.stats.underruns += 1
                s.bump += Double(s.step)
                s.target = min(s.target + s.step, s.maxTarget)
            }
        }
    }

    /// Forgets what is held (a new session, or muting): playing starts again from a full target.
    public func reset() {
        state.withLock { s in
            s.read = 0
            s.count = 0
            s.primed = false
            s.target = s.minTarget
            s.jitter = 0
            s.bump = 0
            s.lastPushNs = 0
        }
    }
}
