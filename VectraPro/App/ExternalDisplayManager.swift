//
//  ExternalDisplayManager.swift
//  VectraPro
//
//  Shows the radar on an external display only while an exercise is active.
//  Call exerciseStarted() when MapScreen appears and exerciseEnded() when it
//  disappears — the manager handles opening / closing the external window.
//

import SwiftUI
import UIKit

final class ExternalDisplayManager {

    static let shared = ExternalDisplayManager()
    private init() {}

    private var externalWindows: [ObjectIdentifier: UIWindow] = [:]
    private var isExerciseActive = false

    // MARK: - Lifecycle

    /// Register scene observers. Call once from AppDelegate at launch.
    func startObserving() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneActivated(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDisconnected(_:)),
            name: UIScene.didDisconnectNotification,
            object: nil
        )
    }

    // MARK: - Exercise lifecycle

    /// Call when MapScreen appears (exercise starts).
    func exerciseStarted() {
        isExerciseActive = true
        // Show radar on any external scene that is already connected.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.screen != UIScreen.main else { continue }
            presentRadar(on: windowScene)
        }
    }

    /// Call when MapScreen disappears (back button / exercise ends).
    func exerciseEnded() {
        isExerciseActive = false
        externalWindows.values.forEach { window in
            window.rootViewController = nil   // triggers onDisappear in RadarWindowScene
            window.isHidden = true
        }
        externalWindows.removeAll()
    }

    // MARK: - Scene notifications

    @objc private func sceneActivated(_ notification: Notification) {
        guard isExerciseActive,
              let scene = notification.object as? UIWindowScene,
              scene.screen != UIScreen.main else { return }
        presentRadar(on: scene)
    }

    @objc private func sceneDisconnected(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        externalWindows[ObjectIdentifier(scene)] = nil
    }

    // MARK: - Window creation

    private func presentRadar(on scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard externalWindows[key] == nil else { return }

        let window = UIWindow(windowScene: scene)
        let side = min(scene.screen.bounds.width, scene.screen.bounds.height)
        window.frame = CGRect(x: 0, y: 0, width: side, height: side)
        window.rootViewController = UIHostingController(
            rootView: RadarWindowScene().ignoresSafeArea()
        )
        window.makeKeyAndVisible()
        externalWindows[key] = window
    }
}
