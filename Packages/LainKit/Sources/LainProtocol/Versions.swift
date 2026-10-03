import CryptoKit
import Foundation

/// One protocol version and the digest of its wire format (PROTOCOL-VERSIONING §3.2).
public struct VersionEntry: Sendable, Hashable {
    public static let digestSize = 8
    public var version: UInt8
    public var digest: [UInt8]
    public init(version: UInt8, digest: [UInt8]) {
        precondition(digest.count == Self.digestSize)
        self.version = version
        self.digest = digest
    }
}

/// The versions one side supports, oldest first, as carried by `ChannelHello` and `ChannelAccept`. A
/// version is common to two lists only if its digests match too, so two builds of a version still under
/// development (or a stale build) don't count as speaking it.
public struct VersionList: Sendable, Hashable, CustomStringConvertible {
    public static let maxCount = 16
    public private(set) var entries: [VersionEntry]

    /// Sorts by version; one entry per version (the first wins).
    public init(_ entries: [VersionEntry]) {
        var seen = Set<UInt8>()
        self.entries = entries.sorted { $0.version < $1.version }.filter { seen.insert($0.version).inserted }
    }

    public var versions: [UInt8] { entries.map(\.version) }
    public var newest: UInt8? { entries.last?.version }
    public var oldest: UInt8? { entries.first?.version }
    public var isEmpty: Bool { entries.isEmpty }

    /// The highest version in both lists with equal digests: what a session runs at.
    public func highestCommon(with other: VersionList) -> UInt8? {
        let theirs = Dictionary(other.entries.map { ($0.version, $0.digest) }, uniquingKeysWith: { a, _ in a })
        return entries.reversed().first { theirs[$0.version] == $0.digest }?.version
    }

    /// Versions both lists name but with different digests: different builds of the same version.
    public func conflicting(with other: VersionList) -> [UInt8] {
        let theirs = Dictionary(other.entries.map { ($0.version, $0.digest) }, uniquingKeysWith: { a, _ in a })
        return entries.filter { e in theirs[e.version].map { $0 != e.digest } ?? false }.map(\.version)
    }

    /// Entries up to `max`; at least the oldest, so a cap below the window still offers something.
    public func capped(at max: UInt8?) -> VersionList {
        guard let max else { return self }
        let kept = entries.filter { $0.version <= max }
        return VersionList(kept.isEmpty ? Array(entries.prefix(1)) : kept)
    }

    /// "v3–v4", "v3", "none".
    public var description: String {
        guard let oldest, let newest else { return "none" }
        return oldest == newest ? "v\(newest)" : "v\(oldest)–v\(newest)"
    }

    /// Every version this build implements, with the digests of its own encodings.
    public static let supported = VersionList(LainProtocol.supportedVersions.map {
        VersionEntry(version: $0, digest: SchemaDigest.compute(version: $0))
    })

    /// What this process offers peers: `supported`, capped by the `lainProtocolMax` user default.
    public static let offered: VersionList = {
        let cap = UserDefaults.standard.integer(forKey: LainProtocol.versionCapKey)
        return supported.capped(at: (1...254).contains(cap) ? UInt8(cap) : nil)
    }()
}

extension ByteWriter {
    /// count u8, then (version u8, digest[8]) per entry: frozen (PROTOCOL-VERSIONING §3.1).
    mutating func versionList(_ list: VersionList) {
        u8(UInt8(min(list.entries.count, VersionList.maxCount)))
        for e in list.entries.prefix(VersionList.maxCount) { u8(e.version); raw(e.digest) }
    }
}

extension ByteReader {
    /// Strict: at most 16 entries, versions strictly ascending, never 0 or the handshake version.
    mutating func versionList() throws(ProtocolError) -> VersionList {
        let n = Int(try u8())
        guard n <= VersionList.maxCount else { throw .malformed("\(n) versions") }
        var entries: [VersionEntry] = []
        for _ in 0..<n {
            let version = try u8()
            guard version != 0, version != LainProtocol.handshakeVersion, version > (entries.last?.version ?? 0) else {
                throw .malformed("version list")
            }
            entries.append(VersionEntry(version: version, digest: try raw(VersionEntry.digestSize)))
        }
        return VersionList(entries)
    }
}

/// The digest of one version's wire format: the first 8 bytes of SHA-256 over the encoding, at that
/// version, of every session message in `ProtocolSamples` that exists in it. Computed from this build's
/// own codec, so a different (or stale) build of a version shows up as a mismatch. Released versions'
/// digests are pinned by tests.
public enum SchemaDigest {
    public static func compute(version: UInt8) -> [UInt8] {
        var hash = SHA256()
        for message in ProtocolSamples.all where message.type.isSession {
            guard let bytes = MessageCodec.lower(message, to: version, sequence: 0, timestampNs: 0).bytes else { continue }
            hash.update(data: bytes)
        }
        return Array(hash.finalize().prefix(VersionEntry.digestSize))
    }
}
