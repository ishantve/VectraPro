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
    }
}

struct RadarWindowScene: View {
    @AppStorage(MapProvider.storageKey) private var providerRaw = MapProvider.mapLibre.rawValue

    /// Largest square edge we'll render the radar at.
    private let maxSquare: CGFloat = 1920

    var body: some View {
        GeometryReader { geo in
            // Detect the available resolution (the window fills the external
            // display once dragged over) and fit the biggest square that fits,
            // capped at 1920×1920. The rest stays black.
            let side = min(min(geo.size.width, geo.size.height), maxSquare)
            ZStack {
                Color.black
                radarMap
                    .frame(width: side, height: side)
                    .clipped()
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .background(.black)
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
