import LainClientCore
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
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
    private var session: ClientSession?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let stream = StreamViewController(input: input, video: video)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = stream
        window.makeKeyAndVisible()
        self.window = window
        startSession(screen: windowScene.screen, view: stream)
    }

    // Invariant 4: anything that takes focus away releases everything on the Mac.
    func sceneWillResignActive(_ scene: UIScene) { input.releaseAll(.focusLost) }
    func sceneDidEnterBackground(_ scene: UIScene) { input.releaseAll(.focusLost) }
    /// §6.1: back in front, the picture may be stale; ask for a keyframe (sent only while connected).
    func sceneDidBecomeActive(_ scene: UIScene) { video.requestKeyframe(.resumed) }

    /// The loopback listener the Mac dials through usbmuxd (§7.2). It only accepts while the app is in
    /// the foreground; iPadOS suspends it otherwise.
    private func startSession(screen: UIScreen, view: StreamViewController) {
        let native = screen.nativeBounds.size
        let hello = Hello(deviceModel: Self.modelIdentifier(), pixelWidth: UInt32(max(native.width, native.height)),
                          pixelHeight: UInt32(min(native.width, native.height)), scale: UInt8(screen.nativeScale),
                          maxRefreshRate: UInt16(screen.maximumFramesPerSecond),
                          // S3c: HEVC Main 4:4:4 10 only if the embedded vector decodes in hardware here.
                          decodeCapabilities: ClientVideoPipeline.probeDecodeCapabilities(),
                          keyboardType: .unknown)
        do {
            session = try ClientSession(secrets: KeychainSecretStore(), hello: hello, input: input, video: video) { [weak view] status in
                Task { @MainActor in view?.status = ClientStatus(status) }
            }
        } catch {
            view.status = .failed("\(error)")
        }
    }

    private static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
