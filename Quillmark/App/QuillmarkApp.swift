import SwiftUI
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PresentationCenter.shared.startObserving()
        BackupArchiveService.pruneTemporaryBackups(keepingMostRecent: 2)
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let configuration = UISceneConfiguration(name: "External Display", sessionRole: connectingSceneSession.role)
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
            return configuration
        }
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = MainSceneDelegate.self
        return configuration
    }
}

final class MainSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let library = LibraryStore.shared
        let rootViewController = UIHostingController(rootView: LibraryView().environmentObject(library))
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        self.window = window

        PresentationCenter.shared.registerSceneAccessory(on: rootViewController)
        PresentationCenter.shared.scanDisplays()

        if let url = connectionOptions.urlContexts.first?.url, url.isFileURL {
            library.pendingImportURL = url
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url, url.isFileURL {
            LibraryStore.shared.pendingImportURL = url
        }
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        PresentationCenter.shared.scanDisplays()
    }
}
