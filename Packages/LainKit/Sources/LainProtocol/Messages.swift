/// Payloads for every message in §7.5, as explicit little-endian structs. Each type round-trips
/// through `encode(into:)` / `init(from:)`; `Message` is the tagged union the codec works with.

public protocol WireMessage: Sendable, Equatable {
    static var type: MessageType { get }
    func encode(into w: inout ByteWriter)
    init(from r: inout ByteReader) throws(ProtocolError)
}

// MARK: - Shared value types

public enum KeyboardType: UInt8, Sendable, CaseIterable { case unknown = 0, ansi = 1, iso = 2, jis = 3 }
public enum VideoCodec: UInt8, Sendable { case hevc = 1 }
/// Values match HEVC chroma_format_idc.
public enum ChromaFormat: UInt8, Sendable { case yuv420 = 1, yuv444 = 3 }
public enum DisplayMode: UInt8, Sendable { case extend = 0, primary = 1, captureExisting = 2 }
public enum AudioEncoding: UInt8, Sendable { case pcm16LE = 0 }

public struct DecodeCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let hevcMain = DecodeCapabilities(rawValue: 1 << 0)
    /// Test-decoded at startup with hardware required (S3c).
    public static let hevcMain44410Hardware = DecodeCapabilities(rawValue: 1 << 1)
}

/// macOS-style modifier state carried with key and pointer events.
public struct ModifierFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let capsLock = ModifierFlags(rawValue: 1 << 0)
    public static let shift = ModifierFlags(rawValue: 1 << 1)
    public static let control = ModifierFlags(rawValue: 1 << 2)
    public static let option = ModifierFlags(rawValue: 1 << 3)
    public static let command = ModifierFlags(rawValue: 1 << 4)
    public static let function = ModifierFlags(rawValue: 1 << 5)
}

/// NSEvent-style scroll/gesture phase.
public enum GesturePhase: UInt8, Sendable, CaseIterable { case none = 0, mayBegin, began, changed, ended, cancelled }
/// Scroll momentum phase, synthesized by the client (§6.4).
public enum MomentumPhase: UInt8, Sendable, CaseIterable { case none = 0, began, changed, ended }
public enum MouseButton: UInt8, Sendable, CaseIterable { case left = 0, right = 1, other = 2 }

// MARK: - Control

public struct ChannelHello: WireMessage {
    public static let type = MessageType.channelHello
    public static let tokenSize = 16, macSize = 32
    public var protocolVersion: UInt8
    public var connectionKind: ConnectionKind
    /// Random per session; ties the three connections together.
    public var sessionToken: [UInt8]
    /// HMAC-SHA256 over the fields above, keyed by the pairing secret (computed in LainTransport).
    /// All zeros requests pairing (§7.6); only the USB listener accepts that.
    public var hmac: [UInt8]

    public init(protocolVersion: UInt8 = LainProtocol.majorVersion, connectionKind: ConnectionKind,
                sessionToken: [UInt8], hmac: [UInt8]) {
        precondition(sessionToken.count == Self.tokenSize && hmac.count == Self.macSize)
        self.protocolVersion = protocolVersion
        self.connectionKind = connectionKind
        self.sessionToken = sessionToken
        self.hmac = hmac
    }

    /// The bytes the HMAC covers.
    public var authenticatedBytes: [UInt8] { [protocolVersion, connectionKind.rawValue] + sessionToken }

    public func encode(into w: inout ByteWriter) {
        w.u8(protocolVersion); w.u8(connectionKind.rawValue); w.raw(sessionToken); w.raw(hmac)
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        protocolVersion = try r.u8()
        connectionKind = try r.enumValue(ConnectionKind.self)
        sessionToken = try r.raw(Self.tokenSize)
        hmac = try r.raw(Self.macSize)
    }
}

public struct Hello: WireMessage {
    public static let type = MessageType.hello
    public var protocolVersion: UInt8
    public var deviceModel: String
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    public var scale: UInt8
    public var maxRefreshRate: UInt16
    public var decodeCapabilities: DecodeCapabilities
    public var keyboardType: KeyboardType

