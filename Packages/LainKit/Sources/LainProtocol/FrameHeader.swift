/// Message types (§7.5). Two layers (PROTOCOL-VERSIONING §3): the frozen handshake (`ChannelHello`,
/// `ChannelAccept`, `Pair`, and `Error` before a version is agreed), framed in header version 0xFF; and
/// the session messages, framed in the negotiated version. Reserved, never reuse: 0x03 `Start`, 0x04
/// `Stop`, 0x08 `Stats`, 0x09 `ConfigUpdate`, 0x0A `DisplayChanged`, 0x22 `VideoFragment`, 0x23
/// `VideoNack`, 0x30 `AudioConfig`, 0x31 `AudioPacket`, 0x60 `ProbeRequest`, 0x61 `ProbeAck` (defined in
/// v1–v2 but never sent; each comes back in the version that first uses it).
public enum MessageType: UInt8, Sendable, CaseIterable {
    case channelHello = 0x00
    case hello = 0x01, helloAck = 0x02
    case ping = 0x05, pong = 0x06
    case keyframeRequest = 0x07
    case error = 0x0B
    case pair = 0x0C
    case displayLayout = 0x0D
    case channelAccept = 0x0E
    /// v4: the Mac's setup state (permissions, why there's no video).
    case hostSetup = 0x0F
    case videoConfig = 0x20, videoFrame = 0x21, frameAck = 0x24
    case cursorShape = 0x40, cursorSelect = 0x41, cursorWarp = 0x42
    case keyEvent = 0x50, pointerMove = 0x51, pointerButton = 0x52, scroll = 0x53, gesture = 0x54, releaseAll = 0x55

    /// Sent in handshake frames (header version 0xFF). `Error` is both: a refusal before a version is
    /// agreed, and a session message after.
    public var isHandshake: Bool {
        switch self {
        case .channelHello, .channelAccept, .pair, .error: true
        default: false
        }
    }

    /// Sent in session frames, at the negotiated version.
    public var isSession: Bool {
        switch self {
        case .channelHello, .channelAccept, .pair: false
        default: true
        }
    }

    /// The first session version the message exists in.
    public var since: UInt8 {
        switch self {
        case .hostSetup: 4
        default: 3
        }
    }

    /// Whether the message can be framed in header version `version`.
    public func exists(in version: UInt8) -> Bool {
        version == LainProtocol.handshakeVersion ? isHandshake : isSession && since <= version
    }

    /// The version `MessageCodec` frames it in when none is given: handshake messages in 0xFF, session
    /// messages (`Error` too) in the newest version.
    public var defaultVersion: UInt8 { isSession ? LainProtocol.newestVersion : LainProtocol.handshakeVersion }
}

public struct HeaderFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let keyframe = HeaderFlags(rawValue: 1 << 0)
    public static let fragment = HeaderFlags(rawValue: 1 << 1)
    public static let retransmit = HeaderFlags(rawValue: 1 << 2)
    public static let refinement = HeaderFlags(rawValue: 1 << 3)
}

/// The 24-byte little-endian header that starts every message (§7.4).
public struct FrameHeader: Equatable, Sendable {
    public static let size = LainProtocol.headerSize
    /// Upper bound on a single payload; a 2752×2064 keyframe is ~1.3 MB (§13).
    public static let maxPayloadLength: UInt32 = 32 << 20

    public var version: UInt8
    public var type: MessageType
    public var flags: HeaderFlags
    /// Per-channel sequence number.
    public var sequence: UInt32
    /// Sender's CLOCK_UPTIME_RAW in ns.
    public var timestampNs: UInt64
    public var payloadLength: UInt32

    /// `version` nil: the type's default (`MessageType.defaultVersion`).
    public init(version: UInt8? = nil, type: MessageType, flags: HeaderFlags = [],
                sequence: UInt32, timestampNs: UInt64, payloadLength: UInt32) {
        self.version = version ?? type.defaultVersion
        self.type = type
        self.flags = flags
        self.sequence = sequence
        self.timestampNs = timestampNs
        self.payloadLength = payloadLength
    }

    public func encode(into w: inout ByteWriter) {
        w.u16(LainProtocol.magic)
        w.u8(version)
        w.u8(type.rawValue)
        w.u16(flags.rawValue)
        w.u16(0)
        w.u32(sequence)
        w.u64(timestampNs)
        w.u32(payloadLength)
    }

    /// Decodes and validates a header. Checks, in order: length, magic, version, type, reserved, size.
    /// The version must be the handshake's or one this build implements; which one a channel accepts is
    /// the channel's business (`MessageChannel`).
    public static func decode(_ bytes: ArraySlice<UInt8>) throws(ProtocolError) -> FrameHeader {
        var r = ByteReader(bytes.prefix(size))
        guard r.remaining == size else { throw .truncated }
        let magic = try r.u16()
        guard magic == LainProtocol.magic else { throw .badMagic(magic) }
        let version = try r.u8()
        guard version == LainProtocol.handshakeVersion || LainProtocol.supportedVersions.contains(version) else {
            throw .versionMismatch(remote: version)
        }
        let rawType = try r.u8()
        guard let type = MessageType(rawValue: rawType) else { throw .unknownType(rawType) }
        let flags = HeaderFlags(rawValue: try r.u16())
        guard try r.u16() == 0 else { throw .reservedNonZero }
        let sequence = try r.u32()
        let timestamp = try r.u64()
        let length = try r.u32()
        guard length <= maxPayloadLength else { throw .payloadTooLarge(length) }
        return FrameHeader(version: version, type: type, flags: flags, sequence: sequence,
                           timestampNs: timestamp, payloadLength: length)
    }
}
