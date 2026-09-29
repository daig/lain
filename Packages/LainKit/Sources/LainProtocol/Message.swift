/// Every message in §7.5 as one tagged union.
public enum Message: Sendable, Equatable {
    case channelHello(ChannelHello)
    case hello(Hello), helloAck(HelloAck)
    case start(Start), stop(Stop)
    case ping(Ping), pong(Pong)
    case keyframeRequest(KeyframeRequest)
    case stats(Stats)
    case configUpdate(ConfigUpdate)
    case displayChanged(DisplayChanged)
    case error(ErrorMessage)
    case pair(Pair)
    case displayLayout(DisplayLayout)
    case videoConfig(VideoConfig), videoFrame(VideoFrame), frameAck(FrameAck)
    case audioConfig(AudioConfig), audioPacket(AudioPacket)
    case cursorShape(CursorShape), cursorSelect(CursorSelect), cursorWarp(CursorWarp)
    case keyEvent(KeyEvent), pointerMove(PointerMove), pointerButton(PointerButton), scroll(Scroll), gesture(Gesture)
    case releaseAll(ReleaseAll)
    case probeRequest(ProbeRequest), probeAck(ProbeAck)

    public var payload: any WireMessage {
        switch self {
        case .channelHello(let m): m
        case .hello(let m): m
        case .helloAck(let m): m
        case .start(let m): m
        case .stop(let m): m
        case .ping(let m): m
        case .pong(let m): m
        case .keyframeRequest(let m): m
        case .stats(let m): m
        case .configUpdate(let m): m
        case .displayChanged(let m): m
        case .error(let m): m
        case .pair(let m): m
        case .displayLayout(let m): m
        case .videoConfig(let m): m
        case .videoFrame(let m): m
        case .frameAck(let m): m
        case .audioConfig(let m): m
        case .audioPacket(let m): m
        case .cursorShape(let m): m
        case .cursorSelect(let m): m
        case .cursorWarp(let m): m
        case .keyEvent(let m): m
        case .pointerMove(let m): m
        case .pointerButton(let m): m
        case .scroll(let m): m
        case .gesture(let m): m
        case .releaseAll(let m): m
        case .probeRequest(let m): m
        case .probeAck(let m): m
        }
    }

    public var type: MessageType { Swift.type(of: payload).type }

    /// Header flags implied by the payload (a keyframe `VideoFrame` sets `.keyframe`).
    public var impliedFlags: HeaderFlags {
        if case .videoFrame(let f) = self, f.isKeyframe { return .keyframe }
        return []
    }

    public static func decode(type: MessageType, payload: ArraySlice<UInt8>) throws(ProtocolError) -> Message {
        var r = ByteReader(payload)
        let m: Message
        switch type {
        case .channelHello: m = .channelHello(try ChannelHello(from: &r))
        case .hello: m = .hello(try Hello(from: &r))
        case .helloAck: m = .helloAck(try HelloAck(from: &r))
        case .start: m = .start(try Start(from: &r))
        case .stop: m = .stop(try Stop(from: &r))
        case .ping: m = .ping(try Ping(from: &r))
        case .pong: m = .pong(try Pong(from: &r))
        case .keyframeRequest: m = .keyframeRequest(try KeyframeRequest(from: &r))
        case .stats: m = .stats(try Stats(from: &r))
        case .configUpdate: m = .configUpdate(try ConfigUpdate(from: &r))
        case .displayChanged: m = .displayChanged(try DisplayChanged(from: &r))
        case .error: m = .error(try ErrorMessage(from: &r))
        case .pair: m = .pair(try Pair(from: &r))
        case .displayLayout: m = .displayLayout(try DisplayLayout(from: &r))
        case .videoConfig: m = .videoConfig(try VideoConfig(from: &r))
        case .videoFrame: m = .videoFrame(try VideoFrame(from: &r))
        case .frameAck: m = .frameAck(try FrameAck(from: &r))
        case .audioConfig: m = .audioConfig(try AudioConfig(from: &r))
        case .audioPacket: m = .audioPacket(try AudioPacket(from: &r))
        case .cursorShape: m = .cursorShape(try CursorShape(from: &r))
        case .cursorSelect: m = .cursorSelect(try CursorSelect(from: &r))
        case .cursorWarp: m = .cursorWarp(try CursorWarp(from: &r))
        case .keyEvent: m = .keyEvent(try KeyEvent(from: &r))
        case .pointerMove: m = .pointerMove(try PointerMove(from: &r))
        case .pointerButton: m = .pointerButton(try PointerButton(from: &r))
        case .scroll: m = .scroll(try Scroll(from: &r))
        case .gesture: m = .gesture(try Gesture(from: &r))
        case .releaseAll: m = .releaseAll(try ReleaseAll(from: &r))
        case .probeRequest: m = .probeRequest(try ProbeRequest(from: &r))
        case .probeAck: m = .probeAck(try ProbeAck(from: &r))
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

public enum MessageCodec {
    /// Header + payload, ready to write to a connection. `version` goes in the header (nil:
    /// `LainProtocol.majorVersion`); pass another one only to answer a mismatched peer with an
    /// `Error(versionMismatch)` it can parse (the `ErrorMessage` payload is unchanged since v1; §7.5).
    public static func encode(_ message: Message, sequence: UInt32, timestampNs: UInt64,
                              flags: HeaderFlags? = nil, version: UInt8? = nil) -> [UInt8] {
        var body = ByteWriter(capacity: 64)
        message.payload.encode(into: &body)
        var w = ByteWriter(capacity: FrameHeader.size + body.bytes.count)
        FrameHeader(version: version, type: message.type, flags: flags ?? message.impliedFlags, sequence: sequence,
                    timestampNs: timestampNs, payloadLength: UInt32(body.bytes.count)).encode(into: &w)
        w.raw(body.bytes)
        return w.bytes
    }

    /// Decodes exactly one complete message.
    public static func decode(_ bytes: [UInt8]) throws(ProtocolError) -> Envelope {
        let header = try FrameHeader.decode(bytes[...])
        guard bytes.count - FrameHeader.size == Int(header.payloadLength) else {
            throw bytes.count - FrameHeader.size < Int(header.payloadLength) ? .truncated : .malformed("length mismatch")
        }
        return Envelope(header: header, message: try Message.decode(type: header.type, payload: bytes[FrameHeader.size...]))
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
        let message = try Message.decode(type: header.type, payload: buffer[(start + FrameHeader.size)..<end])
        start = end
        if start > 1 << 20 { buffer.removeFirst(start); start = 0 }   // compact occasionally
        return Envelope(header: header, message: message)
    }
}
