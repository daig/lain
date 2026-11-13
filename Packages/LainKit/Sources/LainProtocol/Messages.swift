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

/// The first frame on every connection (handshake layer, frozen: PROTOCOL-VERSIONING §3.1). The dialer
/// offers its versions; the acceptor answers `ChannelAccept`.
public struct ChannelHello: WireMessage {
    public static let type = MessageType.channelHello
    public static let tokenSize = 16, macSize = 32
    /// The dialer's versions with their digests.
    public var versions: VersionList
    public var connectionKind: ConnectionKind
    /// Random per session; ties the three connections together.
    public var sessionToken: [UInt8]
    /// HMAC-SHA256 over every field above, keyed by the pairing secret (computed in LainTransport).
    /// All zeros requests pairing (§7.6); only the USB listener accepts that.
    public var hmac: [UInt8]

    /// `versions` nil: `VersionList.offered`.
    public init(versions: VersionList? = nil, connectionKind: ConnectionKind, sessionToken: [UInt8], hmac: [UInt8]) {
        precondition(sessionToken.count == Self.tokenSize && hmac.count == Self.macSize)
        self.versions = versions ?? .offered
        self.connectionKind = connectionKind
        self.sessionToken = sessionToken
        self.hmac = hmac
    }

    /// The bytes the HMAC covers: everything before it.
    public var authenticatedBytes: [UInt8] {
        var w = ByteWriter(version: LainProtocol.handshakeVersion)
        w.versionList(versions); w.u8(connectionKind.rawValue); w.raw(sessionToken)
        return w.bytes
    }

    public func encode(into w: inout ByteWriter) {
        w.versionList(versions); w.u8(connectionKind.rawValue); w.raw(sessionToken); w.raw(hmac)
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        versions = try r.versionList()
        connectionKind = try r.enumValue(ConnectionKind.self)
        sessionToken = try r.raw(Self.tokenSize)
        hmac = try r.raw(Self.macSize)
    }
}

/// The acceptor's answer to an authenticated `ChannelHello`, on every connection (handshake layer,
/// frozen: PROTOCOL-VERSIONING §3.1): the version the session runs at, the highest common to both lists
/// with equal digests, or 0 when there is none (then the connection closes).
public struct ChannelAccept: WireMessage {
    public static let type = MessageType.channelAccept
    /// 0: no common version.
    public var chosen: UInt8
    /// The acceptor's own versions.
    public var versions: VersionList
    public init(chosen: UInt8, versions: VersionList) { self.chosen = chosen; self.versions = versions }
    public func encode(into w: inout ByteWriter) { w.u8(chosen); w.versionList(versions) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        chosen = try r.u8()
        versions = try r.versionList()
        guard chosen == 0 || versions.versions.contains(chosen) else { throw .malformed("chose v\(chosen) outside its list") }
    }
}

public struct Hello: WireMessage {
    public static let type = MessageType.hello
    public var deviceModel: String
    public var pixelWidth: UInt32
    public var pixelHeight: UInt32
    public var scale: UInt8
    public var maxRefreshRate: UInt16
    public var decodeCapabilities: DecodeCapabilities
    public var keyboardType: KeyboardType

    public init(deviceModel: String, pixelWidth: UInt32, pixelHeight: UInt32, scale: UInt8, maxRefreshRate: UInt16,
                decodeCapabilities: DecodeCapabilities, keyboardType: KeyboardType) {
        self.deviceModel = deviceModel
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.maxRefreshRate = maxRefreshRate
        self.decodeCapabilities = decodeCapabilities
        self.keyboardType = keyboardType
    }

