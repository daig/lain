import Testing
@testable import LainProtocol

@Suite struct MessageRoundTrip {
    @Test func samplesCoverEveryMessageType() {
        #expect(Set(Samples.all.map(\.type)) == Set(MessageType.allCases))
    }

    @Test(arguments: Samples.all)
    func roundTrips(_ message: Message) throws {
        let bytes = MessageCodec.encode(message, sequence: 42, timestampNs: 987_654_321)
        let env = try MessageCodec.decode(bytes)
        #expect(env.message == message)
        #expect(env.header.type == message.type)
        #expect(env.header.sequence == 42)
        #expect(env.header.timestampNs == 987_654_321)
        #expect(Int(env.header.payloadLength) == bytes.count - FrameHeader.size)
    }

    @Test(arguments: Samples.all)
    func everyTruncationIsRejected(_ message: Message) {
        let bytes = MessageCodec.encode(message, sequence: 1, timestampNs: 1)
        for n in 0..<bytes.count {
            #expect(throws: ProtocolError.self) { try MessageCodec.decode(Array(bytes.prefix(n))) }
        }
    }

    @Test(arguments: Samples.all)
    func truncatedPayloadWithConsistentLengthIsRejected(_ message: Message) throws {
        // The header claims a shorter payload (as if the sender were buggy): the payload decoder must
        // hit the end of its slice rather than read into the next message.
        var bytes = MessageCodec.encode(message, sequence: 1, timestampNs: 1)
        let payloadLength = bytes.count - FrameHeader.size
        guard payloadLength > 0 else { return }
        bytes.removeLast()
        withUnsafeBytes(of: UInt32(payloadLength - 1).littleEndian) { bytes.replaceSubrange(20..<24, with: $0) }
        #expect(throws: ProtocolError.self) { try MessageCodec.decode(bytes) }
    }

    @Test func keyframeFlagFollowsPayload() throws {
        let key = Samples.all.first { $0.type == .videoFrame }!
        #expect(try MessageCodec.decode(MessageCodec.encode(key, sequence: 0, timestampNs: 0)).header.flags == .keyframe)
        #expect(try MessageCodec.decode(MessageCodec.encode(.ping(Ping(id: 1, sentAtNs: 2)), sequence: 0,
                                                            timestampNs: 0)).header.flags == [])
    }

    @Test func channelHelloIsFixedSize() {
        let m = Samples.all.first { $0.type == .channelHello }!
        #expect(MessageCodec.encode(m, sequence: 0, timestampNs: 0).count == FrameHeader.size + 50)
    }
}

@Suite struct HeaderValidation {
    let ping = MessageCodec.encode(.ping(Ping(id: 1, sentAtNs: 2)), sequence: 0x0102_0304, timestampNs: 0x1122_3344_5566_7788)

    @Test func layoutIsLittleEndianPerSpec() {
        #expect(Array(ping[0..<24]) == [
            0x41, 0x4C,                                      // magic 0x4C41
            LainProtocol.majorVersion, 0x05,                 // version, type = Ping
            0x00, 0x00, 0x00, 0x00,                          // flags, reserved
            0x04, 0x03, 0x02, 0x01,                          // sequence
            0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,  // timestamp
            12, 0, 0, 0,                                     // payload length
        ])
    }

    func mutated(_ offset: Int, _ value: UInt8) -> [UInt8] { var b = ping; b[offset] = value; return b }

    @Test func badMagic() {
        #expect(throws: ProtocolError.badMagic(0x4C42)) { try MessageCodec.decode(mutated(0, 0x42)) }
    }

    @Test func versionMismatchIsReported() {
        let newer = LainProtocol.majorVersion + 1
        #expect(throws: ProtocolError.versionMismatch(remote: newer)) { try MessageCodec.decode(mutated(2, newer)) }
    }

    @Test func encodesInAMismatchedPeersVersion() {
        // An acceptor answers a v1 peer with Error(versionMismatch) in a v1 header, so the peer can read why.
        let why = "host speaks v2"
        let error = Message.error(ErrorMessage(code: .versionMismatch, message: why))
        let v1 = MessageCodec.encode(error, sequence: 0, timestampNs: 0, version: 1)
        #expect(v1[2] == 1)
        var ours = v1
        ours[2] = LainProtocol.majorVersion
        #expect(ours == MessageCodec.encode(error, sequence: 0, timestampNs: 0))   // only the version byte differs
        // v1's ErrorMessage layout: u16 code, then a u16-prefixed UTF-8 message.
        #expect(Array(v1[FrameHeader.size...]) == [1, 0, UInt8(why.utf8.count), 0] + Array(why.utf8))
        #expect(throws: ProtocolError.versionMismatch(remote: 1)) { try MessageCodec.decode(v1) }
        var parser = FrameParser()
        parser.append(v1)
        #expect(throws: ProtocolError.versionMismatch(remote: 1)) { try parser.next() }
    }

    @Test func unknownAndReservedTypes() {
        #expect(throws: ProtocolError.unknownType(0x22)) { try MessageCodec.decode(mutated(3, 0x22)) }
        #expect(throws: ProtocolError.unknownType(0xFF)) { try MessageCodec.decode(mutated(3, 0xFF)) }
    }

    @Test func reservedFieldMustBeZero() {
        #expect(throws: ProtocolError.reservedNonZero) { try MessageCodec.decode(mutated(6, 1)) }
    }

    @Test func oversizedPayloadIsRejectedBeforeBuffering() {
        #expect(throws: ProtocolError.payloadTooLarge(0xFF00_000C)) { try MessageCodec.decode(mutated(23, 0xFF)) }
    }

    @Test func trailingBytesAreRejected() {
        var b = ping + [0]
        b[20] += 1
        #expect(throws: ProtocolError.malformed("1 trailing bytes")) { try MessageCodec.decode(b) }
    }
}

