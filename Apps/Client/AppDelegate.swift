import Foundation
import LainClientCore
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// As a test host (LainClientTests) the app starts no session: no listener, and above all no Wi-Fi
    /// loop browsing the real network during a test run (§7.7 D29).
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    /// Strips the app's own main menu (§6.4): the default iPadOS menu claims Cmd-Z/X/C/V/A/F/… and would
    /// swallow them before they reach the Mac.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main, let root = builder.menu(for: .root) else { return }
        let extra: [UIMenu.Identifier] = [.quit, .close, .hide, .bringAllToFront, .minimizeAndZoom, .fullscreen]
        for id in root.children.compactMap({ ($0 as? UIMenu)?.identifier }) + extra { builder.remove(menu: id) }
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let input = ClientInput()
    private let video = ClientVideoPipeline()
    /// The host's sound, played on the iPad.
    private let audio = ClientAudioPlayer()
    private var session: ClientSession?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // The display asked of the host: the screen's own, or the device's home display (the Duo's inner one,
        // whichever of its two screens the app opened on).
        let screen = windowScene.screen
        let model = ClientStatus.hardwareModel()
        let native = screen.nativeBounds.size
        var display = (pixelWidth: Int(max(native.width, native.height)), pixelHeight: Int(min(native.width, native.height)),
                       scale: Int(screen.nativeScale))
        if let home = ClientStatus.homeDisplay(model: model) { display = home }
        let stream = StreamViewController(input: input, video: video,
                                          referenceWidth: Double(display.pixelWidth) / Double(max(display.scale, 1)))
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = stream
        window.makeKeyAndVisible()
        self.window = window
        guard !AppDelegate.isTestHost else { return }
        let hello = Hello(deviceModel: model, pixelWidth: UInt32(display.pixelWidth), pixelHeight: UInt32(display.pixelHeight),
                          scale: UInt8(display.scale), maxRefreshRate: UInt16(screen.maximumFramesPerSecond),
                          // S3c: HEVC Main 4:4:4 10 only if the embedded vector decodes in hardware here.
                          decodeCapabilities: ClientVideoPipeline.probeDecodeCapabilities(),
                          keyboardType: .unknown)
        startSession(hello: hello, view: stream)
    }

    /// The window moved or changed size (a turn, a fold, Split View, or its two apps swapping sides, which
    /// changes nothing else): lay out again, since the controls follow the side of the screen it is on.
    func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry) {
        window?.rootViewController?.view.setNeedsLayout()
    }

    // Invariant 4: anything that takes focus away releases everything on the Mac.
    func sceneWillResignActive(_ scene: UIScene) {
        input.releaseAll(.focusLost)
        (window?.rootViewController as? StreamViewController)?.diag("scene will resign")
    }
    /// iPadOS suspends the app soon: Wi-Fi discovery pauses (§7.7).
    func sceneDidEnterBackground(_ scene: UIScene) {
        input.releaseAll(.focusLost)
        session?.sceneDidEnterBackground()
    }
    /// §6.1: back in front, the picture may be stale; ask for a keyframe (sent only while connected).
    /// Wi-Fi discovery, which may have died while suspended, is recreated.
    func sceneDidBecomeActive(_ scene: UIScene) {
        video.requestKeyframe(.resumed)
        session?.sceneDidBecomeActive()
        (window?.rootViewController as? StreamViewController)?.sceneBecameActive()
    }

    /// The loopback listener the Mac dials through usbmuxd (§7.2), and the Wi-Fi loop that finds paired
    /// Macs over Bonjour and dials them when no cable is connected (§7.7). Both work only while the app
    /// is in the foreground; iPadOS suspends them otherwise.
    private func startSession(hello: Hello, view: StreamViewController) {
        let wifi = ClientWiFiConfig(discovery: { BonjourHostDiscovery(serviceType: LainProtocol.bonjourServiceType) },
                                    lastHost: .userDefaults())
        do {
            session = try ClientSession(secrets: KeychainSecretStore(), hello: hello, input: input, video: video,
                                        wifi: wifi) { [weak view] status in
                // Main-queue hops keep statuses in order (the session publishes them in order).
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