    public init(protocolVersion: UInt8 = LainProtocol.majorVersion, deviceModel: String, pixelWidth: UInt32,
                pixelHeight: UInt32, scale: UInt8, maxRefreshRate: UInt16, decodeCapabilities: DecodeCapabilities,
                keyboardType: KeyboardType) {
        self.protocolVersion = protocolVersion
        self.deviceModel = deviceModel
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.maxRefreshRate = maxRefreshRate
        self.decodeCapabilities = decodeCapabilities
        self.keyboardType = keyboardType
    }

    public func encode(into w: inout ByteWriter) {
        w.u8(protocolVersion); w.string(deviceModel); w.u32(pixelWidth); w.u32(pixelHeight); w.u8(scale)
        w.u16(maxRefreshRate); w.u32(decodeCapabilities.rawValue); w.u8(keyboardType.rawValue)
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        protocolVersion = try r.u8(); deviceModel = try r.string(); pixelWidth = try r.u32(); pixelHeight = try r.u32()
        scale = try r.u8(); maxRefreshRate = try r.u16()
        decodeCapabilities = DecodeCapabilities(rawValue: try r.u32()); keyboardType = try r.enumValue(KeyboardType.self)
    }
}

public struct HelloAck: WireMessage {
    public static let type = MessageType.helloAck
    public var codec: VideoCodec
    public var chroma: ChromaFormat
    public var bitDepth: UInt8
    public var displayMode: DisplayMode
    public var bitrate: UInt32
    public var refreshRate: UInt16
    /// The Mac display's size in points: the client's cursor space (§6.3).
    public var displayPointWidth: UInt32
    public var displayPointHeight: UInt32
    public var audioSampleRate: UInt32
    public var audioChannels: UInt8
    public var audioEncoding: AudioEncoding
    public var doubleClickIntervalMs: UInt32
    public var keyRepeatDelayMs: UInt32
    public var keyRepeatIntervalMs: UInt32
    /// The Mac's current keyboard input source (D18), e.g. "com.apple.keylayout.Colemak".
    public var macInputSource: String

    public init(codec: VideoCodec, chroma: ChromaFormat, bitDepth: UInt8, displayMode: DisplayMode, bitrate: UInt32,
                refreshRate: UInt16, displayPointWidth: UInt32, displayPointHeight: UInt32, audioSampleRate: UInt32,
                audioChannels: UInt8, audioEncoding: AudioEncoding, doubleClickIntervalMs: UInt32,
                keyRepeatDelayMs: UInt32, keyRepeatIntervalMs: UInt32, macInputSource: String) {
        self.codec = codec
        self.chroma = chroma
        self.bitDepth = bitDepth
        self.displayMode = displayMode
        self.bitrate = bitrate
        self.refreshRate = refreshRate
        self.displayPointWidth = displayPointWidth
        self.displayPointHeight = displayPointHeight
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.audioEncoding = audioEncoding
        self.doubleClickIntervalMs = doubleClickIntervalMs
        self.keyRepeatDelayMs = keyRepeatDelayMs
        self.keyRepeatIntervalMs = keyRepeatIntervalMs
        self.macInputSource = macInputSource
    }

    public func encode(into w: inout ByteWriter) {
        w.u8(codec.rawValue); w.u8(chroma.rawValue); w.u8(bitDepth); w.u8(displayMode.rawValue); w.u32(bitrate)
        w.u16(refreshRate); w.u32(displayPointWidth); w.u32(displayPointHeight); w.u32(audioSampleRate)
        w.u8(audioChannels); w.u8(audioEncoding.rawValue); w.u32(doubleClickIntervalMs); w.u32(keyRepeatDelayMs)
        w.u32(keyRepeatIntervalMs); w.string(macInputSource)
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        codec = try r.enumValue(VideoCodec.self); chroma = try r.enumValue(ChromaFormat.self); bitDepth = try r.u8()
        displayMode = try r.enumValue(DisplayMode.self); bitrate = try r.u32(); refreshRate = try r.u16()
        displayPointWidth = try r.u32(); displayPointHeight = try r.u32(); audioSampleRate = try r.u32()
        audioChannels = try r.u8(); audioEncoding = try r.enumValue(AudioEncoding.self)
        doubleClickIntervalMs = try r.u32(); keyRepeatDelayMs = try r.u32(); keyRepeatIntervalMs = try r.u32()
        macInputSource = try r.string()
    }
}

public struct Start: WireMessage {
    public static let type = MessageType.start
    public init() {}
    public func encode(into w: inout ByteWriter) {}
    public init(from r: inout ByteReader) throws(ProtocolError) {}
}