@Suite struct PayloadValidation {
    @Test func unknownEnumValue() {
        var b = MessageCodec.encode(.stop(Stop(reason: .userRequested)), sequence: 0, timestampNs: 0)
        b[24] = 9
        #expect(throws: ProtocolError.self) { try MessageCodec.decode(b) }
    }

    @Test func boolMustBeZeroOrOne() {
        var b = MessageCodec.encode(.cursorSelect(CursorSelect(shapeId: 1, visible: true)), sequence: 0, timestampNs: 0)
        b[28] = 2
        #expect(throws: ProtocolError.malformed("bool")) { try MessageCodec.decode(b) }
    }

    @Test func cursorPixelCountMustMatchSize() {
        let bad = CursorShape(shapeId: 1, pixelWidth: 4, pixelHeight: 4, scale: 2, hotspotX: 0, hotspotY: 0, pixels: [0])
        #expect(throws: ProtocolError.malformed("cursor pixel count")) {
            try MessageCodec.decode(MessageCodec.encode(.cursorShape(bad), sequence: 0, timestampNs: 0))
        }
    }

    @Test func invalidUTF8() {
        var b = MessageCodec.encode(.error(ErrorMessage(code: .internal, message: "ab")), sequence: 0, timestampNs: 0)
        b[b.count - 1] = 0xFF
        #expect(throws: ProtocolError.malformed("utf8")) { try MessageCodec.decode(b) }
    }

    @Test func hugeDeclaredCountIsTruncatedNotAllocated() {
        var w = ByteWriter()
        w.u16(0xFFFF)   // 65535 stat entries declared, none present
        var b = MessageCodec.encode(.stats(Stats(entries: [])), sequence: 0, timestampNs: 0)
        b.replaceSubrange(24..., with: w.bytes)
        b[20] = 2
        #expect(throws: ProtocolError.truncated) { try MessageCodec.decode(b) }
    }
}

/// Protocol v2 (M6a). A v1 peer is refused by the header version first (`HeaderValidation`); these
/// document that v1's payloads don't decode either, and the new `Error` code.
@Suite struct VersionTwoPayloads {
    @Test func v1HelloAckNoLongerDecodes() {
        // v1's HelloAck ended at `macInputSource`.
        var v1 = ByteWriter()
        v1.u8(VideoCodec.hevc.rawValue); v1.u8(ChromaFormat.yuv444.rawValue); v1.u8(10); v1.u8(DisplayMode.extend.rawValue)
        v1.u32(60_000_000); v1.u16(120); v1.u32(1376); v1.u32(1032); v1.u32(48_000); v1.u8(2)
        v1.u8(AudioEncoding.pcm16LE.rawValue); v1.u32(500); v1.u32(225); v1.u32(30); v1.string("com.apple.keylayout.Colemak")
        var v2 = ByteWriter()
        HelloAck(codec: .hevc, chroma: .yuv444, bitDepth: 10, displayMode: .extend, bitrate: 60_000_000, refreshRate: 120,
                 displayPointWidth: 1376, displayPointHeight: 1032, audioSampleRate: 48_000, audioChannels: 2,
                 audioEncoding: .pcm16LE, doubleClickIntervalMs: 500, keyRepeatDelayMs: 225, keyRepeatIntervalMs: 30,
                 macInputSource: "com.apple.keylayout.Colemak").encode(into: &v2)
        #expect(v2.bytes == v1.bytes + [0, 0, 0, 0])   // the same values in v2: plus two (here empty) strings
        #expect(throws: ProtocolError.truncated) { try Message.decode(type: .helloAck, payload: v1.bytes[...]) }
    }

    @Test func v1PairNoLongerDecodes() {
        let v1: [UInt8] = Array(200..<232)   // v1's Pair: the 32-byte secret alone
        #expect(throws: ProtocolError.truncated) { try Message.decode(type: .pair, payload: v1[...]) }
    }

    @Test func errorBusyRoundTrips() throws {
        let busy = Message.error(ErrorMessage(code: .busy, message: "a USB session is live"))
        let bytes = MessageCodec.encode(busy, sequence: 0, timestampNs: 0)
        #expect(Array(bytes[24..<26]) == [6, 0])
        #expect(try MessageCodec.decode(bytes).message == busy)
        var unknown = bytes
        unknown[24] = 7   // an unknown code is fatal: new codes need a new major version
        #expect(throws: ProtocolError.malformed("error code 7")) { try MessageCodec.decode(unknown) }
    }
}

@Suite struct StreamParsing {
    let stream: [UInt8] = Samples.all.enumerated().flatMap { i, m in
        MessageCodec.encode(m, sequence: UInt32(i), timestampNs: UInt64(i) * 10)
    }

    func parse(chunkSize: Int) throws -> [Envelope] {
        var parser = FrameParser()
        var out: [Envelope] = []
        var i = 0
        while i < stream.count {
            parser.append(stream[i..<min(i + chunkSize, stream.count)])
            i += chunkSize
            while let env = try parser.next() { out.append(env) }
        }
        #expect(parser.bufferedByteCount == 0)
        return out
    }

    @Test(arguments: [1, 7, 24, 25, 1000, 1 << 20])
    func reassemblesAnyChunking(chunkSize: Int) throws {
        let got = try parse(chunkSize: chunkSize)
        #expect(got.map(\.message) == Samples.all)
        #expect(got.map(\.header.sequence) == Array(0..<UInt32(Samples.all.count)))
    }

    @Test func garbageIsFatal() {
        var parser = FrameParser()
        parser.append([UInt8](repeating: 0xAB, count: 30))
        #expect(throws: ProtocolError.badMagic(0xABAB)) { try parser.next() }
    }
}
