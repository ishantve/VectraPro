//
//  RadarMapView.swift
//  VectraPro
//
//  Thin SwiftUI wrapper that mounts the shared map view owned by
//  RadarMapController. The same map view can be hosted here (iPad) or on an
//  external display — only one at a time — so it reparents without reloading.
//

import MapLibre
import SwiftUI

struct RadarMapView: UIViewRepresentable {
    let controller: RadarMapController

    func makeUIView(context: Context) -> MLNMapView {
        controller.mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {
        controller.sync()
    }
}