public struct Stop: WireMessage {
    public static let type = MessageType.stop
    public enum Reason: UInt8, Sendable { case userRequested = 0, backgrounded = 1, shuttingDown = 2 }
    public var reason: Reason
    public init(reason: Reason) { self.reason = reason }
    public func encode(into w: inout ByteWriter) { w.u8(reason.rawValue) }
    public init(from r: inout ByteReader) throws(ProtocolError) { reason = try r.enumValue(Reason.self) }
}

/// NTP-style exchange for RTT and clock offset (§9): Ping carries t0, Pong t0 plus the peer's t1/t2.
public struct Ping: WireMessage {
    public static let type = MessageType.ping
    public var id: UInt32
    public var sentAtNs: UInt64
    public init(id: UInt32, sentAtNs: UInt64) { self.id = id; self.sentAtNs = sentAtNs }
    public func encode(into w: inout ByteWriter) { w.u32(id); w.u64(sentAtNs) }
    public init(from r: inout ByteReader) throws(ProtocolError) { id = try r.u32(); sentAtNs = try r.u64() }
}

public struct Pong: WireMessage {
    public static let type = MessageType.pong
    public var id: UInt32
    /// t0: the Ping's sender time, echoed.
    public var pingSentAtNs: UInt64
    /// t1: when the Ping arrived (responder clock).
    public var receivedAtNs: UInt64
    /// t2: when this Pong was sent (responder clock).
    public var sentAtNs: UInt64
    public init(id: UInt32, pingSentAtNs: UInt64, receivedAtNs: UInt64, sentAtNs: UInt64) {
        self.id = id; self.pingSentAtNs = pingSentAtNs; self.receivedAtNs = receivedAtNs; self.sentAtNs = sentAtNs
    }
    public func encode(into w: inout ByteWriter) { w.u32(id); w.u64(pingSentAtNs); w.u64(receivedAtNs); w.u64(sentAtNs) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        id = try r.u32(); pingSentAtNs = try r.u64(); receivedAtNs = try r.u64(); sentAtNs = try r.u64()
    }
}

public struct KeyframeRequest: WireMessage {
    public static let type = MessageType.keyframeRequest
    public enum Reason: UInt8, Sendable { case startup = 0, decodeError = 1, sequenceGap = 2, resumed = 3 }
    public var reason: Reason
    /// Last frame the client decoded correctly (0 if none).
    public var lastGoodFrameId: UInt32
    public init(reason: Reason, lastGoodFrameId: UInt32) { self.reason = reason; self.lastGoodFrameId = lastGoodFrameId }
    public func encode(into w: inout ByteWriter) { w.u8(reason.rawValue); w.u32(lastGoodFrameId) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        reason = try r.enumValue(Reason.self); lastGoodFrameId = try r.u32()
    }
}

/// A key/value pair; keys are open-ended so new stats and settings don't change the wire format.
public struct KeyValue: Sendable, Equatable {
    public var key: UInt16
    public var value: Int64
    public init(_ key: UInt16, _ value: Int64) { self.key = key; self.value = value }
}

extension ByteWriter {
    mutating func keyValues(_ kvs: [KeyValue]) {
        u16(UInt16(kvs.count)); for kv in kvs { u16(kv.key); i64(kv.value) }
    }
}

extension ByteReader {
    mutating func keyValues() throws(ProtocolError) -> [KeyValue] {
        let n = Int(try u16())
        guard remaining >= n * 10 else { throw .truncated }
        var out: [KeyValue] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(KeyValue(try u16(), try i64())) }
        return out
    }
}

/// Client-side telemetry for the HUD and bitrate control (keys in `StatKey`).
public struct Stats: WireMessage {
    public static let type = MessageType.stats
    public var entries: [KeyValue]
    public init(entries: [KeyValue]) { self.entries = entries }
    public func encode(into w: inout ByteWriter) { w.keyValues(entries) }
    public init(from r: inout ByteReader) throws(ProtocolError) { entries = try r.keyValues() }
}

public enum StatKey {
    public static let framesReceived: UInt16 = 1
    public static let framesDecoded: UInt16 = 2
    public static let framesDropped: UInt16 = 3
    public static let decodeP50Us: UInt16 = 4
    public static let decodeP95Us: UInt16 = 5
    public static let presentP50Us: UInt16 = 6
    public static let presentP95Us: UInt16 = 7
}

