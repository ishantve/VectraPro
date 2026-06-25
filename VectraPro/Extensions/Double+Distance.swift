//
//  Double+Distance.swift
//  VectraPro
//
//  Distance helpers for converting nautical miles to meters.
//

import Foundation

enum Distance {
    /// Meters in one nautical mile.
    static let metersPerNauticalMile: Double = 1852
}

extension Double {
    /// Interprets the value as nautical miles and returns the equivalent in meters.
    var nauticalMilesToMeters: Double {
        self * Distance.metersPerNauticalMile
    }
}
