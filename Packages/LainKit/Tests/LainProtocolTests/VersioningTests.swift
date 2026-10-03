import Foundation
import Testing
@testable import LainProtocol

private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

private func unhex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}

/// The layers every frame version admits (header 0xFF: the frozen handshake; otherwise a session version).
private let frameVersions: [UInt8] = [LainProtocol.handshakeVersion] + LainProtocol.supportedVersions

/// PROTOCOL-VERSIONING §9: the bytes every message has at every version, recorded once and then frozen.
@Suite struct GoldenBytesTests {
    @Test func everyMessageHasFrozenBytesAtEveryVersion() throws {
        let record = ProcessInfo.processInfo.environment["LAIN_RECORD_GOLDEN"] == "1"
        var bytes = Golden.bytes, digests = Golden.digests, added: [String] = []
        for v in frameVersions {
            for message in Samples.all where message.type.exists(in: v) {
                let key = "\(message.type)"
                let encoded = hex(MessageCodec.encode(message, sequence: 0, timestampNs: 0, version: v))
                if let golden = bytes[v]?[key] {
                    #expect(encoded == golden, "v\(v) \(key) no longer encodes as recorded: released bytes never change")
                } else if record {
                    bytes[v, default: [:]][key] = encoded
                    added.append("v\(v) \(key)")
                } else {
                    Issue.record("no golden bytes for v\(v) \(key): LAIN_RECORD_GOLDEN=1 swift test --filter GoldenBytesTests")
                }
            }
        }
        for v in LainProtocol.supportedVersions {
            let digest = hex(SchemaDigest.compute(version: v))
            if let pinned = digests[v] {
                #expect(digest == pinned, "v\(v)'s digest changed: its wire format changed")
            } else if record {
                digests[v] = digest
                added.append("v\(v) digest")
            } else {
                Issue.record("no pinned digest for v\(v): LAIN_RECORD_GOLDEN=1 swift test --filter GoldenBytesTests")
            }
        }
        // Every recorded version is still supported (raising the floor deletes its entries).
        #expect(Set(bytes.keys) == Set(frameVersions))
        guard record, !added.isEmpty else { return }
        try Self.write(bytes: bytes, digests: digests)
        Issue.record("recorded \(added.count) new entries (\(added.joined(separator: ", "))): review and commit GoldenBytes.swift")
    }

    /// Lowering is exact on lift's image: decoding the golden bytes and encoding again gives them back,
    /// so decoding (lift) is injective. And the lifted value is a valid newest-version message.
    @Test func liftIsInjectiveAndLandsInTheModel() throws {
        for (v, messages) in Golden.bytes {
            for (key, golden) in messages {
                let bytes = unhex(golden)
                let lifted = try MessageCodec.decode(bytes)
                #expect(lifted.header.version == v)
                #expect(MessageCodec.encode(lifted.message, sequence: 0, timestampNs: 0, version: v) == bytes, "v\(v) \(key)")
                let newest = lifted.message.type.defaultVersion
                let again = try MessageCodec.decode(MessageCodec.encode(lifted.message, sequence: 0, timestampNs: 0, version: newest))
                #expect(again.message == lifted.message, "v\(v) \(key)")
            }
        }
    }

    private static func write(bytes: [UInt8: [String: String]], digests: [UInt8: String]) throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("GoldenBytes.swift")
        var out = """
        // Recorded by `GoldenBytesTests` (LAIN_RECORD_GOLDEN=1 swift test --filter GoldenBytesTests), which only
        // ever adds entries. A released version's entries never change; raising the floor deletes its entries
        // by hand (PROTOCOL-VERSIONING §6). Key 255: the frozen handshake layer.
        enum Golden {
            static let bytes: [UInt8: [String: String]] = [

        """
        for v in bytes.keys.sorted() {
            out += "        \(v): [\n"
            for key in bytes[v]!.keys.sorted() { out += "            \"\(key)\": \"\(bytes[v]![key]!)\",\n" }
            out += "        ],\n"
        }
        out += "    ]\n    static let digests: [UInt8: String] = [\n"
        for v in digests.keys.sorted() { out += "        \(v): \"\(digests[v]!)\",\n" }
        out += "    ]\n}\n"
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
}