/// Settings changes in either direction (keys in `ConfigKey`).
public struct ConfigUpdate: WireMessage {
    public static let type = MessageType.configUpdate
    public var entries: [KeyValue]
    public init(entries: [KeyValue]) { self.entries = entries }
    public func encode(into w: inout ByteWriter) { w.keyValues(entries) }
    public init(from r: inout ByteReader) throws(ProtocolError) { entries = try r.keyValues() }
}

public enum ConfigKey {
    public static let bitrate: UInt16 = 1
    public static let chroma: UInt16 = 2
    public static let refreshRate: UInt16 = 3
    public static let keepDisplayAfterDisconnect: UInt16 = 4
}

public struct DisplayChanged: WireMessage {
    public static let type = MessageType.displayChanged
    public var displayID: UInt32
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    public var pointWidth: UInt32
    public var pointHeight: UInt32
    public var refreshRate: UInt16
    public init(displayID: UInt32, pixelWidth: UInt32, pixelHeight: UInt32, pointWidth: UInt32, pointHeight: UInt32,
                refreshRate: UInt16) {
        self.displayID = displayID; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth; self.pointHeight = pointHeight; self.refreshRate = refreshRate
    }
    public func encode(into w: inout ByteWriter) {
        w.u32(displayID); w.u32(pixelWidth); w.u32(pixelHeight); w.u32(pointWidth); w.u32(pointHeight); w.u16(refreshRate)
    }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        displayID = try r.u32(); pixelWidth = try r.u32(); pixelHeight = try r.u32()
        pointWidth = try r.u32(); pointHeight = try r.u32(); refreshRate = try r.u16()
    }
}

public struct ErrorMessage: WireMessage {
    public static let type = MessageType.error
    public enum Code: UInt16, Sendable {
        case versionMismatch = 1, authenticationFailed = 2, permissionMissing = 3, displayUnavailable = 4, `internal` = 5
    }
    public var code: Code
    public var message: String
    public init(code: Code, message: String) { self.code = code; self.message = message }
    public func encode(into w: inout ByteWriter) { w.u16(code.rawValue); w.string(message) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        let raw = try r.u16()
        guard let c = Code(rawValue: raw) else { throw .malformed("error code \(raw)") }
        code = c; message = try r.string()
    }
}

/// USB pairing (§7.6, D13): sent by the host on the realtime connection right after a pairing
/// `ChannelHello` (all-zero HMAC). The client stores the secret; its `Hello` confirms it.
public struct Pair: WireMessage {
    public static let type = MessageType.pair
    public static let secretSize = 32
    public var secret: [UInt8]
    public init(secret: [UInt8]) {
        precondition(secret.count == Self.secretSize)
        self.secret = secret
    }
    public func encode(into w: inout ByteWriter) { w.raw(secret) }
    public init(from r: inout ByteReader) throws(ProtocolError) { secret = try r.raw(Self.secretSize) }
}

// MARK: - Video

/// Color tags use ITU-T H.273 code points: P3-D65 primaries = 12, sRGB/IEC 61966-2-1 transfer = 13,
/// BT.709 matrix = 1.
public struct VideoConfig: WireMessage {
    public static let type = MessageType.videoConfig
    public var configId: UInt32
    public var codec: VideoCodec
    public var chroma: ChromaFormat
    public var bitDepth: UInt8
    public var width: UInt32
    public var height: UInt32
    public var fullRange: Bool
    public var colorPrimaries: UInt8
    public var transferFunction: UInt8
    public var matrix: UInt8
    /// VPS, SPS, PPS without start codes.
    public var parameterSets: [[UInt8]]

    public init(configId: UInt32, codec: VideoCodec, chroma: ChromaFormat, bitDepth: UInt8, width: UInt32, height: UInt32,
                fullRange: Bool, colorPrimaries: UInt8, transferFunction: UInt8, matrix: UInt8, parameterSets: [[UInt8]]) {
        self.configId = configId; self.codec = codec; self.chroma = chroma; self.bitDepth = bitDepth
        self.width = width; self.height = height; self.fullRange = fullRange; self.colorPrimaries = colorPrimaries
        self.transferFunction = transferFunction; self.matrix = matrix; self.parameterSets = parameterSets
    }