    public func encode(into w: inout ByteWriter) {
        w.string(deviceModel); w.u32(pixelWidth); w.u32(pixelHeight); w.u8(scale)
        w.u16(maxRefreshRate); w.u32(decodeCapabilities.rawValue); w.u8(keyboardType.rawValue)
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        deviceModel = try r.string(); pixelWidth = try r.u32(); pixelHeight = try r.u32()
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
    /// The host's stable id, a canonical UUID (Bonjour TXT `id`, §7.7). Over USB the client stores the
    /// link's secret under `mac:<hostId>` for Wi-Fi; over Wi-Fi it must be the dialed id. Empty: unknown.
    public var hostId: String
    /// The Mac's computer name, for the client's status.
    public var hostName: String

    public init(codec: VideoCodec, chroma: ChromaFormat, bitDepth: UInt8, displayMode: DisplayMode, bitrate: UInt32,
                refreshRate: UInt16, displayPointWidth: UInt32, displayPointHeight: UInt32, audioSampleRate: UInt32,
                audioChannels: UInt8, audioEncoding: AudioEncoding, doubleClickIntervalMs: UInt32,
                keyRepeatDelayMs: UInt32, keyRepeatIntervalMs: UInt32, macInputSource: String, hostId: String = "",
                hostName: String = "") {
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
        self.hostId = hostId
        self.hostName = hostName
    }

    public func encode(into w: inout ByteWriter) {
        w.u8(codec.rawValue); w.u8(chroma.rawValue); w.u8(bitDepth); w.u8(displayMode.rawValue); w.u32(bitrate)
        w.u16(refreshRate); w.u32(displayPointWidth); w.u32(displayPointHeight); w.u32(audioSampleRate)
        w.u8(audioChannels); w.u8(audioEncoding.rawValue); w.u32(doubleClickIntervalMs); w.u32(keyRepeatDelayMs)
        w.u32(keyRepeatIntervalMs); w.string(macInputSource); w.string(hostId); w.string(hostName)
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        codec = try r.enumValue(VideoCodec.self); chroma = try r.enumValue(ChromaFormat.self); bitDepth = try r.u8()
        displayMode = try r.enumValue(DisplayMode.self); bitrate = try r.u32(); refreshRate = try r.u16()
        displayPointWidth = try r.u32(); displayPointHeight = try r.u32(); audioSampleRate = try r.u32()
        audioChannels = try r.u8(); audioEncoding = try r.enumValue(AudioEncoding.self)
        doubleClickIntervalMs = try r.u32(); keyRepeatDelayMs = try r.u32(); keyRepeatIntervalMs = try r.u32()
        macInputSource = try r.string(); hostId = try r.string(); hostName = try r.string()
    }
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

/// A refusal or failure. In handshake frames (before a version is agreed) any code is accepted, so a
/// newer peer's reason still arrives; in session frames the code must be known (PROTOCOL-VERSIONING §3.1).
public struct ErrorMessage: WireMessage {
    public static let type = MessageType.error
    public struct Code: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        /// Answered only to a legacy peer (a version before negotiation), framed in its version.
        public static let versionMismatch = Code(rawValue: 1)
        public static let authenticationFailed = Code(rawValue: 2)
        // 3 (permissionMissing) and 4 (displayUnavailable) are reserved: defined in v1–v2, never sent.
        public static let `internal` = Code(rawValue: 5)
        /// The host won't start this session now: another is live (e.g. over USB, which is preferred) or it
        /// is backing off. Retry later (§7.7).
        public static let busy = Code(rawValue: 6)
        static let names: [UInt16: String] = [1: "versionMismatch", 2: "authenticationFailed", 5: "internal", 6: "busy"]
        public var isKnown: Bool { Self.names[rawValue] != nil }
        public var description: String { Self.names[rawValue] ?? "code \(rawValue)" }
    }
    public var code: Code
    public var message: String
    public init(code: Code, message: String) { self.code = code; self.message = message }
    public func encode(into w: inout ByteWriter) { w.u16(code.rawValue); w.string(message) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        let c = Code(rawValue: try r.u16())
        guard c.isKnown || r.version == LainProtocol.handshakeVersion else { throw .malformed("error code \(c.rawValue)") }
        code = c; message = try r.string()
    }
}

/// USB pairing (§7.6, D13): sent by the host on the realtime connection right after a pairing
/// `ChannelHello` (all-zero HMAC). The client stores the secret; its `Hello` confirms it.
public struct Pair: WireMessage {
    public static let type = MessageType.pair
    public static let secretSize = 32
    public var secret: [UInt8]
    /// The host's id, as in `HelloAck`: the client stores the secret for USB and for Wi-Fi
    /// (`mac:<hostId>`) together, so a cable pull can't leave a stale Wi-Fi secret (§7.7). Empty: unknown.
    public var hostId: String
    public init(secret: [UInt8], hostId: String = "") {
        precondition(secret.count == Self.secretSize)
        self.secret = secret
        self.hostId = hostId
    }
    public func encode(into w: inout ByteWriter) { w.raw(secret); w.string(hostId) }
    public init(from r: inout ByteReader) throws(ProtocolError) { secret = try r.raw(Self.secretSize); hostId = try r.string() }
}

/// Every Mac display in global point coordinates (top-left origin, main display at 0,0), so the
/// client's cursor can roam the whole desktop while only the streamed display is shown (§5.1 target
/// setup, §6.3). Sent after `HelloAck` and whenever the arrangement changes.
public struct DisplayLayout: WireMessage {
    public static let type = MessageType.displayLayout

