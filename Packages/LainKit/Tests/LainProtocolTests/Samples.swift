@testable import LainProtocol

/// One representative value of every message type, with non-default values in every field.
enum Samples {
    /// A canonical host id, as `UUID().uuidString` writes it.
    static let hostId = "0B5D5C4E-6A1F-4E53-9C2D-7F3A8E91B264"

    static let all: [Message] = [
        .channelHello(ChannelHello(connectionKind: .video, sessionToken: Array(0..<16), hmac: Array(100..<132))),
        .hello(Hello(deviceModel: "iPad16,6 ✓", pixelWidth: 2752, pixelHeight: 2064, scale: 2, maxRefreshRate: 120,
                     decodeCapabilities: [.hevcMain, .hevcMain44410Hardware], keyboardType: .iso)),
        .helloAck(HelloAck(codec: .hevc, chroma: .yuv444, bitDepth: 10, displayMode: .primary, bitrate: 60_000_000,
                           refreshRate: 120, displayPointWidth: 1376, displayPointHeight: 1032, audioSampleRate: 48_000,
                           audioChannels: 2, audioEncoding: .pcm16LE, doubleClickIntervalMs: 500, keyRepeatDelayMs: 225,
                           keyRepeatIntervalMs: 30, macInputSource: "com.apple.keylayout.Colemak", hostId: hostId,
                           hostName: "Mac mini ✓")),
        .start(Start()),
        .stop(Stop(reason: .backgrounded)),
        .ping(Ping(id: 7, sentAtNs: 123_456_789_012)),
        .pong(Pong(id: 7, pingSentAtNs: 1, receivedAtNs: .max - 1, sentAtNs: .max)),
        .keyframeRequest(KeyframeRequest(reason: .decodeError, lastGoodFrameId: 41)),
        .stats(Stats(entries: [KeyValue(StatKey.framesDecoded, 1000), KeyValue(StatKey.decodeP95Us, -1)])),
        .configUpdate(ConfigUpdate(entries: [KeyValue(ConfigKey.bitrate, 150_000_000)])),
        .displayChanged(DisplayChanged(displayID: 5, pixelWidth: 2752, pixelHeight: 2064, pointWidth: 1376,
                                       pointHeight: 1032, refreshRate: 60)),
        .error(ErrorMessage(code: .versionMismatch, message: "host speaks v2")),
        .pair(Pair(secret: Array(200..<232), hostId: hostId)),
        .displayLayout(DisplayLayout(displays: [
            DisplayLayout.Display(displayID: 2, x: 0, y: 0, width: 1680, height: 1050, isStreamed: false),
            DisplayLayout.Display(displayID: 18, x: 0, y: 1050, width: 1376, height: 1032, isStreamed: true),
            DisplayLayout.Display(displayID: 3, x: -1920, y: 0, width: 1920, height: 1200, isStreamed: false),
        ])),
        .videoConfig(VideoConfig(configId: 3, codec: .hevc, chroma: .yuv444, bitDepth: 10, width: 2752, height: 2064,
                                 fullRange: true, colorPrimaries: 12, transferFunction: 13, matrix: 1,
                                 parameterSets: [[0x40, 0x01], [0x42, 0x01, 0x01], [0x44, 0x01]])),
        .videoFrame(VideoFrame(frameId: 99, configId: 3, captureTimeNs: 10, encodeDoneNs: 20, isKeyframe: true,
                               data: [0, 0, 0, 3, 0x26, 0x01, 0xAF])),
        .frameAck(FrameAck(frameId: 99, receivedAtNs: 30, bytes: 1_200_000)),
        .audioConfig(AudioConfig(sampleRate: 48_000, channels: 2, encoding: .pcm16LE, framesPerPacket: 240)),
        .audioPacket(AudioPacket(packetId: 12, captureTimeNs: 40, samples: [1, 2, 3, 4])),
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
        .probeRequest(ProbeRequest(probeId: 8, sentAtNs: 50)),
        .probeAck(ProbeAck(probeId: 8, detectedAtNs: 60)),
    ]
}
