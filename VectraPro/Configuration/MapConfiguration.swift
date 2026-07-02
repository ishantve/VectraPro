//
//  MapConfiguration.swift
//  VectraPro
//
//  Static configuration describing what the radar map displays.
//

import CoreLocation
import UIKit

enum MapConfiguration {

    /// Radar origin — 28° 34.0' N, 077° 05.7' E.
    static let center = CLLocationCoordinate2D(
        latitude: 28.566667,
        longitude: 77.095
    )

    /// Initial camera zoom used before any fitting.
    static let defaultZoom: Float = 8.8

    /// Concentric range rings, innermost to outermost.
    static let rings: [RangeRing] = {
        let dashed = RingStyle.dashed(dashMeters: 3000, gapMeters: 2000)
        let neutral = UIColor(white: 0.70, alpha: 0.85)
        let green = UIColor.green.withAlphaComponent(0.7)

        return [
            RangeRing(radiusNM: 10, style: dashed, color: neutral, lineWidth: 0.8),
            RangeRing(radiusNM: 20, style: dashed, color: neutral, lineWidth: 0.8),
            RangeRing(radiusNM: 30, style: .solid, color: green, lineWidth: 1.5),
            RangeRing(radiusNM: 40, style: dashed, color: neutral, lineWidth: 0.8),
            RangeRing(radiusNM: 50, style: .solid, color: green, lineWidth: 1.5),
            RangeRing(radiusNM: 60, style: dashed, color: neutral, lineWidth: 0.8),
        ]
    }()

    /// Area Control Radar rings — wide, very light dashed circles sharing the
    /// same centre as the range rings.
    static let areaControlRings: [RangeRing] = {
        let dashed = RingStyle.dashed(dashMeters: 6000, gapMeters: 4000)
        let faint = UIColor(white: 0.78, alpha: 0.35)
        return [100, 150, 200, 250].map {
            RangeRing(radiusNM: $0, style: dashed, color: faint, lineWidth: 0.9)
        }
    }()
}
