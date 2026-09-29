import Testing
@testable import LainProtocol

@Test func magicIsLAInLittleEndian() {
    let bytes = withUnsafeBytes(of: LainProtocol.magic.littleEndian, Array.init)
    #expect(bytes == [0x41, 0x4C])
    #expect(LainProtocol.headerSize == 24)
}

@Test func versionAndBonjourService() {
    #expect(LainProtocol.majorVersion == 2)   // M6a: HelloAck and Pair carry the host id, Error busy
    #expect(LainProtocol.bonjourServiceType == "_lain._tcp")   // the client's NSBonjourServices must list it
}
