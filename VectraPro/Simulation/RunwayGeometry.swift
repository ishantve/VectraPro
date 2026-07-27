//
//  RunwayGeometry.swift
//  VectraPro
//
//  Pure runway-geometry helpers shared by localizer guidance, landing-sequence
//  separation, and departures. Stateless — the runway set is passed in, so this
//  is trivially testable and has no dependency on MapViewModel.
//

import CoreLocation
import GeoKit

enum RunwayGeometry {

    /// Normalise a designator for matching: digits without leading zeros + a
    /// lowercased side suffix ("08L" ↔ "8l", "09" ↔ "9").
    static func canonical(_ s: String) -> String {
        let lower = s.lowercased()
        let digits = lower.prefix { $0.isNumber }
        let suffix = lower.drop { $0.isNumber }.filter { "lrc".contains($0) }
        let num = Int(digits).map(String.init) ?? String(digits)
        return num + suffix
    }

    /// The threshold coordinate and inbound (landing) course matching a
    /// designator, derived from the actual runway geometry.
    static func threshold(for designator: String, in runways: [Runway])
        -> (threshold: CLLocationCoordinate2D, inbound: Double)? {
        let target = canonical(designator)
        for rwy in runways {
            if canonical(rwy.endA.designator) == target {
                return (rwy.endA.coordinate, Geo.bearing(from: rwy.endA.coordinate, to: rwy.endB.coordinate))
            }
            if canonical(rwy.endB.designator) == target {
                return (rwy.endB.coordinate, Geo.bearing(from: rwy.endB.coordinate, to: rwy.endA.coordinate))
            }
        }
        return nil
    }

    /// Threshold coordinate and takeoff heading for an aircraft's assigned
    /// runway. Falls back to the first available runway, then `center`.
    static func departureThreshold(for ac: Aircraft, in runways: [Runway],
                                   center: CLLocationCoordinate2D)
        -> (CLLocationCoordinate2D, Double) {
        for runway in runways {
            if runway.endA.designator == ac.assignedRunway {
                return (runway.endA.coordinate,
                        Geo.bearing(from: runway.endA.coordinate, to: runway.endB.coordinate))
            }
            if runway.endB.designator == ac.assignedRunway {
                return (runway.endB.coordinate,
                        Geo.bearing(from: runway.endB.coordinate, to: runway.endA.coordinate))
            }
        }
        if let rwy = runways.first {
            return (rwy.endA.coordinate,
                    Geo.bearing(from: rwy.endA.coordinate, to: rwy.endB.coordinate))
        }
        return (center, 0)
    }
}
