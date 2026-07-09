//
//  AppDelegate.swift
//  VectraPro
//

import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ExternalDisplayManager.shared.startObserving()
        return true
    }
}