    public func encode(into w: inout ByteWriter) {
        w.u32(configId); w.u8(codec.rawValue); w.u8(chroma.rawValue); w.u8(bitDepth); w.u32(width); w.u32(height)
        w.bool(fullRange); w.u8(colorPrimaries); w.u8(transferFunction); w.u8(matrix)
        w.u8(UInt8(parameterSets.count)); for ps in parameterSets { w.blob(ps) }
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        configId = try r.u32(); codec = try r.enumValue(VideoCodec.self); chroma = try r.enumValue(ChromaFormat.self)
        bitDepth = try r.u8(); width = try r.u32(); height = try r.u32(); fullRange = try r.bool()
        colorPrimaries = try r.u8(); transferFunction = try r.u8(); matrix = try r.u8()
        let n = Int(try r.u8())
        var sets: [[UInt8]] = []
        for _ in 0..<n { sets.append(try r.blob()) }
        parameterSets = sets
    }
}

/// One encoded frame: 4-byte big-endian length-prefixed NAL units exactly as VideoToolbox emits them.
/// Keyframe/refinement are header flags.
public struct VideoFrame: WireMessage {
    public static let type = MessageType.videoFrame
    public var frameId: UInt32
    public var configId: UInt32
    public var captureTimeNs: UInt64
    public var encodeDoneNs: UInt64
    public var isKeyframe: Bool
    public var data: [UInt8]

    public init(frameId: UInt32, configId: UInt32, captureTimeNs: UInt64, encodeDoneNs: UInt64, isKeyframe: Bool,
                data: [UInt8]) {
        self.frameId = frameId; self.configId = configId; self.captureTimeNs = captureTimeNs
        self.encodeDoneNs = encodeDoneNs; self.isKeyframe = isKeyframe; self.data = data
    }

    public func encode(into w: inout ByteWriter) {
        w.u32(frameId); w.u32(configId); w.u64(captureTimeNs); w.u64(encodeDoneNs); w.bool(isKeyframe); w.blob(data)
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        frameId = try r.u32(); configId = try r.u32(); captureTimeNs = try r.u64(); encodeDoneNs = try r.u64()
        isKeyframe = try r.bool(); data = try r.blob()
    }
}

/// Sent as soon as a frame has fully arrived; drives backpressure (§7.3).
public struct FrameAck: WireMessage {
    public static let type = MessageType.frameAck
    public var frameId: UInt32
    public var receivedAtNs: UInt64
    public var bytes: UInt32
    public init(frameId: UInt32, receivedAtNs: UInt64, bytes: UInt32) {
        self.frameId = frameId; self.receivedAtNs = receivedAtNs; self.bytes = bytes
    }
    public func encode(into w: inout ByteWriter) { w.u32(frameId); w.u64(receivedAtNs); w.u32(bytes) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        frameId = try r.u32(); receivedAtNs = try r.u64(); bytes = try r.u32()
    }
}

// MARK: - Audio

public struct AudioConfig: WireMessage {
    public static let type = MessageType.audioConfig
    public var sampleRate: UInt32
    public var channels: UInt8
    public var encoding: AudioEncoding
    public var framesPerPacket: UInt16
    public init(sampleRate: UInt32, channels: UInt8, encoding: AudioEncoding, framesPerPacket: UInt16) {
        self.sampleRate = sampleRate; self.channels = channels; self.encoding = encoding; self.framesPerPacket = framesPerPacket
    }
    public func encode(into w: inout ByteWriter) { w.u32(sampleRate); w.u8(channels); w.u8(encoding.rawValue); w.u16(framesPerPacket) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        sampleRate = try r.u32(); channels = try r.u8(); encoding = try r.enumValue(AudioEncoding.self)
        framesPerPacket = try r.u16()
    }
}

public struct AudioPacket: WireMessage {
    public static let type = MessageType.audioPacket
    public var packetId: UInt32
    public var captureTimeNs: UInt64
    public var samples: [UInt8]
    public init(packetId: UInt32, captureTimeNs: UInt64, samples: [UInt8]) {
        self.packetId = packetId; self.captureTimeNs = captureTimeNs; self.samples = samples
    }
    public func encode(into w: inout ByteWriter) { w.u32(packetId); w.u64(captureTimeNs); w.blob(samples) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        packetId = try r.u32(); captureTimeNs = try r.u64(); samples = try r.blob()
    }
}

