//
//  LocalizerRenderer.swift
//  VectraPro
//
//  Builds approach geometry as MapLines:
//   • strip geometry — both-end cones + a circuit (shown when strip enabled)
//   • localizer line  — centerline + range markers (only the enabled threshold)
//

import CoreLocation
import ATCSimKit
import GeoNavKit
import UIKit

enum LocalizerRenderer {

    private static let nauticalMile = 1852.0
    private static let lengthNM = 15.0
    private static let coneApexNM = 8.5
    private static let coneRangeNM = 18.0
    private static let coneHalfAngle = 30.0
    private static let minorBarHalfNM = 0.2
    private static let majorBarHalfNM = 0.4
    private static let circuitOffsetNM = 5.0
    private static let baseRangeNM = 12.0

    private static let color = UIColor.green.withAlphaComponent(0.7)
    private static let lineWidth: CGFloat = 1.5

    // MARK: - Strip geometry (both cones + circuit)

    static func stripGeometry(runway: Runway) -> [MapLine] {
        coneArms(runway: runway, side: .a)
            + coneArms(runway: runway, side: .b)
            + circuit(runway: runway)
    }

    private static func coneArms(runway: Runway, side: RunwayEndSide) -> [MapLine] {
        let threshold = runway.threshold(side).coordinate
        let course = approachCourse(runway: runway, side: side)

        let apex = Geo.offset(from: threshold, distanceMeters: coneApexNM * nauticalMile, bearingDegrees: course)
        let armLength = coneArmLength()
        let armRight = Geo.offset(from: apex, distanceMeters: armLength, bearingDegrees: course + coneHalfAngle)
        let armLeft  = Geo.offset(from: apex, distanceMeters: armLength, bearingDegrees: course - coneHalfAngle)

        return [
            line(apex, armRight),
            line(apex, armLeft),
        ]
    }

    private static func circuit(runway: Runway) -> [MapLine] {
        let a = runway.endA.coordinate
        let b = runway.endB.coordinate
        let axis = Geo.bearing(from: a, to: b)
        let beyondA = (axis + 180).truncatingRemainder(dividingBy: 360)

        let apexA = Geo.offset(from: a, distanceMeters: coneApexNM * nauticalMile, bearingDegrees: beyondA)
        let apexB = Geo.offset(from: b, distanceMeters: coneApexNM * nauticalMile, bearingDegrees: axis)
        let armTo12 = (baseRangeNM - coneApexNM) / cos(coneHalfAngle * .pi / 180) * nauticalMile
        let coneARight = Geo.offset(from: apexA, distanceMeters: armTo12, bearingDegrees: beyondA - 30)
        let coneALeft = Geo.offset(from: apexA, distanceMeters: armTo12, bearingDegrees: beyondA + 30)
        let coneBRight = Geo.offset(from: apexB, distanceMeters: armTo12, bearingDegrees: axis + 30)
        let coneBLeft = Geo.offset(from: apexB, distanceMeters: armTo12, bearingDegrees: axis - 30)

        let markerA = Geo.offset(from: a, distanceMeters: baseRangeNM * nauticalMile, bearingDegrees: beyondA)
        let markerB = Geo.offset(from: b, distanceMeters: baseRangeNM * nauticalMile, bearingDegrees: axis)
        let lateral = circuitOffsetNM * nauticalMile
        let aRight = Geo.offset(from: markerA, distanceMeters: lateral, bearingDegrees: axis + 90)
        let aLeft = Geo.offset(from: markerA, distanceMeters: lateral, bearingDegrees: axis - 90)
        let bRight = Geo.offset(from: markerB, distanceMeters: lateral, bearingDegrees: axis + 90)
        let bLeft = Geo.offset(from: markerB, distanceMeters: lateral, bearingDegrees: axis - 90)

        return [
            line(aRight, bRight),
            line(aLeft, bLeft),
            line(aRight, coneARight),
            line(aLeft, coneALeft),
            line(bRight, coneBRight),
            line(bLeft, coneBLeft),
        ]
    }

    // MARK: - Localizer line

    static func localizerLines(runway: Runway, side: RunwayEndSide) -> [MapLine] {
        let threshold = runway.threshold(side).coordinate
        let course = approachCourse(runway: runway, side: side)
        var lines: [MapLine] = []

        let far = Geo.offset(from: threshold, distanceMeters: lengthNM * nauticalMile, bearingDegrees: course)
        lines.append(line(threshold, far))

        for nm in 1...Int(lengthNM) {
            let center = Geo.offset(from: threshold, distanceMeters: Double(nm) * nauticalMile, bearingDegrees: course)
            let half = (nm % 5 == 0 ? majorBarHalfNM : minorBarHalfNM) * nauticalMile
            let left = Geo.offset(from: center, distanceMeters: half, bearingDegrees: course - 90)
            let right = Geo.offset(from: center, distanceMeters: half, bearingDegrees: course + 90)
            lines.append(line(left, right))
        }

        return lines
    }

    // MARK: - Helpers

    private static func approachCourse(runway: Runway, side: RunwayEndSide) -> Double {
        Geo.bearing(from: runway.otherThreshold(side).coordinate,
                    to: runway.threshold(side).coordinate)
    }

    private static func coneArmLength() -> Double {
        let a = coneApexNM * nauticalMile
        let r = coneRangeNM * nauticalMile
        let projection = a * cos(coneHalfAngle * .pi / 180)
        return -projection + (projection * projection - a * a + r * r).squareRoot()
    }

    private static func line(_ from: CLLocationCoordinate2D,
                             _ to: CLLocationCoordinate2D) -> MapLine {
        MapLine(coordinates: [from, to], color: color, width: lineWidth)
    }
}
