//
//  WindowPresentation.swift
//  VectraPro
//

import Combine
import UIKit

final class WindowPresentation: ObservableObject {
    static let shared = WindowPresentation()
    private init() {}

    /// True while the content is detached into its own window.
    @Published var isRadarOpen = false

    /// Bumped whenever an external display connects — MainWindowView reacts by
    /// auto-opening the content window.
    @Published var externalDisplayConnectTrigger = 0

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
        if UIScreen.screens.count > 1 {
            externalDisplayConnectTrigger += 1
        }
    }

    @objc private func screenConnected(_ note: Notification) {
        externalDisplayConnectTrigger += 1
    }

    @objc private func screenDisconnected(_ note: Notification) {
        // External display unplugged — pull content back to the main window.
        isRadarOpen = false
    }
}
