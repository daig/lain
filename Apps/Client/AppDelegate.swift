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
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var endpoint: ClientEndpoint?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let connect = ConnectViewController()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = connect
        window.makeKeyAndVisible()
        self.window = window
        startEndpoint(screen: windowScene.screen, view: connect)
    }

    /// The loopback listener the Mac dials through usbmuxd (§7.2). It only accepts while the app is in
    /// the foreground; iPadOS suspends it otherwise.
    private func startEndpoint(screen: UIScreen, view: ConnectViewController) {
        let native = screen.nativeBounds.size
        let hello = Hello(deviceModel: Self.modelIdentifier(), pixelWidth: UInt32(max(native.width, native.height)),
                          pixelHeight: UInt32(min(native.width, native.height)), scale: UInt8(screen.nativeScale),
                          maxRefreshRate: UInt16(screen.maximumFramesPerSecond), decodeCapabilities: [.hevcMain],
                          keyboardType: .unknown)
        do {
            endpoint = try ClientEndpoint(secrets: KeychainSecretStore(), hello: hello) { [weak view] status in
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
