import LainClientCore
import Testing

@Suite struct AudioJitterBufferTests {
    /// 1000 Hz, so a frame is a millisecond; mono.
    private func buffer(target: Int = 40) -> AudioJitterBuffer {
        AudioJitterBuffer(sampleRate: 1000, channels: 1, targetMs: target, maxTargetMs: 400, stepMs: 10, slackMs: 80)
    }
    private func packet(_ frames: Int, value: Int16 = 16384) -> [UInt8] {
        (0..<frames).flatMap { _ in [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)] }
    }
    private func pull(_ b: AudioJitterBuffer, _ frames: Int) -> [Float] {
        var out = [Float](repeating: 9, count: frames)
        out.withUnsafeMutableBufferPointer { b.pull(frames: frames, into: [$0.baseAddress!]) }
        return out
    }

    @Test func silenceUntilTheTargetHasCome() {
        let b = buffer()
        b.push(packet(30))
        #expect(pull(b, 10) == [Float](repeating: 0, count: 10), "30 ms held, 40 wanted")
        #expect(b.stats.bufferedFrames == 30 && b.stats.underruns == 0)
        b.push(packet(10))
        #expect(pull(b, 10) == [Float](repeating: 0.5, count: 10))
        #expect(b.stats.bufferedFrames == 30)
    }

    @Test func runningDryPlaysSilenceThenWaitsForAFullerBuffer() {
        let b = buffer()
        b.push(packet(40))
        let out = pull(b, 50)
        #expect(Array(out[0..<40]) == [Float](repeating: 0.5, count: 40) && Array(out[40...]) == [Float](repeating: 0, count: 10))
        #expect(b.stats.underruns == 1 && b.stats.targetFrames == 50)
        b.push(packet(45))
        #expect(pull(b, 5) == [Float](repeating: 0, count: 5), "below the raised target")
        b.push(packet(5))
        #expect(pull(b, 5) == [Float](repeating: 0.5, count: 5))
    }

    @Test func aPileUpIsDroppedDownToTheTarget() {
        let b = buffer()
        b.push(packet(160))
        #expect(b.stats.bufferedFrames == 160 && b.stats.dropped == 0, "within twice the target and the slack")
        b.push(packet(30, value: 8192))
        #expect(b.stats.bufferedFrames == 40 && b.stats.dropped == 150, "the oldest goes")
        let out = pull(b, 40)
        #expect(out.first == 0.5 && out.last == 0.25, "what is left is the newest")
    }

    @Test func stereoIsDeinterleavedAndMonoFillsBothOutputs() {
        let stereo = AudioJitterBuffer(sampleRate: 1000, channels: 2, targetMs: 1)
        stereo.push([0x00, 0x40, 0x00, 0xC0, 0x00, 0x20, 0x00, 0xE0])   // L 0.5 R −0.5, L 0.25 R −0.25
        var l = [Float](repeating: 9, count: 2), r = l
        l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
            stereo.pull(frames: 2, into: [lp.baseAddress!, rp.baseAddress!])
        } }
        #expect(l == [0.5, 0.25] && r == [-0.5, -0.25])
        let mono = buffer(target: 1)
        mono.push(packet(1))
        var a = [Float](repeating: 9, count: 1), c = a
        a.withUnsafeMutableBufferPointer { ap in c.withUnsafeMutableBufferPointer { cp in
            mono.pull(frames: 1, into: [ap.baseAddress!, cp.baseAddress!])
        } }
        #expect(a == [0.5] && c == [0.5])
    }

    @Test func resetStartsOverAtTheFirstTarget() {
        let b = buffer()
        b.push(packet(40))
        _ = pull(b, 50)
        b.push(packet(60))
        b.reset()
        #expect(b.stats.bufferedFrames == 0 && b.stats.targetFrames == 40)
        #expect(pull(b, 5) == [Float](repeating: 0, count: 5))
    }

    @Test func theTargetFollowsTheNetworksJitterAndComesBackDown() {
        let b = buffer()
        let ms: UInt64 = 1_000_000
        var t: UInt64 = 1_000 * ms
        // Steady: a 20 ms packet every 20 ms.
        for _ in 0..<50 { b.push(packet(20), at: t); _ = pull(b, 20); t += 20 * ms }
        #expect(b.stats.targetFrames == 40, "nothing late: the floor")
        // One packet 200 ms late (a stall of the radio).
        t += 200 * ms
        b.push(packet(20), at: t)
        #expect(b.stats.targetFrames >= 235 && b.stats.targetFrames <= 240, "the floor plus the lateness")
        // A minute of steady packets: it fades back.
        for _ in 0..<3_000 { t += 20 * ms; b.push(packet(20), at: t); _ = pull(b, 20) }
        #expect(b.stats.targetFrames < 60)
        // A pause in the sound (nothing sent for seconds) isn't lateness.
        t += 5_000 * ms
        let before = b.stats.targetFrames
        b.push(packet(20), at: t)
        #expect(b.stats.targetFrames <= before)
    }
}
