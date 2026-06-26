//
//  RadarMapView.swift
//  VectraPro
//
//  SwiftUI wrapper for the radar map. Each instance (iPad screen / external
//  display) creates its OWN map view but binds to the shared MapViewModel, so
//  both show the same live radar. (A Metal-backed map view can't be reparented
//  across separate scenes, so we use one per scene rather than sharing it.)
//

import MapLibre
import SwiftUI

struct RadarMapView: UIViewRepresentable {
    let viewModel: MapViewModel
    let styleURL: URL

    func makeCoordinator() -> RadarMapController {
        RadarMapController(viewModel: viewModel, styleURL: styleURL)
    }

    func makeUIView(context: Context) -> MLNMapView {
        context.coordinator.mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        context.coordinator.sync()
    }
}
