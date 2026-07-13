//
//  WindowPresentation.swift
//  VectraPro
//

import Combine
import UIKit
import SwiftUI

// MARK: - App Mode

enum AppMode {
    case stageManager   // SwiftUI openWindow approach
    case hdmiAuto       // UIKit UIWindow on external screen approach
}

// MARK: - WindowPresentation

final class WindowPresentation: ObservableObject {
    static let shared = WindowPresentation()
    private init() {}

    /// Which demo mode the user has selected from the home screen.
    @Published var selectedMode: AppMode? = nil

    /// True while the content is detached into its own SwiftUI window (Stage Manager mode).
    @Published var isRadarOpen = false

    /// Bumped whenever an external display connects — MainWindowView reacts by
    /// auto-opening the content window (Stage Manager mode).
    @Published var externalDisplayConnectTrigger = 0

    /// Holds the UIKit window shown on the external screen (HDMI Auto mode).
    private var externalWindow: UIWindow?

    /// The window scene hosting the radar/extended window (Stage Manager mode).
    /// Captured on appear so we can fully destroy it on close.
    weak var radarScene: UIWindowScene?

    /// Fully close + destroy the radar window scene so it reopens fresh.
    func closeRadarWindow() {
        if let scene = radarScene {
            UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
            radarScene = nil
        }
        isRadarOpen = false
    }

    // MARK: - Display observation

    /// Start listening for HDMI / external display connect + disconnect.
    /// Call once at launch (from AppDelegate).
    func startObservingDisplays() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConnected(_:)),
            name: UIScreen.didConnectNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDisconnected(_:)),
            name: UIScreen.didDisconnectNotification,
            object: nil
        )

        // If a display is already attached at launch, trigger once.
        let externalAtLaunch = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.screen != UIScreen.main }
        if !externalAtLaunch.isEmpty {
            externalDisplayConnectTrigger += 1
        }
    }

    @objc private func screenConnected(_ note: Notification) {
        switch selectedMode {
        case .stageManager:
            externalDisplayConnectTrigger += 1
        case .hdmiAuto:
            if let screen = note.object as? UIScreen {
                openUIKitWindow(on: screen)
            }
        case nil:
            // Mode not chosen yet — store trigger so it fires after selection
            externalDisplayConnectTrigger += 1
        }
    }

    @objc private func screenDisconnected(_ note: Notification) {
        switch selectedMode {
        case .stageManager:
            isRadarOpen = false
        case .hdmiAuto:
            closeUIKitWindow()
        case nil:
            isRadarOpen = false
        }
    }

    // MARK: - UIKit external window (HDMI Auto mode)

    func openUIKitWindow(on screen: UIScreen) {
        guard externalWindow == nil else { return }

        // Find the UIWindowScene that belongs to the external screen.
        // UIScreen.didConnectNotification gives us the UIScreen; we look up
        // the matching scene from the currently active sessions.
        let externalScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.screen == screen }

        guard let scene = externalScene else {
            // Scene not ready yet — store the screen and retry after a short delay.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openUIKitWindow(on: screen)
            }
            return
        }

        let window = UIWindow(windowScene: scene)
        let hostingVC = UIHostingController(rootView: DummyAnimatedScreen())
        hostingVC.view.backgroundColor = .black
        window.rootViewController = hostingVC
        window.isHidden = false
        externalWindow = window
    }

    func closeUIKitWindow() {
        externalWindow?.isHidden = true
        externalWindow = nil
    }

    /// Called when user picks HDMI Auto mode and a screen is already connected.
    func triggerHDMIAutoIfScreenPresent() {
        guard selectedMode == .hdmiAuto else { return }
        // Find external window scenes (screens other than the main one).
        let externalScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.screen != UIScreen.main }
        if let scene = externalScenes.first {
            openUIKitWindow(on: scene.screen)
        }
    }
}
