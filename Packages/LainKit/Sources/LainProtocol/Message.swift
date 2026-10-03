/// Every message in §7.5 as one tagged union: the newest version's model (PROTOCOL-VERSIONING §3.3).
public enum Message: Sendable, Equatable {
    case channelHello(ChannelHello), channelAccept(ChannelAccept)
    case hello(Hello), helloAck(HelloAck)
    case ping(Ping), pong(Pong)
    case keyframeRequest(KeyframeRequest)
    case error(ErrorMessage)
    case pair(Pair)
    case displayLayout(DisplayLayout)
    case hostSetup(HostSetup)
    case videoConfig(VideoConfig), videoFrame(VideoFrame), frameAck(FrameAck)
    case cursorShape(CursorShape), cursorSelect(CursorSelect), cursorWarp(CursorWarp)
    case keyEvent(KeyEvent), pointerMove(PointerMove), pointerButton(PointerButton), scroll(Scroll), gesture(Gesture)
    case releaseAll(ReleaseAll)

    public var payload: any WireMessage {
        switch self {
        case .channelHello(let m): m
        case .channelAccept(let m): m
        case .hello(let m): m
        case .helloAck(let m): m
        case .ping(let m): m
        case .pong(let m): m
        case .keyframeRequest(let m): m
        case .error(let m): m
        case .pair(let m): m
        case .displayLayout(let m): m
        case .hostSetup(let m): m
        case .videoConfig(let m): m
        case .videoFrame(let m): m
        case .frameAck(let m): m
        case .cursorShape(let m): m
        case .cursorSelect(let m): m
        case .cursorWarp(let m): m
        case .keyEvent(let m): m
        case .pointerMove(let m): m
        case .pointerButton(let m): m
        case .scroll(let m): m
        case .gesture(let m): m
        case .releaseAll(let m): m
        }
    }

    public var type: MessageType { Swift.type(of: payload).type }

    /// Header flags implied by the payload (a keyframe `VideoFrame` sets `.keyframe`).
    public var impliedFlags: HeaderFlags {
        if case .videoFrame(let f) = self, f.isKeyframe { return .keyframe }
        return []
    }

    /// Lifts a payload of `version` into the model: fields the version doesn't have get their defaults.
    /// `version` nil: the type's default (`MessageType.defaultVersion`).
    public static func decode(type: MessageType, payload: ArraySlice<UInt8>,
                              version: UInt8? = nil) throws(ProtocolError) -> Message {
        let version = version ?? type.defaultVersion
        guard type.exists(in: version) else { throw .unknownType(type.rawValue) }
        var r = ByteReader(payload, version: version)
        let m: Message
        switch type {
        case .channelHello: m = .channelHello(try ChannelHello(from: &r))
        case .channelAccept: m = .channelAccept(try ChannelAccept(from: &r))
        case .hello: m = .hello(try Hello(from: &r))
        case .helloAck: m = .helloAck(try HelloAck(from: &r))
        case .ping: m = .ping(try Ping(from: &r))
        case .pong: m = .pong(try Pong(from: &r))
        case .keyframeRequest: m = .keyframeRequest(try KeyframeRequest(from: &r))
        case .error: m = .error(try ErrorMessage(from: &r))
        case .pair: m = .pair(try Pair(from: &r))
        case .displayLayout: m = .displayLayout(try DisplayLayout(from: &r))
        case .hostSetup: m = .hostSetup(try HostSetup(from: &r))
        case .videoConfig: m = .videoConfig(try VideoConfig(from: &r))
        case .videoFrame: m = .videoFrame(try VideoFrame(from: &r))
        case .frameAck: m = .frameAck(try FrameAck(from: &r))
        case .cursorShape: m = .cursorShape(try CursorShape(from: &r))
        case .cursorSelect: m = .cursorSelect(try CursorSelect(from: &r))
        case .cursorWarp: m = .cursorWarp(try CursorWarp(from: &r))
        case .keyEvent: m = .keyEvent(try KeyEvent(from: &r))
        case .pointerMove: m = .pointerMove(try PointerMove(from: &r))
        case .pointerButton: m = .pointerButton(try PointerButton(from: &r))
        case .scroll: m = .scroll(try Scroll(from: &r))
        case .gesture: m = .gesture(try Gesture(from: &r))
        case .releaseAll: m = .releaseAll(try ReleaseAll(from: &r))
        }
        try r.finish()
        return m
    }
}

/// A decoded message with its header.
public struct Envelope: Sendable, Equatable {
    public var header: FrameHeader
    public var message: Message
    public init(header: FrameHeader, message: Message) { self.header = header; self.message = message }
}

