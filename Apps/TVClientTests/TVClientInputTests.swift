import Foundation
import LainClientCore
import LainInput
import LainProtocol
import LainTransport
import Testing
import UIKit
@testable import LainTVClient

/// Hosted tvOS Simulator integration tests running inside `LainTVClient.app` on Apple TV 4K.
@Suite(.serialized) @MainActor struct TVClientInputTests {
    private func makeVC() -> (TVStreamViewController, UIWindow, Box<[Message]>) {
        let sent = Box<[Message]>([])
        let input = ClientInput()
        input.connect { sent.value.append($0) }
        input.configure(HelloAck(codec: .hevc, chroma: .yuv420, bitDepth: 8, displayMode: .primary,
                                 bitrate: 30_000_000, refreshRate: 60,
                                 displayPointWidth: 1920, displayPointHeight: 1080,
                                 audioSampleRate: 48_000, audioChannels: 2, audioEncoding: .pcm16LE,
                                 doubleClickIntervalMs: 500, keyRepeatDelayMs: 400, keyRepeatIntervalMs: 50,
                                 macInputSource: "com.apple.keylayout.US",
                                 hostId: UUID().uuidString, hostName: "TestMac",
                                 displayScale: 200, displayScales: [100, 150, 200, 250]))
        let video = ClientVideoPipeline()
        let vc = TVStreamViewController(input: input, video: video, referenceWidth: 1920, nativeScale: 200)
        vc.acceptsRemoteInputWhenDisconnected = true
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        }
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.layoutIfNeeded()
        return (vc, window, sent)
    }

    @Test func tvViewControllerInitializesAt4KPointsAndRoutesRemoteInput() async throws {
        let (vc, _, sent) = makeVC()
        let start = vc.input.cursor

        // Simulate thumb swipe across the Siri Remote clickpad.
        vc.input.remoteSurfaceTouched(true)
        vc.input.remoteSurfaceMoved(x: -0.2, y: 0.0)
        vc.input.remoteSurfaceMoved(x: 0.3, y: 0.1)
        vc.input.remoteSurfaceTouched(false)
        // Simulate hardware lift-to-zero after touch-up (must not snap cursor back).
        vc.input.remoteSurfaceMoved(x: 0.0, y: 0.0)
        // Center click.
        vc.input.remoteCenterButton(isDown: true)
        vc.input.remoteCenterButton(isDown: false)

        // Drain input queue.
        let end = vc.input.sync { $0.pointer }
        #expect(end.x > start.x)
        #expect(end.y < start.y)   // pad +y is cursor up (smaller y)
        #expect(sent.value.contains { if case .pointerMove = $0 { true } else { false } })
        #expect(sent.value.filter { if case .pointerButton = $0 { true } else { false } }.count == 2)
    }

    @Test func tvZoomAndDragLockUpdateLocalModeStateAndViewport() async throws {
        let (vc, _, _) = makeVC()
        #expect(vc.input.viewport == .full)
        #expect(!vc.currentRemoteState.zoomed)
        #expect(!vc.currentRemoteState.dragLocked)

        vc.input.toggleZoom()
        _ = vc.input.sync { $0.isZoomed }
        try await Task.sleep(for: .milliseconds(80))
        #expect(abs(vc.input.viewport.width - 0.5) < 1e-6)
        #expect(vc.currentRemoteState.zoomed)

        vc.input.setRemoteDragLocked(true)
        _ = vc.input.sync { $0.remote.isDragLocked }
        try await Task.sleep(for: .milliseconds(80))
        #expect(vc.currentRemoteState.dragLocked)

        vc.input.setRemoteDragLocked(false)
        vc.input.toggleZoom()
        _ = vc.input.sync { $0.isZoomed }
        try await Task.sleep(for: .milliseconds(80))
        #expect(vc.input.viewport == .full)
        #expect(!vc.currentRemoteState.zoomed && !vc.currentRemoteState.dragLocked)
    }

    @Test func tvOverlayPresentsAndDismissesCleanly() async throws {
        let (vc, window, _) = makeVC()
        _ = window
        #expect(!vc.isOverlayPresented)

        vc.input.openPanel()
        for _ in 0..<30 where !(vc.presentedViewController is TVOverlayViewController) || vc.presentedViewController?.isBeingPresented == true {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(vc.isOverlayPresented)
        #expect(vc.presentedViewController is TVOverlayViewController)
        #expect(vc.controllerUserInteractionEnabled)

        vc.input.closePanel()
        for _ in 0..<30 where vc.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!vc.isOverlayPresented)
        #expect(vc.presentedViewController == nil)
    }

    @Test func tvTypeTextReachesHostViaTextInputMessage() async throws {
        let (vc, window, sent) = makeVC()
        _ = window
        vc.input.typeText("hello tv")
        _ = vc.input.sync { $0.isConfigured }
        let typed = sent.value.compactMap { msg -> String? in
            if case .textInput(let t) = msg { t.text } else { nil }
        }
        #expect(typed == ["hello tv"])
    }

    @Test func tvPairingModalExplainsContinuityKeyboardAndPairsCode() async throws {
        let (vc, window, _) = makeVC()
        _ = window
        let store = InMemorySecretStore()
        let hostId = UUID().uuidString
        let secret = ChannelAuth.randomBytes(32)
        let encoded = try PairingCode(hostId: hostId, secret: secret, hostName: "dai-AI90").encode()
        let hello = Hello(deviceModel: "AppleTV14,1", pixelWidth: 3840, pixelHeight: 2160, scale: 2,
                          maxRefreshRate: 60, decodeCapabilities: [], keyboardType: .unknown)
        let session = try ClientSession(listenForUSB: false, secrets: store, hello: hello,
                                        wifi: ClientWiFiConfig(discovery: { FixedHostDiscovery() })) { _ in }
        defer { session.stop() }
        vc.session = session

        vc.presentPairing(for: ClientSession.UnpairedHost(id: hostId, name: "dai-AI90", keyRefused: false))
        for _ in 0..<30 where !(vc.presentedViewController is TVPairHostViewController) || vc.presentedViewController?.isBeingPresented == true {
            try await Task.sleep(for: .milliseconds(50))
        }
        let modal = try #require(vc.presentedViewController as? TVPairHostViewController)
        modal.view.layoutIfNeeded()

        // Invalid code returns an inline error; valid lain1:... code stores the secret under mac:<hostId>.
        #expect(modal.onPair?("not-a-code") != nil)
        #expect(try store.secret(for: PairingAccounts.mac(hostId)) == nil)
        #expect(modal.onPair?(encoded) == nil)
        #expect(try store.secret(for: PairingAccounts.mac(hostId)) == secret)

        modal.dismiss(animated: false)
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
