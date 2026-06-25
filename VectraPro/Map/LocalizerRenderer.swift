//
//  LocalizerRenderer.swift
//  VectraPro
//
//  Draws ILS-style approach geometry:
//   • strip geometry — both-end cones + a circuit rectangle (shown whenever
//     the strip is enabled, i.e. either threshold is on)
//   • localizer line  — centerline + range markers (only the enabled threshold)
//

import CoreLocation
import GoogleMaps
import UIKit

enum LocalizerRenderer {

    // MARK: - Geometry constants

    private static let nauticalMile = 1852.0

    private static let lengthNM = 15.0          // localizer length
    private static let coneApexNM = 8.5         // cone starts here
    private static let coneRangeNM = 18.0       // cone arms reach this range
    private static let coneHalfAngle = 30.0     // each arm, degrees off course

    private static let minorBarHalfNM = 0.2     // 1 NM tick half-length
    private static let majorBarHalfNM = 0.4     // 5 NM tick half-length

    private static let circuitOffsetNM = 5.0    // downwind legs, lateral offset
    private static let baseRangeNM = 12.0       // perpendicular connector at the 12 NM marker

    private static let coneColor = UIColor.green.withAlphaComponent(0.7)
    private static let circuitColor = UIColor.green.withAlphaComponent(0.7)
    private static let localizerColor = UIColor.green.withAlphaComponent(0.7)
    private static let lineWidth: CGFloat = 1.5

    // MARK: - Strip geometry (both cones + circuit) — shown when strip enabled

    static func drawStripGeometry(runway: Runway, on mapView: GMSMapView) -> [GMSOverlay] {
        var overlays: [GMSOverlay] = []
        overlays += coneArms(runway: runway, side: .a, on: mapView)
        overlays += coneArms(runway: runway, side: .b, on: mapView)
        overlays += circuit(runway: runway, on: mapView)
        return overlays
    }

    /// Cone arms for one threshold — emanate from the 8.5 NM apex at ±30°,
    /// tips at 18 NM range.
    private static func coneArms(runway: Runway,
                                 side: RunwayEndSide,
                                 on mapView: GMSMapView) -> [GMSOverlay] {
        let threshold = runway.threshold(side).coordinate
        let course = approachCourse(runway: runway, side: side)

        let apex = Geo.offset(from: threshold, distanceMeters: coneApexNM * nauticalMile, bearingDegrees: course)
        let armLength = coneArmLength()
        let armRight = Geo.offset(from: apex, distanceMeters: armLength, bearingDegrees: course + coneHalfAngle)
        let armLeft = Geo.offset(from: apex, distanceMeters: armLength, bearingDegrees: course - coneHalfAngle)

        return [
            line(apex, armRight, color: coneColor, on: mapView),
            line(apex, armLeft, color: coneColor, on: mapView),
        ]
    }

