import Testing
@testable import LainProtocol

@Test func magicIsLAInLittleEndian() {
    let bytes = withUnsafeBytes(of: LainProtocol.magic.littleEndian, Array.init)
    #expect(bytes == [0x41, 0x4C])
    #expect(LainProtocol.headerSize == 24)
}

@Test func versionsAndBonjourService() {
    // PROTOCOL-VERSIONING §2.3: the newest and the previous version until a public release.
    #expect(LainProtocol.supportedVersions == [3, 4])
    #expect(LainProtocol.newestVersion == 4)
    #expect(LainProtocol.handshakeVersion == 0xFF)
    #expect(LainProtocol.legacyVersions.upperBound < LainProtocol.supportedVersions[0])
    #expect(LainProtocol.bonjourServiceType == "_lain._tcp")   // the client's NSBonjourServices must list it
}

/// Version parameters default to nil and read the constants in the body, so a caller's module can't keep
/// an old value from before a change (D30); an explicit version still goes through.
@Test func versionDefaultsResolveInTheBody() {
    let token = [UInt8](repeating: 1, count: ChannelHello.tokenSize), mac = [UInt8](repeating: 0, count: ChannelHello.macSize)
    #expect(ChannelHello(connectionKind: .video, sessionToken: token, hmac: mac).versions == VersionList.offered)
    #expect(FrameHeader(type: .ping, sequence: 0, timestampNs: 0, payloadLength: 0).version == LainProtocol.newestVersion)
    #expect(FrameHeader(type: .channelHello, sequence: 0, timestampNs: 0, payloadLength: 0).version == LainProtocol.handshakeVersion)
    #expect(FrameHeader(version: 3, type: .ping, sequence: 0, timestampNs: 0, payloadLength: 0).version == 3)
    let ping = Message.ping(Ping(id: 1, sentAtNs: 2))
    #expect(MessageCodec.encode(ping, sequence: 0, timestampNs: 0)[2] == LainProtocol.newestVersion)   // the header's version byte
    #expect(MessageCodec.encode(ping, sequence: 0, timestampNs: 0, version: 3)[2] == 3)
    #expect(ByteWriter().version == LainProtocol.newestVersion)
    #expect(ByteReader([UInt8]()).version == LainProtocol.newestVersion)
}
