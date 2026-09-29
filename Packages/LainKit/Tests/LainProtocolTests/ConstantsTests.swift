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

/// The version parameters default to nil and read `majorVersion` in the body, so a caller's module can't
/// keep an old version from before a bump; an explicit version still goes through.
@Test func versionDefaultsResolveToTheMajorVersion() {
    let token = [UInt8](repeating: 1, count: ChannelHello.tokenSize), mac = [UInt8](repeating: 0, count: ChannelHello.macSize)
    #expect(ChannelHello(connectionKind: .video, sessionToken: token, hmac: mac).protocolVersion == LainProtocol.majorVersion)
    #expect(ChannelHello(protocolVersion: 1, connectionKind: .video, sessionToken: token, hmac: mac).protocolVersion == 1)
    let hello = Hello(deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                      decodeCapabilities: [.hevcMain], keyboardType: .ansi)
    #expect(hello.protocolVersion == LainProtocol.majorVersion)
    #expect(Hello(protocolVersion: 3, deviceModel: "iPad16,6", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                  decodeCapabilities: [.hevcMain], keyboardType: .ansi).protocolVersion == 3)
    #expect(FrameHeader(type: .ping, sequence: 0, timestampNs: 0, payloadLength: 0).version == LainProtocol.majorVersion)
    #expect(FrameHeader(version: 1, type: .ping, sequence: 0, timestampNs: 0, payloadLength: 0).version == 1)
    let ping = Message.ping(Ping(id: 1, sentAtNs: 2))
    #expect(MessageCodec.encode(ping, sequence: 0, timestampNs: 0)[2] == LainProtocol.majorVersion)   // the header's version byte
    #expect(MessageCodec.encode(ping, sequence: 0, timestampNs: 0, version: 1)[2] == 1)
}
