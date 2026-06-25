//
//  AppConfiguration.swift
//  VectraPro
//
//  App-wide configuration & secrets.
//

import Foundation

enum AppConfiguration {

    /// Google Maps SDK key.
    ///
    /// ⚠️ Checked into source for convenience. For production, move this to an
    /// untracked `.xcconfig` / Info.plist entry and rotate the key, since it is
    /// currently visible in version control.
    static let googleMapsAPIKey = "AIzaSyDmGBLJSEtjlV_Tuy-hhv-VKDBSW6lP5YI"
}
