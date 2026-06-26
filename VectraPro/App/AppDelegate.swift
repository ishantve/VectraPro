//
//  AppDelegate.swift
//  VectraPro
//
//  Routes external-display scenes:
//   • M-series iPad → destroy the auto scene so the monitor is a real
//     interactive extended desktop (the user drags the radar window onto it
//     via Stage Manager; mouse + keyboard then work there).
//   • Other iPads → present the radar map on the monitor (non-interactive,
//     controlled from the iPad).
//

import GoogleMaps
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        GMSServices.provideAPIKey(AppConfiguration.googleMapsAPIKey)
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {

        let role = connectingSceneSession.role
        if role.rawValue.contains("ExternalDisplay") {
            let config = UISceneConfiguration(name: "External", sessionRole: role)
            config.delegateClass = ExternalSceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: "Default", sessionRole: role)
    }
}

final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // Present the radar directly on the external display — stable, no scene
        // destruction (which loops) and no window open/close churn.
        let provider = MapProvider.current
        let host: UIViewController
        if provider == .google {
            host = UIHostingController(rootView: GoogleRadarMapView(viewModel: MapViewModel.shared).ignoresSafeArea())
        } else {
            host = UIHostingController(rootView: RadarMapView(
                viewModel: MapViewModel.shared,
                styleURL: MapStyleProvider.styleURL(for: provider)
            ).ignoresSafeArea())
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = host
        self.window = window
        window.makeKeyAndVisible()

        RadarPresentation.shared.isMapDetached = true
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        RadarPresentation.shared.isMapDetached = false
    }
}
