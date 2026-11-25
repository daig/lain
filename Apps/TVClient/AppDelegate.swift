import Foundation
import LainClientCore
import LainTransport
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// As a test host (`LainTVClientTests`) the app starts no session or network browse.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func applicationWillTerminate(_ application: UIApplication) {
        for scene in application.connectedScenes {
            (scene.delegate as? SceneDelegate)?.quitSession()
        }
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let input = ClientInput()
    private let video = ClientVideoPipeline()
    private let audio = ClientAudioPlayer()
    private var session: ClientSession?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var backgroundTimer: DispatchWorkItem?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let screen = windowScene.screen
        let model = ClientStatus.hardwareModel()
        let native = screen.nativeBounds.size
        let pixelWidth = Int(max(native.width, native.height))
        let pixelHeight = Int(min(native.width, native.height))
        let scale = max(Int(screen.nativeScale.rounded()), 1)
        let nativeScale = UInt16(clamping: scale * 100)

        let stream = TVStreamViewController(input: input, video: video,
                                            referenceWidth: Double(pixelWidth) / Double(scale),
                                            nativeScale: nativeScale)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = stream
        window.makeKeyAndVisible()
        stream.view.layoutIfNeeded()
        self.window = window

        guard !AppDelegate.isTestHost else { return }
        let prefs = ClientPreferences.load(nativeScale: nativeScale)
        let hello = Hello(deviceModel: model,
                          pixelWidth: UInt32(pixelWidth),
                          pixelHeight: UInt32(pixelHeight),
                          scale: UInt8(clamping: scale),
                          maxRefreshRate: UInt16(clamping: screen.maximumFramesPerSecond),
                          decodeCapabilities: ClientVideoPipeline.probeDecodeCapabilities(),
                          keyboardType: .unknown,
                          desiredScale: prefs.activeDisplayScale,
                          desiredDisplayMode: prefs.wireDisplayMode)
        startSession(hello: hello, view: stream)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        input.releaseAll(.focusLost)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        input.releaseAll(.focusLost)
        session?.sceneDidEnterBackground()
        beginQuitGraceTask()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        endQuitGraceTask()
        video.requestKeyframe(.resumed)
        session?.sceneDidBecomeActive()
        (window?.rootViewController as? TVStreamViewController)?.sceneBecameActive()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        quitSession()
    }

    func quitSession() {
        endQuitGraceTask()
        session?.quit()
    }

    private func beginQuitGraceTask() {
        endQuitGraceTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "lain.tv.quitGrace") { [weak self] in
            MainActor.assumeIsolated { self?.endQuitGraceTask() }
        }
        guard backgroundTask != .invalid else { return }
        let work = DispatchWorkItem { [weak self] in self?.endQuitGraceTask() }
        backgroundTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func endQuitGraceTask() {
        backgroundTimer?.cancel()
        backgroundTimer = nil
        guard backgroundTask != .invalid else { return }
        let id = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    private func startSession(hello: Hello, view: TVStreamViewController) {
        let wifi = ClientWiFiConfig(discovery: { BonjourHostDiscovery(serviceType: LainProtocol.bonjourServiceType) },
                                    lastHost: .userDefaults(),
                                    wakeOnLAN: WakeOnLAN.send)
        do {
            session = try ClientSession(listenForUSB: false, secrets: KeychainSecretStore(), hello: hello, input: input,
                                        video: video, wifi: wifi) { [weak view] status in
                DispatchQueue.main.async { MainActor.assumeIsolated { view?.status = ClientStatus(status) } }
            }
            view.session = session
            view.audio = audio
            session?.setAudioPlayer(audio)
        } catch {
            view.status = .failed("\(error)")
        }
    }
}