@Suite struct Layers {
    @Test func handshakeMessagesExistOnlyInHandshakeFrames() {
        for type in MessageType.allCases {
            #expect(type.exists(in: LainProtocol.handshakeVersion) == type.isHandshake, "\(type)")
            for v in LainProtocol.supportedVersions {
                #expect(type.exists(in: v) == (type.isSession && type.since <= v), "\(type) v\(v)")
            }
        }
        #expect(MessageType.error.isHandshake && MessageType.error.isSession)
    }

    @Test func hostSetupIsAVersionFourMessage() throws {
        let setup = Samples.all.first { $0.type == .hostSetup }!
        #expect(MessageCodec.lower(setup, to: 3, sequence: 0, timestampNs: 0) == .unrepresentable("hostSetup doesn't exist in v3"))
        #expect(MessageCodec.lower(setup, to: 4, sequence: 0, timestampNs: 0).bytes != nil)
        var v3 = MessageCodec.encode(setup, sequence: 0, timestampNs: 0, version: 4)
        v3[2] = 3   // a v3 peer never sends it, and a v3 frame can't carry it
        #expect(throws: ProtocolError.unknownType(MessageType.hostSetup.rawValue)) { try MessageCodec.decode(v3) }
    }

    @Test func sessionMessagesCantBeHandshakeFramedAndViceVersa() {
        var ping = MessageCodec.encode(.ping(Ping(id: 1, sentAtNs: 2)), sequence: 0, timestampNs: 0)
        ping[2] = LainProtocol.handshakeVersion
        #expect(throws: ProtocolError.unknownType(MessageType.ping.rawValue)) { try MessageCodec.decode(ping) }
        let hello = Samples.all.first { $0.type == .channelHello }!
        var framed = MessageCodec.encode(hello, sequence: 0, timestampNs: 0)
        framed[2] = 3
        #expect(throws: ProtocolError.unknownType(MessageType.channelHello.rawValue)) { try MessageCodec.decode(framed) }
    }
}

@Suite struct VersionLists {
    func list(_ entries: (UInt8, UInt8)...) -> VersionList {
        VersionList(entries.map { VersionEntry(version: $0.0, digest: [UInt8](repeating: $0.1, count: 8)) })
    }

    @Test func theHighestVersionWithEqualDigestsIsCommon() {
        #expect(list((3, 1), (4, 1)).highestCommon(with: list((4, 1), (5, 1))) == 4)
        #expect(list((3, 1), (4, 1)).highestCommon(with: list((3, 1), (4, 2))) == 3)   // two builds of v4
        #expect(list((3, 1)).highestCommon(with: list((4, 1))) == nil)
        #expect(list((3, 1), (4, 1)).conflicting(with: list((3, 1), (4, 2))) == [4])
    }

    @Test func aCapKeepsAtLeastTheOldest() {
        #expect(list((3, 1), (4, 1)).capped(at: 3).versions == [3])
        #expect(list((3, 1), (4, 1)).capped(at: 2).versions == [3])
        #expect(list((3, 1), (4, 1)).capped(at: nil).versions == [3, 4])
        #expect("\(list((3, 1), (4, 1)))" == "v3–v4" && "\(list((4, 1)))" == "v4")
    }