/// A message written at one version (lower, PROTOCOL-VERSIONING §3.3).
public enum Lowered: Sendable, Equatable {
    /// Everything the message holds exists at that version.
    case exact([UInt8])
    /// Advisory fields the version doesn't have were left out.
    case projected([UInt8], dropped: [String])
    /// The message, or something it holds, doesn't exist at that version: not sendable there.
    case unrepresentable(String)

    public var bytes: [UInt8]? {
        switch self {
        case .exact(let b), .projected(let b, _): b
        case .unrepresentable: nil
        }
    }
}

public enum MessageCodec {
    /// Header + payload at `version` (a session version, or the handshake's), or why it can't be.
    public static func lower(_ message: Message, to version: UInt8, sequence: UInt32, timestampNs: UInt64,
                             flags: HeaderFlags? = nil) -> Lowered {
        guard message.type.exists(in: version) else { return .unrepresentable("\(message.type) doesn't exist in v\(version)") }
        var body = ByteWriter(capacity: 64, version: version)
        message.payload.encode(into: &body)
        if let why = body.refused { return .unrepresentable(why) }
        var w = ByteWriter(capacity: FrameHeader.size + body.bytes.count, version: version)
        FrameHeader(version: version, type: message.type, flags: flags ?? message.impliedFlags, sequence: sequence,
                    timestampNs: timestampNs, payloadLength: UInt32(body.bytes.count)).encode(into: &w)
        w.raw(body.bytes)
        return body.dropped.isEmpty ? .exact(w.bytes) : .projected(w.bytes, dropped: body.dropped)
    }

    /// Header + payload, ready to write. `version` nil: the type's default (`MessageType.defaultVersion`).
    /// The message must be representable there; channels use `lower` instead.
    public static func encode(_ message: Message, sequence: UInt32, timestampNs: UInt64,
                              flags: HeaderFlags? = nil, version: UInt8? = nil) -> [UInt8] {
        let lowered = lower(message, to: version ?? message.type.defaultVersion, sequence: sequence,
                            timestampNs: timestampNs, flags: flags)
        guard let bytes = lowered.bytes else { preconditionFailure("\(lowered)") }
        return bytes
    }

    /// `Error(versionMismatch)` framed in a legacy peer's own version, which it can parse (the `Error`
    /// payload is the same in every version), so a one-sided update says why (PROTOCOL-VERSIONING §7).
    public static func legacyVersionMismatch(remote: UInt8, why: String, sequence: UInt32, timestampNs: UInt64) -> [UInt8] {
        var body = ByteWriter(version: LainProtocol.handshakeVersion)
        ErrorMessage(code: .versionMismatch, message: why).encode(into: &body)
        var w = ByteWriter(capacity: FrameHeader.size + body.bytes.count, version: LainProtocol.handshakeVersion)
        FrameHeader(version: remote, type: .error, sequence: sequence, timestampNs: timestampNs,
                    payloadLength: UInt32(body.bytes.count)).encode(into: &w)
        w.raw(body.bytes)
        return w.bytes
    }

    /// Decodes exactly one complete message, at the version its header names.
    public static func decode(_ bytes: [UInt8]) throws(ProtocolError) -> Envelope {
        let header = try FrameHeader.decode(bytes[...])
        guard bytes.count - FrameHeader.size == Int(header.payloadLength) else {
            throw bytes.count - FrameHeader.size < Int(header.payloadLength) ? .truncated : .malformed("length mismatch")
        }
        return Envelope(header: header, message: try Message.decode(type: header.type, payload: bytes[FrameHeader.size...],
                                                                    version: header.version))
    }
}

/// Reassembles messages from a byte stream (TCP delivers arbitrary chunks). Any error is fatal for
/// the connection: the stream can't be resynchronized.
public struct FrameParser: Sendable {
    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public var bufferedByteCount: Int { buffer.count - start }

    public mutating func append(_ bytes: some Collection<UInt8>) {
        if start > 0, start == buffer.count { buffer.removeAll(keepingCapacity: true); start = 0 }
        buffer.append(contentsOf: bytes)
    }

    /// The next complete message, or nil if more bytes are needed.
    public mutating func next() throws(ProtocolError) -> Envelope? {
        guard bufferedByteCount >= FrameHeader.size else { return nil }
        let header = try FrameHeader.decode(buffer[start...])
        let end = start + FrameHeader.size + Int(header.payloadLength)
        guard buffer.count >= end else { return nil }
        let message = try Message.decode(type: header.type, payload: buffer[(start + FrameHeader.size)..<end],
                                         version: header.version)
        start = end
        if start > 1 << 20 { buffer.removeFirst(start); start = 0 }   // compact occasionally
        return Envelope(header: header, message: message)
    }
}
