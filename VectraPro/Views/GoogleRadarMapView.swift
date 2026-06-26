//
//  GoogleRadarMapView.swift
//  VectraPro
//
//  SwiftUI wrapper for the Google Maps radar renderer. Each instance owns its
//  own map view bound to the shared MapViewModel.
//

import GoogleMaps
import SwiftUI

struct GoogleRadarMapView: UIViewRepresentable {
    let viewModel: MapViewModel

    func makeCoordinator() -> GoogleRadarMapController {
        GoogleRadarMapController(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> GMSMapView {
        context.coordinator.mapView
    }

    func updateUIView(_ uiView: GMSMapView, context: Context) {
        context.coordinator.sync()
    }
}
