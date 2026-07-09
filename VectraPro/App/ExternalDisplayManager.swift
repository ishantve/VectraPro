//
//  ExternalDisplayManager.swift
//  VectraPro
//
//  Auto-shows the content on a connected external display (HDMI). As soon as
//  an external UIWindowScene activates, a UIWindow hosting DummyAnimatedScreen
//  is created on it. When the display disconnects the window is torn down.
//

import SwiftUI
import UIKit

final class ExternalDisplayManager {

    static let shared = ExternalDisplayManager()
    private init() {}

    private var externalWindows: [ObjectIdentifier: UIWindow] = [:]

    /// Call once at launch (from AppDelegate).
    func startObserving() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidDisconnect(_:)),
            name: UIScene.didDisconnectNotification, object: nil
        )

        // Attach to any external scene that is already connected at launch.
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene, ws.screen != UIScreen.main {
                present(on: ws)
            }
        }
    }

    // MARK: - Scene notifications

    @objc private func sceneDidActivate(_ note: Notification) {
        guard let ws = note.object as? UIWindowScene,
              ws.screen != UIScreen.main else { return }
        present(on: ws)
    }

    @objc private func sceneDidDisconnect(_ note: Notification) {
        guard let ws = note.object as? UIWindowScene else { return }
        externalWindows[ObjectIdentifier(ws)] = nil
        if externalWindows.isEmpty {
            WindowPresentation.shared.isRadarOpen = false
        }
    }

    // MARK: - Window creation

    private func present(on scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard externalWindows[key] == nil else { return }

        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: DummyAnimatedScreen().ignoresSafeArea()
        )
        window.makeKeyAndVisible()
        externalWindows[key] = window

        WindowPresentation.shared.isRadarOpen = true
    }
}
