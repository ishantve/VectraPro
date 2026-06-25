//
//  VectraProApp.swift
//  VectraPro
//
//  Created by Ishant Zibal on 24/06/26.
//

import GoogleMaps
import SwiftUI

@main
struct VectraProApp: App {

    init() {
        GMSServices.provideAPIKey(AppConfiguration.googleMapsAPIKey)
    }

    var body: some Scene {
        WindowGroup {
            HomeScreen()
        }
    }
}
