//
//  VectraProApp.swift
//  VectraPro
//
//  Created by Ishant Zibal on 24/06/26.
//

import SwiftData
import SwiftUI

@main
struct VectraProApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
        }
        .modelContainer(ConfigStore.shared.container)

        // Radar in its own window. Opened manually from MapScreen; the user
        // drags it onto the external monitor (Stage Manager), where it stays a
        // normal interactive window — mouse + keyboard work there.
        WindowGroup(id: "radar") {
            RadarWindowScene()
        }
        .defaultSize(CGSize(width: 800, height: 600))
    }
}

struct RadarWindowScene: View {
    @AppStorage(MapProvider.storageKey) private var providerRaw = MapProvider.mapLibre.rawValue

    var body: some View {
        radarMap
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .background(.black)
            // Green border so the detached radar window is easy to tell apart.
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.green, lineWidth: 3)
                    .ignoresSafeArea()
            )
            .onAppear { RadarPresentation.shared.isMapDetached = true }
            .onDisappear { RadarPresentation.shared.isMapDetached = false }
    }

    @ViewBuilder
    private var radarMap: some View {
        let provider = MapProvider(rawValue: providerRaw) ?? .mapLibre
        if provider == .google {
            GoogleRadarMapView(viewModel: MapViewModel.shared)
        } else {
            RadarMapView(viewModel: MapViewModel.shared,
                         styleURL: MapStyleProvider.styleURL(for: provider))
        }
    }
}
