//
//  AppDelegate.swift
//  VectraPro
//
//  Provides the Google Maps API key. External-display scenes are left to the
//  system: with Stage Manager ON the monitor is an interactive extended desktop
//  onto which the user drags the radar window (mouse + keyboard work there).
//

import GoogleMaps
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        GMSServices.provideAPIKey(AppConfiguration.googleMapsAPIKey)
        return true
    }
}
