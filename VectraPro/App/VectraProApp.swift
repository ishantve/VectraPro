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
        WindowGroup(id: "main") {
            HomeScreen()
        }

        // Radar in its own window. Opened manually from MapScreen; the user
        // drags it onto the external monitor (Stage Manager), where it stays a
        // normal interactive window — mouse + keyboard work there.
        WindowGroup(id: "radar") {
            RadarWindowScene()
        }
    }
}

struct RadarWindowScene: View {
    @AppStorage(MapProvider.storageKey) private var providerRaw = MapProvider.mapLibre.rawValue

    var body: some View {
        Group {
            let provider = MapProvider(rawValue: providerRaw) ?? .mapLibre
            if provider == .google {
                GoogleRadarMapView(viewModel: MapViewModel.shared)
            } else {
                RadarMapView(viewModel: MapViewModel.shared,
                             styleURL: MapStyleProvider.styleURL(for: provider))
            }
        }
        .ignoresSafeArea()
        .background(.black)
        .onAppear { RadarPresentation.shared.isMapDetached = true }
        .onDisappear { RadarPresentation.shared.isMapDetached = false }
    }
}