    public struct Display: Sendable, Equatable {
        public var displayID: UInt32
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// The display shown on the iPad (at most one).
        public var isStreamed: Bool
        public init(displayID: UInt32, x: Double, y: Double, width: Double, height: Double, isStreamed: Bool) {
            self.displayID = displayID; self.x = x; self.y = y; self.width = width; self.height = height
            self.isStreamed = isStreamed
        }
    }

    public var displays: [Display]
    public init(displays: [Display]) { self.displays = displays }

    public func encode(into w: inout ByteWriter) {
        w.u8(UInt8(min(displays.count, 255)))
        for d in displays.prefix(255) { w.u32(d.displayID); w.f64(d.x); w.f64(d.y); w.f64(d.width); w.f64(d.height); w.bool(d.isStreamed) }
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        let n = Int(try r.u8())
        guard r.remaining >= n * 37 else { throw .truncated }
        var out: [Display] = []
        for _ in 0..<n {
            out.append(Display(displayID: try r.u32(), x: try r.f64(), y: try r.f64(), width: try r.f64(), height: try r.f64(),
                               isStreamed: try r.bool()))
        }
        displays = out
    }
}

/// v4: the Mac's setup state, so the iPad can say what's missing and where to fix it. Sent after
/// `HelloAck` and whenever it changes, only to peers with `ProtocolFeature.hostSetup`.
public struct HostSetup: WireMessage {
    public static let type = MessageType.hostSetup

    public enum Requirement: UInt8, Sendable, CaseIterable {
        case screenRecording = 0, accessibility = 1, localNetwork = 2, startAtLogin = 3
    }

    public enum State: UInt8, Sendable {
        case granted = 0, missing = 1
        /// The host can't tell (Local Network on macOS before the listener first advertises).
        case unknown = 2
    }

    public struct Item: Sendable, Equatable {
        public var requirement: Requirement
        public var state: State
        public init(_ requirement: Requirement, _ state: State) { self.requirement = requirement; self.state = state }
    }

    public var items: [Item]
    /// Why the live session has no video, for the owner (empty: it has video, or it's starting).
    public var videoProblem: String
    /// The Mac has a display besides lain's, where its setup window shows.
    public var hasOtherDisplay: Bool

    public init(items: [Item], videoProblem: String, hasOtherDisplay: Bool) {
        self.items = items; self.videoProblem = videoProblem; self.hasOtherDisplay = hasOtherDisplay
    }

    public func state(of requirement: Requirement) -> State? { items.first { $0.requirement == requirement }?.state }
    public var missing: [Requirement] { items.filter { $0.state == .missing }.map(\.requirement) }

