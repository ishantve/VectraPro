//
//  Runway.swift
//  ATCSimKit
//
//  Model describing a runway and its two thresholds.
//

import CoreLocation
import Foundation

/// One end of a runway: its designator (e.g. "09") and threshold coordinate.
public struct RunwayThreshold {
    public let designator: String
    public let coordinate: CLLocationCoordinate2D

    public init(designator: String, coordinate: CLLocationCoordinate2D) {
        self.designator = designator
        self.coordinate = coordinate
    }
}

/// A runway defined by its two opposite thresholds.
public struct Runway: Identifiable {
    public let id = UUID()
    public let endA: RunwayThreshold
    public let endB: RunwayThreshold
    public let lengthMeters: Double?

    public init(endA: RunwayThreshold, endB: RunwayThreshold, lengthMeters: Double?) {
        self.endA = endA
        self.endB = endB
        self.lengthMeters = lengthMeters
    }

    /// Combined name, e.g. "09/27".
    public var name: String {
        "\(endA.designator)/\(endB.designator)"
    }
}

extension Runway {
    /// Runway designator ("01"–"36") derived from a compass bearing.
    public static func designator(forBearing bearing: Double) -> String {
        var deg = bearing.truncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }

        var number = Int((deg / 10).rounded())
        if number == 0 { number = 36 }
        if number > 36 { number -= 36 }

        return String(format: "%02d", number)
    }
}
