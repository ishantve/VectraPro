//
//  RangeRing.swift
//  VectraPro
//
//  Model describing a single concentric range ring.
//

import UIKit
import GeoNavKit

/// How a range ring is stroked on the map.
enum RingStyle {
    case solid
    case dashed(dashMeters: Double, gapMeters: Double)
}

/// A single concentric range ring, measured in nautical miles.
struct RangeRing: Identifiable {
    let id = UUID()
    let radiusNM: Double
    let style: RingStyle
    let color: UIColor
    let lineWidth: CGFloat

    /// Radius converted to meters for the Maps SDK.
    var radiusMeters: Double {
        radiusNM.nauticalMilesToMeters
    }
}