    /// Circuit: two downwind legs (±5 NM, parallel to the strip), each joined
    /// to the cone by a perpendicular connector at the threshold's 12 NM
    /// marker. Not closed — there is no line across the centerline.
    private static func circuit(runway: Runway, on mapView: GMSMapView) -> [GMSOverlay] {
        let a = runway.endA.coordinate
        let b = runway.endB.coordinate

        let axis = Geo.bearing(from: a, to: b)                            // A -> B
        let beyondA = (axis + 180).truncatingRemainder(dividingBy: 360)  // A's outward course

        // Point on a cone arm at the 12 NM along-position (where the
        // perpendicular connector meets the cone).
        let apexA = Geo.offset(from: a, distanceMeters: coneApexNM * nauticalMile, bearingDegrees: beyondA)
        let apexB = Geo.offset(from: b, distanceMeters: coneApexNM * nauticalMile, bearingDegrees: axis)
        let armTo12 = (baseRangeNM - coneApexNM) / cos(coneHalfAngle * .pi / 180) * nauticalMile
        let coneARight = Geo.offset(from: apexA, distanceMeters: armTo12, bearingDegrees: beyondA - 30)
        let coneALeft = Geo.offset(from: apexA, distanceMeters: armTo12, bearingDegrees: beyondA + 30)
        let coneBRight = Geo.offset(from: apexB, distanceMeters: armTo12, bearingDegrees: axis + 30)
        let coneBLeft = Geo.offset(from: apexB, distanceMeters: armTo12, bearingDegrees: axis - 30)

        // Downwind endpoints: ±5 NM lateral at each threshold's 12 NM marker.
        let markerA = Geo.offset(from: a, distanceMeters: baseRangeNM * nauticalMile, bearingDegrees: beyondA)
        let markerB = Geo.offset(from: b, distanceMeters: baseRangeNM * nauticalMile, bearingDegrees: axis)
        let lateral = circuitOffsetNM * nauticalMile
        let aRight = Geo.offset(from: markerA, distanceMeters: lateral, bearingDegrees: axis + 90)
        let aLeft = Geo.offset(from: markerA, distanceMeters: lateral, bearingDegrees: axis - 90)
        let bRight = Geo.offset(from: markerB, distanceMeters: lateral, bearingDegrees: axis + 90)
        let bLeft = Geo.offset(from: markerB, distanceMeters: lateral, bearingDegrees: axis - 90)

        return [
            line(aRight, bRight, color: circuitColor, on: mapView),     // right downwind leg
            line(aLeft, bLeft, color: circuitColor, on: mapView),       // left downwind leg
            line(aRight, coneARight, color: circuitColor, on: mapView), // perpendicular → cone @12NM (A)
            line(aLeft, coneALeft, color: circuitColor, on: mapView),
            line(bRight, coneBRight, color: circuitColor, on: mapView), // perpendicular → cone @12NM (B)
            line(bLeft, coneBLeft, color: circuitColor, on: mapView),
        ]
    }

    // MARK: - Localizer line (only the enabled threshold)

    static func drawLocalizer(runway: Runway,
                              side: RunwayEndSide,
                              on mapView: GMSMapView) -> [GMSOverlay] {
        let threshold = runway.threshold(side).coordinate
        let course = approachCourse(runway: runway, side: side)
        var overlays: [GMSOverlay] = []

        // Centerline
        let far = Geo.offset(from: threshold, distanceMeters: lengthNM * nauticalMile, bearingDegrees: course)
        overlays.append(line(threshold, far, color: localizerColor, on: mapView))

        // Range markers every 1 NM as perpendicular bars (every 5th is longer)
        for nm in 1...Int(lengthNM) {
            let center = Geo.offset(from: threshold, distanceMeters: Double(nm) * nauticalMile, bearingDegrees: course)
            let half = (nm % 5 == 0 ? majorBarHalfNM : minorBarHalfNM) * nauticalMile
            let left = Geo.offset(from: center, distanceMeters: half, bearingDegrees: course - 90)
            let right = Geo.offset(from: center, distanceMeters: half, bearingDegrees: course + 90)
            overlays.append(line(left, right, color: localizerColor, on: mapView))
        }

        return overlays
    }

    // MARK: - Helpers

    /// Outward approach course — reciprocal of the landing heading, extended
    /// beyond the threshold.
    private static func approachCourse(runway: Runway, side: RunwayEndSide) -> Double {
        Geo.bearing(from: runway.otherThreshold(side).coordinate,
                    to: runway.threshold(side).coordinate)
    }

    /// Length of each cone arm so that, starting at the apex and heading off at
    /// ±coneHalfAngle, its tip lands exactly coneRangeNM from the threshold.
    private static func coneArmLength() -> Double {
        let a = coneApexNM * nauticalMile
        let r = coneRangeNM * nauticalMile
        let projection = a * cos(coneHalfAngle * .pi / 180)
        return -projection + (projection * projection - a * a + r * r).squareRoot()
    }

    private static func line(_ from: CLLocationCoordinate2D,
                             _ to: CLLocationCoordinate2D,
                             color: UIColor,
                             on mapView: GMSMapView) -> GMSPolyline {
        let path = GMSMutablePath()
        path.add(from)
        path.add(to)

        let polyline = GMSPolyline(path: path)
        polyline.strokeColor = color
        polyline.strokeWidth = lineWidth
        polyline.map = mapView
        return polyline
    }
}