    public func encode(into w: inout ByteWriter) {
        w.u8(UInt8(min(items.count, 255)))
        for item in items.prefix(255) { w.u8(item.requirement.rawValue); w.u8(item.state.rawValue) }
        w.string(videoProblem); w.bool(hasOtherDisplay)
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        let n = Int(try r.u8())
        var items: [Item] = []
        for _ in 0..<n { items.append(Item(try r.enumValue(Requirement.self), try r.enumValue(State.self))) }
        self.items = items
        videoProblem = try r.string(); hasOtherDisplay = try r.bool()
    }
}

/// v5: the iPad asks for `HostStats` every `intervalMs` (0: stop), while it shows them. Only to peers with
/// `ProtocolFeature.hostStats`.
public struct StatsRequest: WireMessage {
    public static let type = MessageType.statsRequest
    /// Clamped by the host to `HostStats.intervalRange`; 0 stops them.
    public var intervalMs: UInt32
    public init(intervalMs: UInt32) { self.intervalMs = intervalMs }
    public func encode(into w: inout ByteWriter) { w.u32(intervalMs) }
    public init(from r: inout ByteReader) throws(ProtocolError) { intervalMs = try r.u32() }
}

/// v5: what only the host knows about the video path (encode times, frames held back before the encoder,
/// frames in flight), sent every `StatsRequest.intervalMs` while the iPad asks. Counters run from the
/// start of the session's video; a time not measured yet is `HostStats.none`.
public struct HostStats: WireMessage {
    public static let type = MessageType.hostStats
    /// A time not measured yet.
    public static let none = UInt32.max
    /// The intervals the host honours.
    public static let intervalRange: ClosedRange<UInt32> = 100...5000

    /// Submit → encoded, in microseconds.
    public var encodeP50Us: UInt32
    public var encodeP95Us: UInt32
    /// Frame sent → `FrameAck` received, on the host's clock, in microseconds.
    public var ackRttP50Us: UInt32
    public var ackRttP95Us: UInt32
    public var captured: UInt32
    public var encoded: UInt32
    public var sent: UInt32
    /// Replaced in the host's latest-wins slot before the encoder took them (backpressure).
    public var droppedBeforeEncode: UInt32
    public var encodeFailures: UInt32
    public var keyframes: UInt32
    public var refinements: UInt32
    /// Sent and not yet acknowledged, now and at most.
    public var inFlight: UInt8
    public var peakInFlight: UInt8
    /// Over the last second.
    public var bitsPerSecond: UInt32

    public init(encodeP50Us: UInt32 = none, encodeP95Us: UInt32 = none, ackRttP50Us: UInt32 = none, ackRttP95Us: UInt32 = none,
                captured: UInt32 = 0, encoded: UInt32 = 0, sent: UInt32 = 0, droppedBeforeEncode: UInt32 = 0,
                encodeFailures: UInt32 = 0, keyframes: UInt32 = 0, refinements: UInt32 = 0, inFlight: UInt8 = 0,
                peakInFlight: UInt8 = 0, bitsPerSecond: UInt32 = 0) {
        self.encodeP50Us = encodeP50Us; self.encodeP95Us = encodeP95Us
        self.ackRttP50Us = ackRttP50Us; self.ackRttP95Us = ackRttP95Us
        self.captured = captured; self.encoded = encoded; self.sent = sent
        self.droppedBeforeEncode = droppedBeforeEncode; self.encodeFailures = encodeFailures
        self.keyframes = keyframes; self.refinements = refinements
        self.inFlight = inFlight; self.peakInFlight = peakInFlight; self.bitsPerSecond = bitsPerSecond
    }

    public func encode(into w: inout ByteWriter) {
        w.u32(encodeP50Us); w.u32(encodeP95Us); w.u32(ackRttP50Us); w.u32(ackRttP95Us)
        w.u32(captured); w.u32(encoded); w.u32(sent); w.u32(droppedBeforeEncode); w.u32(encodeFailures)
        w.u32(keyframes); w.u32(refinements); w.u8(inFlight); w.u8(peakInFlight); w.u32(bitsPerSecond)
    }

