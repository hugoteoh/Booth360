import SwiftUI
import UIKit

/// Only external-display sessions get this delegate. SwiftUI continues to own
/// the phone's application scene and its single camera preview.
@MainActor
final class Booth360AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive
            || connectingSceneSession.role == .windowExternalDisplay {
            let configuration = UISceneConfiguration(name: "Booth360 TV", sessionRole: connectingSceneSession.role)
            configuration.sceneClass = UIWindowScene.self
            configuration.delegateClass = ExternalWallSceneDelegate.self
            return configuration
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}

@MainActor
final class ExternalWallSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    private var sessionID: String?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene,
              session.role == .windowExternalDisplayNonInteractive || session.role == .windowExternalDisplay,
              ExternalWallController.shared.connect(sessionID: session.persistentIdentifier) else { return }
        sessionID = session.persistentIdentifier
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: ExternalWallView())
        window.backgroundColor = .black
        window.isUserInteractionEnabled = false
        // Never make the television the key window; camera/phone keeps focus.
        window.isHidden = false
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let sessionID else { return }
        ExternalWallController.shared.setDisplayActive(true, sessionID: sessionID)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        guard let sessionID else { return }
        ExternalWallController.shared.setDisplayActive(false, sessionID: sessionID)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if let sessionID { ExternalWallController.shared.disconnect(sessionID: sessionID) }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        sessionID = nil
    }
}
