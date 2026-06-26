//
//  VectraProApp.swift
//  VectraPro
//
//  Created by Ishant Zibal on 24/06/26.
//

import SwiftUI

@main
struct VectraProApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            HomeScreen()
        }
    }
}
