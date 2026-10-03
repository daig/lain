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

    @Test func channelHelloSizeFollowsItsVersionList() {
        let m = Samples.all.first { $0.type == .channelHello }!
        // count, two (version, digest[8]) entries, kind, token[16], hmac[32]
        #expect(MessageCodec.encode(m, sequence: 0, timestampNs: 0).count == FrameHeader.size + 1 + 2 * 9 + 1 + 16 + 32)
    }
}

@Suite struct HeaderValidation {
    let ping = MessageCodec.encode(.ping(Ping(id: 1, sentAtNs: 2)), sequence: 0x0102_0304, timestampNs: 0x1122_3344_5566_7788)

    @Test func layoutIsLittleEndianPerSpec() {
        #expect(Array(ping[0..<24]) == [
            0x41, 0x4C,                                      // magic 0x4C41
            LainProtocol.newestVersion, 0x05,                // version, type = Ping
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

    @Test func versionsThisBuildDoesntImplementAreReported() {
        for legacy in LainProtocol.legacyVersions {
            #expect(throws: ProtocolError.versionMismatch(remote: legacy)) { try MessageCodec.decode(mutated(2, legacy)) }
        }
        let newer = LainProtocol.newestVersion + 1
        #expect(throws: ProtocolError.versionMismatch(remote: newer)) { try MessageCodec.decode(mutated(2, newer)) }
        #expect(throws: ProtocolError.versionMismatch(remote: 0)) { try MessageCodec.decode(mutated(2, 0)) }
    }

    @Test func answersALegacyPeerInItsOwnVersion() throws {
        // An acceptor answers a v2 peer with Error(versionMismatch) in a v2 header, so the peer can read why.
        let why = "lain here speaks protocol v3–v4"
        let v2 = MessageCodec.legacyVersionMismatch(remote: 2, why: why, sequence: 0, timestampNs: 0)
        #expect(v2[2] == 2 && v2[3] == MessageType.error.rawValue)
        // v1/v2's ErrorMessage layout: u16 code, then a u16-prefixed UTF-8 message.
        #expect(Array(v2[FrameHeader.size...]) == [1, 0, UInt8(why.utf8.count), 0] + Array(why.utf8))
        #expect(throws: ProtocolError.versionMismatch(remote: 2)) { try MessageCodec.decode(v2) }
        // A legacy peer answering our handshake frames in our framing is readable here.
        var ours = v2
        ours[2] = LainProtocol.handshakeVersion
        #expect(try MessageCodec.decode(ours).message == .error(ErrorMessage(code: .versionMismatch, message: why)))
    }

    @Test func unknownAndReservedTypes() {
        #expect(throws: ProtocolError.unknownType(0x22)) { try MessageCodec.decode(mutated(3, 0x22)) }
        #expect(throws: ProtocolError.unknownType(0xFE)) { try MessageCodec.decode(mutated(3, 0xFE)) }
        // Defined in v1–v2 but never sent, so left out of v3 and reserved (PROTOCOL-VERSIONING §7).
        for pruned: UInt8 in [0x03, 0x04, 0x08, 0x09, 0x0A, 0x30, 0x31, 0x60, 0x61] {
            #expect(throws: ProtocolError.unknownType(pruned)) { try MessageCodec.decode(mutated(3, pruned)) }
        }
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
        var b = MessageCodec.encode(.releaseAll(ReleaseAll(reason: .focusLost)), sequence: 0, timestampNs: 0)
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
        var b = MessageCodec.encode(.displayLayout(DisplayLayout(displays: [])), sequence: 0, timestampNs: 0)
        b[24] = 0xFF   // 255 displays declared, none present
        #expect(throws: ProtocolError.truncated) { try MessageCodec.decode(b) }
    }
}

/// `Error` in both layers (PROTOCOL-VERSIONING §3.1): any code in a handshake frame, only known codes in
/// a session frame.
@Suite struct ErrorCodes {
    @Test func busyRoundTripsAndUnknownCodesOnlyPassInHandshakeFrames() throws {
        let busy = Message.error(ErrorMessage(code: .busy, message: "a USB session is live"))
        let bytes = MessageCodec.encode(busy, sequence: 0, timestampNs: 0)
        #expect(Array(bytes[24..<26]) == [6, 0])
        #expect(try MessageCodec.decode(bytes).message == busy)
        var unknown = bytes
        unknown[24] = 7
        #expect(throws: ProtocolError.malformed("error code 7")) { try MessageCodec.decode(unknown) }
        unknown[2] = LainProtocol.handshakeVersion   // a newer peer's refusal still arrives
        let decoded = try MessageCodec.decode(unknown)
        #expect(decoded.message == .error(ErrorMessage(code: ErrorMessage.Code(rawValue: 7), message: "a USB session is live")))
        #expect("\(ErrorMessage.Code(rawValue: 7))" == "code 7")
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
