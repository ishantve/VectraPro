//
//  FixRadialRenderer.swift
//  VectraPro
//
//  Draws radials for VOR / HOLDING fixes from the exercise detail. A radial is
//  a line from the fix outward at its bearing for its distance (NM). Fixes whose
//  `type` is "VOR" or "HOLDING" and that actually carry radials are drawn.
//

import CoreLocation
import GeoKit
import UIKit

enum FixRadialRenderer {

    /// Fix types that draw radials when they carry any.
    private static let radialTypes: Set<String> = ["VOR", "HOLDING"]

    private static let color = UIColor.green.withAlphaComponent(0.7)
    private static let width: CGFloat = 0.8
    private static let metersPerNM = 1852.0
    // Dash pattern matching the radar's other radials.
    private static let dashMeters = 3000.0
    private static let gapMeters = 2000.0

    struct RadialLabel {
        let coordinate: CLLocationCoordinate2D
        let name: String
        let bearing: Double   // degrees clockwise from North
    }

    /// Label positions for all named VOR radials.
    /// Each label is placed at the point on the radial closest to `targetNM`
    /// from the radar `center` — so labels sit between the 40 and 50 NM rings.
    static func labels(fixes: [ExerciseDetail.Fix],
                       center: CLLocationCoordinate2D,
                       targetNM: Double = 45) -> [RadialLabel] {
        let targetMeters = targetNM * metersPerNM
        var result: [RadialLabel] = []

        for fix in fixes {
            guard let type = fix.type?.uppercased(), radialTypes.contains(type),
                  let lat = fix.latitude, let lon = fix.longitude,
                  let radials = fix.radials, !radials.isEmpty else { continue }
            let origin = CLLocationCoordinate2D(latitude: lat, longitude: lon)

            for radial in radials {
                guard let angle = radial.angle, let distanceNM = radial.distance, distanceNM > 0,
                      let name = radial.name, !name.isEmpty else { continue }

                let totalDrawn = distanceNM * 3 * metersPerNM
                // Sample 80 points along the radial; pick the one closest to targetMeters
                // from the radar center.  Falls back to midpoint if none is close enough.
                var bestT      = distanceNM * 1.5 * metersPerNM
                var bestDelta  = Double.infinity
                let steps      = 80
                for i in 0...steps {
                    let t  = totalDrawn * Double(i) / Double(steps)
                    let pt = Geo.offset(from: origin, distanceMeters: t, bearingDegrees: angle)
                    let d  = Geo.distanceMeters(from: center, to: pt)
                    let delta = abs(d - targetMeters)
                    if delta < bestDelta { bestDelta = delta; bestT = t }
                }

                let coord = Geo.offset(from: origin, distanceMeters: bestT, bearingDegrees: angle)
                result.append(RadialLabel(coordinate: coord, name: name, bearing: angle))
            }
        }
        return result
    }

    static func lines(fixes: [ExerciseDetail.Fix]) -> [MapLine] {
        var result: [MapLine] = []
        for fix in fixes {
            guard let type = fix.type?.uppercased(), radialTypes.contains(type),
                  let lat = fix.latitude, let lon = fix.longitude,
                  let radials = fix.radials, !radials.isEmpty else { continue }

            let origin = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            for radial in radials {
                guard let angle = radial.angle, let distanceNM = radial.distance, distanceNM > 0 else { continue }
                // Display the radial at three times its reported distance.
                let total = distanceNM * 3 * metersPerNM

                // Build the radial as dashed segments.
                var distance = 0.0
                while distance < total {
                    let segmentEnd = min(distance + dashMeters, total)
                    let start = Geo.offset(from: origin, distanceMeters: distance, bearingDegrees: angle)
                    let end = Geo.offset(from: origin, distanceMeters: segmentEnd, bearingDegrees: angle)
                    result.append(MapLine(coordinates: [start, end], color: color, width: width))
                    distance += dashMeters + gapMeters
                }
            }
        }
        return result
    }
}
