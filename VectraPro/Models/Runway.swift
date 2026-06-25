//
//  Runway.swift
//  VectraPro
//
//  Model describing a runway and its two thresholds.
//

import CoreLocation
import Foundation

/// One end of a runway: its designator (e.g. "09") and threshold coordinate.
struct RunwayThreshold {
    let designator: String
    let coordinate: CLLocationCoordinate2D
}

/// A runway defined by its two opposite thresholds.
struct Runway: Identifiable {
    let id = UUID()
    let endA: RunwayThreshold
    let endB: RunwayThreshold
    let lengthMeters: Double?

    /// Combined name, e.g. "09/27".
    var name: String {
        "\(endA.designator)/\(endB.designator)"
    }
}

extension Runway {
    /// Runway designator ("01"–"36") derived from a compass bearing.
    static func designator(forBearing bearing: Double) -> String {
        var deg = bearing.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }

        var number = Int((deg / 10).rounded())
        if number == 0 { number = 36 }
        if number > 36 { number -= 36 }

        return String(format: "%02d", number)
    }
}