// MARK: - Cursor (H→C)

/// Sent once per unique shape (§5.4). Pixels are premultiplied BGRA, rows packed.
public struct CursorShape: WireMessage {
    public static let type = MessageType.cursorShape
    public var shapeId: UInt32
    public var pixelWidth: UInt16
    public var pixelHeight: UInt16
    public var scale: UInt8
    /// Hotspot in points from the top-left.
    public var hotspotX: Float
    public var hotspotY: Float
    public var pixels: [UInt8]
    public init(shapeId: UInt32, pixelWidth: UInt16, pixelHeight: UInt16, scale: UInt8, hotspotX: Float, hotspotY: Float,
                pixels: [UInt8]) {
        self.shapeId = shapeId; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.scale = scale
        self.hotspotX = hotspotX; self.hotspotY = hotspotY; self.pixels = pixels
    }
    public func encode(into w: inout ByteWriter) {
        w.u32(shapeId); w.u16(pixelWidth); w.u16(pixelHeight); w.u8(scale); w.f32(hotspotX); w.f32(hotspotY); w.blob(pixels)
    }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        shapeId = try r.u32(); pixelWidth = try r.u16(); pixelHeight = try r.u16(); scale = try r.u8()
        hotspotX = try r.f32(); hotspotY = try r.f32(); pixels = try r.blob()
        guard pixels.count == Int(pixelWidth) * Int(pixelHeight) * 4 else { throw .malformed("cursor pixel count") }
    }
}

public struct CursorSelect: WireMessage {
    public static let type = MessageType.cursorSelect
    public var shapeId: UInt32
    public var visible: Bool
    public init(shapeId: UInt32, visible: Bool) { self.shapeId = shapeId; self.visible = visible }
    public func encode(into w: inout ByteWriter) { w.u32(shapeId); w.bool(visible) }
    public init(from r: inout ByteReader) throws(ProtocolError) { shapeId = try r.u32(); visible = try r.bool() }
}

/// The Mac moved the cursor itself; overwrite the client's position (points).
public struct CursorWarp: WireMessage {
    public static let type = MessageType.cursorWarp
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public func encode(into w: inout ByteWriter) { w.f64(x); w.f64(y) }
    public init(from r: inout ByteReader) throws(ProtocolError) { x = try r.f64(); y = try r.f64() }
}

// MARK: - Input (C→H)

/// A physical key (D18): HID usage page + usage; the host maps it to a macOS keycode.
public struct KeyEvent: WireMessage {
    public static let type = MessageType.keyEvent
    public var usagePage: UInt16
    public var usage: UInt16
    public var isDown: Bool
    public var isRepeat: Bool
    /// Modifier state after this event, including any remap (§6.4).
    public var modifiers: ModifierFlags
    public init(usagePage: UInt16 = 0x07, usage: UInt16, isDown: Bool, isRepeat: Bool = false, modifiers: ModifierFlags) {
        self.usagePage = usagePage; self.usage = usage; self.isDown = isDown; self.isRepeat = isRepeat; self.modifiers = modifiers
    }
    public func encode(into w: inout ByteWriter) {
        w.u16(usagePage); w.u16(usage); w.bool(isDown); w.bool(isRepeat); w.u32(modifiers.rawValue)
    }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        usagePage = try r.u16(); usage = try r.u16(); isDown = try r.bool(); isRepeat = try r.bool()
        modifiers = ModifierFlags(rawValue: try r.u32())
    }
}

/// Absolute position (points, client-authoritative) plus the raw delta (§6.3).
public struct PointerMove: WireMessage {
    public static let type = MessageType.pointerMove
    public var x: Double
    public var y: Double
    public var dx: Float
    public var dy: Float
    /// Bit n = MouseButton(rawValue: n) held.
    public var buttons: UInt8
    public init(x: Double, y: Double, dx: Float, dy: Float, buttons: UInt8) {
        self.x = x; self.y = y; self.dx = dx; self.dy = dy; self.buttons = buttons
    }
    public func encode(into w: inout ByteWriter) { w.f64(x); w.f64(y); w.f32(dx); w.f32(dy); w.u8(buttons) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        x = try r.f64(); y = try r.f64(); dx = try r.f32(); dy = try r.f32(); buttons = try r.u8()
    }
}

