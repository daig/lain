/// One representative value of every message type, with a non-default value in every field. The schema
/// digests (`SchemaDigest`) and the golden bytes (tests) are made from these, so an existing value never
/// changes: a new field gets a new value (PROTOCOL-VERSIONING §6).
public enum ProtocolSamples {
    /// A canonical host id, as `UUID().uuidString` writes it.
    public static let hostId = "0B5D5C4E-6A1F-4E53-9C2D-7F3A8E91B264"

    /// A version list with fixed digests (never `VersionList.offered`: its digests are made from these).
    public static let versions = VersionList([
        VersionEntry(version: 3, digest: Array(1...8)),
        VersionEntry(version: 4, digest: Array(11...18)),
    ])

    public static let all: [Message] = [
        .channelHello(ChannelHello(versions: versions, connectionKind: .video, sessionToken: Array(0..<16),
                                   hmac: Array(100..<132))),
        .channelAccept(ChannelAccept(chosen: 4, versions: versions)),
        .hello(Hello(deviceModel: "iPad16,6 ✓", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                     decodeCapabilities: [.hevcMain, .hevcMain44410Hardware], keyboardType: .iso)),
        .helloAck(HelloAck(codec: .hevc, chroma: .yuv444, bitDepth: 10, displayMode: .primary, bitrate: 60_000_000,
                           refreshRate: 120, displayPointWidth: 1376, displayPointHeight: 1032, audioSampleRate: 48_000,
                           audioChannels: 2, audioEncoding: .pcm16LE, doubleClickIntervalMs: 500, keyRepeatDelayMs: 225,
                           keyRepeatIntervalMs: 30, macInputSource: "com.apple.keylayout.Colemak", hostId: hostId,
                           hostName: "Mac mini ✓")),
        .ping(Ping(id: 7, sentAtNs: 123_456_789_012)),
        .pong(Pong(id: 7, pingSentAtNs: 1, receivedAtNs: .max - 1, sentAtNs: .max)),
        .keyframeRequest(KeyframeRequest(reason: .decodeError, lastGoodFrameId: 41)),
        .error(ErrorMessage(code: .busy, message: "a USB session is live")),
        .pair(Pair(secret: Array(200..<232), hostId: hostId)),
        .displayLayout(DisplayLayout(displays: [
            DisplayLayout.Display(displayID: 2, x: 0, y: 0, width: 1680, height: 1050, isStreamed: false),
            DisplayLayout.Display(displayID: 18, x: 0, y: 1050, width: 1376, height: 1032, isStreamed: true),
            DisplayLayout.Display(displayID: 3, x: -1920, y: 0, width: 1920, height: 1200, isStreamed: false),
        ])),
        .hostSetup(HostSetup(items: [HostSetup.Item(.screenRecording, .missing), HostSetup.Item(.accessibility, .granted),
                                     HostSetup.Item(.localNetwork, .unknown), HostSetup.Item(.startAtLogin, .missing)],
                             videoProblem: "Screen Recording is off ✓", hasOtherDisplay: true)),
        .videoConfig(VideoConfig(configId: 3, codec: .hevc, chroma: .yuv444, bitDepth: 10, width: 2752, height: 2064,
                                 fullRange: true, colorPrimaries: 12, transferFunction: 13, matrix: 1,
                                 parameterSets: [[0x40, 0x01], [0x42, 0x01, 0x01], [0x44, 0x01]])),
        .videoFrame(VideoFrame(frameId: 99, configId: 3, captureTimeNs: 10, encodeDoneNs: 20, isKeyframe: true,
                               data: [0, 0, 0, 3, 0x26, 0x01, 0xAF])),
        .frameAck(FrameAck(frameId: 99, receivedAtNs: 30, bytes: 1_200_000)),
        .cursorShape(CursorShape(shapeId: 2, pixelWidth: 2, pixelHeight: 1, scale: 2, hotspotX: 0.5, hotspotY: 1.25,
                                 pixels: [1, 2, 3, 4, 5, 6, 7, 8])),
        .cursorSelect(CursorSelect(shapeId: 2, visible: false)),
        .cursorWarp(CursorWarp(x: 688.5, y: -3)),
        .keyEvent(KeyEvent(usage: 0x2B, isDown: true, isRepeat: true, modifiers: [.command, .shift])),
        .pointerMove(PointerMove(x: 100.25, y: 1031.75, dx: -7, dy: 97, buttons: 0b01)),
        .pointerButton(PointerButton(button: .right, isDown: true, clickCount: 2, x: 1, y: 2, modifiers: [.control])),
        .scroll(Scroll(dx: 0.5, dy: -12.25, phase: .ended, momentumPhase: .changed)),
        .gesture(Gesture(kind: .rotate, phase: .changed, value: 0.125)),
        .releaseAll(ReleaseAll(reason: .pointerLockLost)),
    ]
}