    public init(from r: inout ByteReader) throws(ProtocolError) {
        encodeP50Us = try r.u32(); encodeP95Us = try r.u32(); ackRttP50Us = try r.u32(); ackRttP95Us = try r.u32()
        captured = try r.u32(); encoded = try r.u32(); sent = try r.u32(); droppedBeforeEncode = try r.u32()
        encodeFailures = try r.u32(); keyframes = try r.u32(); refinements = try r.u32()
        inFlight = try r.u8(); peakInFlight = try r.u8(); bitsPerSecond = try r.u32()
    }
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

// MARK: - Cursor (H→C)

/// Sent once per unique shape (§5.4). Pixels are premultiplied BGRA, rows packed.
public struct CursorShape: WireMessage {
    public static let type = MessageType.cursorShape
    /// The host keeps at most this many shapes live. When it needs another it forgets them all and
    /// resends each shape when next used, under new ids that are higher than every earlier one, so a
    /// client that keeps this many and evicts the lowest id always holds every live shape.
    public static let maxLive = 64
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

// MARK: - Audio (H→C, the audio channel)

/// v6: the format of the `AudioPacket`s that follow, sent before the first and again if it changes. Only to
/// peers with `ProtocolFeature.audio`.
public struct AudioConfig: WireMessage {
    public static let type = MessageType.audioConfig
    public var sampleRate: UInt32
    public var channels: UInt8
    public var encoding: AudioEncoding
    public init(sampleRate: UInt32, channels: UInt8, encoding: AudioEncoding) {
        self.sampleRate = sampleRate; self.channels = channels; self.encoding = encoding
    }
    public func encode(into w: inout ByteWriter) { w.u32(sampleRate); w.u8(channels); w.u8(encoding.rawValue) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        sampleRate = try r.u32(); channels = try r.u8(); encoding = try r.enumValue(AudioEncoding.self)
    }
}

/// v6: a few milliseconds of the host's sound in the last `AudioConfig`'s format (interleaved), sent as it is
/// captured. Uncompressed: no codec delay, and small next to the video.
public struct AudioPacket: WireMessage {
    public static let type = MessageType.audioPacket
    /// When the host captured the first sample (its `CLOCK_UPTIME_RAW`, ns).
    public var captureTimeNs: UInt64
    public var samples: [UInt8]
    public init(captureTimeNs: UInt64, samples: [UInt8]) { self.captureTimeNs = captureTimeNs; self.samples = samples }
    public func encode(into w: inout ByteWriter) { w.u64(captureTimeNs); w.blob(samples) }
    public init(from r: inout ByteReader) throws(ProtocolError) { captureTimeNs = try r.u64(); samples = try r.blob() }
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

/// v6: text for the host to type as if on its keyboard, whatever its layout: what was dictated, or typed on
/// the iPad's on-screen keyboard. A line feed is Return and a tab is Tab. With `modifiers`, each character is
/// instead the key that types it in the host's layout, pressed with those modifiers held (Control-C,
/// Command-V). Only to peers with `ProtocolFeature.textInput`; long text goes in several messages
/// (`maxLength` each).
public struct TextInput: WireMessage {
    public static let type = MessageType.textInput
    /// The most characters one message carries (the sender splits; a `String` field holds 65 535 bytes).
    public static let maxLength = 1_000
    public var text: String
    /// Held while the text is typed; empty for plain text.
    public var modifiers: ModifierFlags
    public init(text: String, modifiers: ModifierFlags = []) { self.text = text; self.modifiers = modifiers }
    public func encode(into w: inout ByteWriter) { w.string(text); w.u32(modifiers.rawValue) }
    public init(from r: inout ByteReader) throws(ProtocolError) {
        text = try r.string(); modifiers = ModifierFlags(rawValue: try r.u32())
    }

    /// `text` as messages of at most `maxLength` characters each.
    public static func split(_ text: String, modifiers: ModifierFlags = []) -> [TextInput] {
        var out: [TextInput] = [], rest = Substring(text)
        while !rest.isEmpty {
            out.append(TextInput(text: String(rest.prefix(maxLength)), modifiers: modifiers))
            rest = rest.dropFirst(maxLength)
        }
        return out
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

