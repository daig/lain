import Testing
@testable import LainProtocol

@Test func magicIsLAInLittleEndian() {
    let bytes = withUnsafeBytes(of: LainProtocol.magic.littleEndian, Array.init)
    #expect(bytes == [0x41, 0x4C])
    #expect(LainProtocol.headerSize == 24)
}
