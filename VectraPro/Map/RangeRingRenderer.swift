//
//  RangeRingRenderer.swift
//  VectraPro
//
//  Renders concentric range rings onto a GMSMapView.
//

import CoreLocation
import GoogleMaps

enum RangeRingRenderer {

    /// Draws all rings around `center` on the given map view.
    static func render(_ rings: [RangeRing],
                       around center: CLLocationCoordinate2D,
                       on mapView: GMSMapView) {
        for ring in rings {
            switch ring.style {
            case .solid:
                drawSolid(ring, around: center, on: mapView)
            case let .dashed(dashMeters, gapMeters):
                drawDashed(ring,
                           dashMeters: dashMeters,
                           gapMeters: gapMeters,
                           around: center,
                           on: mapView)
            }
        }
    }

    // MARK: - Solid

    private static func drawSolid(_ ring: RangeRing,
                                  around center: CLLocationCoordinate2D,
                                  on mapView: GMSMapView) {
        let path = GMSMutablePath()
        for angle in stride(from: 0.0, through: 360.0, by: 2.0) {
            path.add(GMSGeometryOffset(center, ring.radiusMeters, angle))
        }

        let polyline = GMSPolyline(path: path)
        polyline.strokeColor = ring.color
        polyline.strokeWidth = ring.lineWidth
        polyline.map = mapView
    }

    // MARK: - Dashed

    private static func drawDashed(_ ring: RangeRing,
                                   dashMeters: Double,
                                   gapMeters: Double,
                                   around center: CLLocationCoordinate2D,
                                   on mapView: GMSMapView) {
        let radius = ring.radiusMeters
        let circumference = 2 * .pi * radius
        let dashAngle = (dashMeters / circumference) * 360.0
        let gapAngle = (gapMeters / circumference) * 360.0

        var angle = 0.0
        while angle < 360 {
            let path = GMSMutablePath()
            let endAngle = min(angle + dashAngle, 360)

            var current = angle
            while current <= endAngle {
                path.add(GMSGeometryOffset(center, radius, current))
                current += 0.5
            }

            let segment = GMSPolyline(path: path)
            segment.strokeColor = ring.color
            segment.strokeWidth = ring.lineWidth
            segment.map = mapView

            angle += dashAngle + gapAngle
        }
    }
}