    @Test func theSupportedListCarriesThisBuildsDigests() {
        #expect(VersionList.supported.versions == LainProtocol.supportedVersions)
        for e in VersionList.supported.entries { #expect(e.digest == SchemaDigest.compute(version: e.version)) }
        #expect(SchemaDigest.compute(version: 3) != SchemaDigest.compute(version: 4))
    }

    @Test func decodingIsStrict() {
        func decode(_ bytes: [UInt8]) throws(ProtocolError) -> VersionList {
            var r = ByteReader(bytes, version: LainProtocol.handshakeVersion)
            return try r.versionList()
        }
        let digest = [UInt8](repeating: 1, count: 8)
        #expect(throws: ProtocolError.malformed("17 versions")) { try decode([17]) }
        #expect(throws: ProtocolError.malformed("version list")) { try decode([2, 4] + digest + [3] + digest) }   // descending
        #expect(throws: ProtocolError.malformed("version list")) { try decode([2, 3] + digest + [3] + digest) }   // repeated
        #expect(throws: ProtocolError.malformed("version list")) { try decode([1, 0] + digest) }
        #expect(throws: ProtocolError.malformed("version list")) { try decode([1, 0xFF] + digest) }
        #expect(throws: ProtocolError.truncated) { try decode([1, 3, 1, 2]) }
    }

    @Test func anAcceptMustChooseFromItsOwnList() {
        var w = ByteWriter(version: LainProtocol.handshakeVersion)
        ChannelAccept(chosen: 4, versions: list((3, 1))).encode(into: &w)
        var r = ByteReader(w.bytes, version: LainProtocol.handshakeVersion)
        #expect(throws: ProtocolError.malformed("chose v4 outside its list")) { try ChannelAccept(from: &r) }
    }
}

/// A field added in v4 to a message that exists from v3: the per-field lift and lower rules.
struct Widget: WireMessage, Equatable {
    static let type = MessageType.ping   // unused: these tests call encode/init directly
    var id: UInt32
    var hint: String = ""      // v4, advisory: dropped for v3
    var limit: UInt16 = 0      // v4, required: refused for v3

    func encode(into w: inout ByteWriter) {
        w.u32(id)
        w.since(4, "hint", hint, default: "", lowering: .drop) { $0.string($1) }
        w.since(4, "limit", limit, default: 0, lowering: .refuse) { $0.u16($1) }
    }

    init(id: UInt32, hint: String = "", limit: UInt16 = 0) { self.id = id; self.hint = hint; self.limit = limit }

    init(from r: inout ByteReader) throws(ProtocolError) {
        id = try r.u32()
        hint = try r.since(4, default: "") { r throws(ProtocolError) in try r.string() }
        limit = try r.since(4, default: 0) { r throws(ProtocolError) in try r.u16() }
    }
}

@Suite struct FieldsAddedLater {
    func encode(_ w: Widget, at version: UInt8) -> ByteWriter {
        var writer = ByteWriter(version: version)
        w.encode(into: &writer)
        return writer
    }

    @Test func anOlderVersionGetsTheOldLayoutAndDefaultsComeBack() throws {
        let old = encode(Widget(id: 7), at: 3)
        #expect(old.bytes == [7, 0, 0, 0] && old.dropped.isEmpty && old.refused == nil)
        var r = ByteReader(old.bytes, version: 3)
        #expect(try Widget(from: &r) == Widget(id: 7))   // lift: the new fields at their defaults
        let new = encode(Widget(id: 7, hint: "x", limit: 2), at: 4)
        var r4 = ByteReader(new.bytes, version: 4)
        #expect(try Widget(from: &r4) == Widget(id: 7, hint: "x", limit: 2))
    }

    @Test func advisoryValuesAreDroppedAndRequiredOnesRefused() {
        let dropped = encode(Widget(id: 7, hint: "x"), at: 3)
        #expect(dropped.bytes == [7, 0, 0, 0] && dropped.dropped == ["hint"] && dropped.refused == nil)
        let refused = encode(Widget(id: 7, limit: 2), at: 3)
        #expect(refused.refused == "limit doesn't exist in v3")
    }
}

@Suite struct Features {
    @Test func featuresFollowTheirVersions() {
        #expect(!ProtocolFeature.hostSetup.isSupported(at: 3))
        #expect(ProtocolFeature.hostSetup.isSupported(at: 4))
        #expect(ProtocolFeature.missing(at: 3) == [.hostSetup])
        #expect(ProtocolFeature.missing(at: LainProtocol.newestVersion).isEmpty)
    }

    /// A feature replaced before the oldest supported version is dead compatibility code: delete it.
    @Test func noFeatureOutlivesTheFloor() {
        for feature in ProtocolFeature.allCases {
            if let until = feature.until { #expect(until > LainProtocol.supportedVersions[0], "\(feature) is dead: delete it") }
        }
    }
}
