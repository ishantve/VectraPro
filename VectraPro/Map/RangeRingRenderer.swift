//
//  RangeRingRenderer.swift
//  VectraPro
//
//  Builds the concentric range rings as MapLines (solid or dashed-as-segments).
//

import CoreLocation

enum RangeRingRenderer {

    static func lines(_ rings: [RangeRing],
                      around center: CLLocationCoordinate2D) -> [MapLine] {
        rings.flatMap { ring -> [MapLine] in
            switch ring.style {
            case .solid:
                return [solid(ring, around: center)]
            case let .dashed(dashMeters, gapMeters):
                return dashed(ring, dashMeters: dashMeters, gapMeters: gapMeters, around: center)
            }
        }
    }

    private static func solid(_ ring: RangeRing,
                              around center: CLLocationCoordinate2D) -> MapLine {
        var coords: [CLLocationCoordinate2D] = []
        for angle in stride(from: 0.0, through: 360.0, by: 2.0) {
            coords.append(Geo.offset(from: center, distanceMeters: ring.radiusMeters, bearingDegrees: angle))
        }
        return MapLine(coordinates: coords, color: ring.color, width: ring.lineWidth)
    }

    private static func dashed(_ ring: RangeRing,
                               dashMeters: Double,
                               gapMeters: Double,
                               around center: CLLocationCoordinate2D) -> [MapLine] {
        let radius = ring.radiusMeters
        let circumference = 2 * .pi * radius
        let dashAngle = (dashMeters / circumference) * 360.0
        let gapAngle = (gapMeters / circumference) * 360.0

        var lines: [MapLine] = []
        var angle = 0.0
        while angle < 360 {
            let endAngle = min(angle + dashAngle, 360)
            var coords: [CLLocationCoordinate2D] = []
            var current = angle
            while current <= endAngle {
                coords.append(Geo.offset(from: center, distanceMeters: radius, bearingDegrees: current))
                current += 0.5
            }
            lines.append(MapLine(coordinates: coords, color: ring.color, width: ring.lineWidth))
            angle += dashAngle + gapAngle
        }
        return lines
    }
}
