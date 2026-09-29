#if os(macOS)
import LainMedia
import LainProtocol
import Testing

/// S3c at runtime: the embedded 64×64 HEVC Main 4:4:4 10 keyframe decodes in hardware on this Mac.
/// (The iPad's answer is verified by the owner on the device.)
struct DecodeProbeTests {
    @Test func embeddedVectorDecodesInHardwareAs444() {
        let result = DecodeProbe.run()
        #expect(result.status == 0)
        #expect(result.chromaFormatIDC == 3)
        #expect(result.hardware444)
        #expect(DecodeProbe.capabilities() == [.hevcMain, .hevcMain44410Hardware])
    }
}
#endif
