//
//  RunwayRenderer.swift
//  VectraPro
//
//  Draws runway centerlines onto a GMSMapView.
//

import GoogleMaps

enum RunwayRenderer {

    /// Draws a runway centerline and returns the overlays it created so they
    /// can be removed later without disturbing other map content.
    @discardableResult
    static func draw(_ runway: Runway, on mapView: GMSMapView) -> [GMSOverlay] {
        let path = GMSMutablePath()
        path.add(runway.endA.coordinate)
        path.add(runway.endB.coordinate)

        let line = GMSPolyline(path: path)
        line.strokeColor = .white
        line.strokeWidth = 4
        line.map = mapView

        return [line]
    }
}