public struct PointerButton: WireMessage {
    public static let type = MessageType.pointerButton
    public var button: MouseButton
    public var isDown: Bool
    /// Computed by the client with the Mac's double-click interval (§5.5).
    public var clickCount: UInt8
    public var x: Double
    public var y: Double
    public var modifiers: ModifierFlags
    public init(button: MouseButton, isDown: Bool, clickCount: UInt8, x: Double, y: Double, modifiers: ModifierFlags) {
        self.button = button; self.isDown = isDown; self.clickCount = clickCount; self.x = x; self.y = y
        self.modifiers = modifiers
    }
    public func encode(into w: inout ByteWriter) {
        w.u8(button.rawValue); w.bool(isDown); w.u8(clickCount); w.f64(x); w.f64(y); w.u32(modifiers.rawValue)
    }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        button = try r.enumValue(MouseButton.self); isDown = try r.bool(); clickCount = try r.u8()
        x = try r.f64(); y = try r.f64(); modifiers = ModifierFlags(rawValue: try r.u32())
    }
}

/// Continuous pixel scroll with phases; momentum is synthesized by the client (§5.5, §6.4).
public struct Scroll: WireMessage {
    public static let type = MessageType.scroll
    public var dx: Float
    public var dy: Float
    public var phase: GesturePhase
    public var momentumPhase: MomentumPhase
    public init(dx: Float, dy: Float, phase: GesturePhase, momentumPhase: MomentumPhase) {
        self.dx = dx; self.dy = dy; self.phase = phase; self.momentumPhase = momentumPhase
    }
    public func encode(into w: inout ByteWriter) { w.f32(dx); w.f32(dy); w.u8(phase.rawValue); w.u8(momentumPhase.rawValue) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        dx = try r.f32(); dy = try r.f32(); phase = try r.enumValue(GesturePhase.self)
        momentumPhase = try r.enumValue(MomentumPhase.self)
    }
}

public struct Gesture: WireMessage {
    public static let type = MessageType.gesture
    public enum Kind: UInt8, Sendable { case magnify = 0, rotate = 1 }
    public var kind: Kind
    public var phase: GesturePhase
    /// Magnify: scale delta; rotate: radians delta.
    public var value: Float
    public init(kind: Kind, phase: GesturePhase, value: Float) { self.kind = kind; self.phase = phase; self.value = value }
    public func encode(into w: inout ByteWriter) { w.u8(kind.rawValue); w.u8(phase.rawValue); w.f32(value) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        kind = try r.enumValue(Kind.self); phase = try r.enumValue(GesturePhase.self); value = try r.f32()
    }
}

/// Invariant 4: release every held key and button.
public struct ReleaseAll: WireMessage {
    public static let type = MessageType.releaseAll
    public enum Reason: UInt8, Sendable { case focusLost = 0, pointerLockLost = 1, disconnect = 2, transportSwitch = 3 }
    public var reason: Reason
    public init(reason: Reason) { self.reason = reason }
    public func encode(into w: inout ByteWriter) { w.u8(reason.rawValue) }
    public init(from r: inout ByteReader) throws(ProtocolError) { reason = try r.enumValue(Reason.self) }
}

// MARK: - Latency probe (§9)

public struct ProbeRequest: WireMessage {
    public static let type = MessageType.probeRequest
    public var probeId: UInt32
    public var sentAtNs: UInt64
    public init(probeId: UInt32, sentAtNs: UInt64) { self.probeId = probeId; self.sentAtNs = sentAtNs }
    public func encode(into w: inout ByteWriter) { w.u32(probeId); w.u64(sentAtNs) }
    public init(from r: inout ByteReader) throws(ProtocolError) { probeId = try r.u32(); sentAtNs = try r.u64() }
}

public struct ProbeAck: WireMessage {
    public static let type = MessageType.probeAck
    public var probeId: UInt32
    public var detectedAtNs: UInt64
    public init(probeId: UInt32, detectedAtNs: UInt64) { self.probeId = probeId; self.detectedAtNs = detectedAtNs }
    public func encode(into w: inout ByteWriter) { w.u32(probeId); w.u64(detectedAtNs) }
    public init(from r: inout ByteReader) throws(ProtocolError) { probeId = try r.u32(); detectedAtNs = try r.u64() }
}
