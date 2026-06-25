//
//  Aircraft.swift
//  VectraPro
//
//  A radar aircraft target.
//

import CoreLocation
import Foundation

struct Aircraft: Identifiable {
    let id = UUID()
    var callsign: String
    var position: CLLocationCoordinate2D
    var headingDegrees: Double
    var speedKnots: Double = Aircraft.defaultSpeedKnots
    var altitudeFeet: Double = Aircraft.defaultAltitudeFeet

    /// Recent past positions (oldest first) used to draw the history trail.
    var history: [CLLocationCoordinate2D] = []

    /// Data-block placement relative to the aircraft (polar offset). The user
    /// can drag the block; this offset keeps it attached as the aircraft moves.
    var labelBearingDegrees: Double = 45
    var labelDistanceMeters: Double = 1.5 * 1852   // 1.5 NM up-right by default

    static let defaultSpeedKnots = 250.0
    static let defaultAltitudeFeet = 18_000.0   // FL180

    /// Flight level (altitude in hundreds of feet), e.g. 180.
    var flightLevel: Int {
        Int(altitudeFeet / 100)
    }

    /// Radar data block, e.g. "ACA98 / FL180 250".
    var dataBlock: String {
        "\(callsign)\nFL\(flightLevel) \(Int(speedKnots))"
    }
}
