//
//  ExternalDisplayManager.swift
//  VectraPro
//
//  Moves the radar map onto an external display when one is connected, and
//  back to the iPad when it disconnects. The same map view is reparented (not
//  recreated), so the transition is seamless.
//

import Combine
import MapLibre
import SwiftUI
import UIKit

final class ExternalDisplayManager: ObservableObject {

    @Published private(set) var isActive = false

    private let controller: RadarMapController
    private var externalWindow: UIWindow?

    init(controller: RadarMapController) {
        self.controller = controller

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screenConnected(_:)),
                           name: UIScreen.didConnectNotification, object: nil)
        center.addObserver(self, selector: #selector(screenDisconnected(_:)),
                           name: UIScreen.didDisconnectNotification, object: nil)

        // Handle a display already connected at launch.
        if let screen = UIScreen.screens.first(where: { $0 !== UIScreen.main }) {
            attach(to: screen)
        }
    }

    @objc private func screenConnected(_ note: Notification) {
        guard let screen = note.object as? UIScreen else { return }
        attach(to: screen)
    }

    @objc private func screenDisconnected(_ note: Notification) {
        detach()
    }

    private func attach(to screen: UIScreen, retriesLeft: Int = 10) {
        guard externalWindow == nil else { return }

        // The external display is hosted by its own UIWindowScene (created
        // asynchronously by the system). Build our window in that scene and put
        // it above the auto-created window so the map shows, not the app root.
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.screen === screen }) else {
            guard retriesLeft > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.attach(to: screen, retriesLeft: retriesLeft - 1)
            }
            return
        }

        let window = UIWindow(windowScene: windowScene)
        let host = UIHostingController(rootView: RadarMapView(controller: controller).ignoresSafeArea())
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()

        externalWindow = window
        isActive = true   // iPad side switches to controls-only; map reparents here
    }

    private func detach() {
        externalWindow?.isHidden = true
        externalWindow = nil
        isActive = false   // map reparents back to the iPad
    }
}
