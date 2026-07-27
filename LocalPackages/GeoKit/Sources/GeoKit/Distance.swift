//
//  Distance.swift
//  GeoKit
//
//  Nautical-mile ↔ meter conversion.
//

import Foundation

public enum Distance {
    /// Meters in one nautical mile.
    public static let metersPerNauticalMile: Double = 1852
}

public extension Double {
    /// Interprets the value as nautical miles and returns the equivalent in meters.
    var nauticalMilesToMeters: Double {
        self * Distance.metersPerNauticalMile
    }
}
