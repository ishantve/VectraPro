//
//  FixRadialRenderer.swift
//  VectraPro
//
//  Draws radials for VOR fixes from the exercise detail. A radial is a line
//  from the fix outward at its bearing for its distance (NM). Only fixes whose
//  `type` is "VOR" and that actually carry radials are drawn.
//

import CoreLocation
import UIKit

enum FixRadialRenderer {

    private static let color = UIColor.green.withAlphaComponent(0.7)
    private static let width: CGFloat = 0.8
    private static let metersPerNM = 1852.0
    // Dash pattern matching the radar's other radials.
    private static let dashMeters = 3000.0
    private static let gapMeters = 2000.0

    static func lines(fixes: [ExerciseDetail.Fix]) -> [MapLine] {
        var result: [MapLine] = []
        for fix in fixes {
            guard fix.type?.uppercased() == "VOR",
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
