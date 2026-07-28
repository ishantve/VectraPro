//
//  TrailSampler.swift
//  GeoNavKit
//
//  Pure geometry for placing history-trail dots along a recent path. Returns
//  coordinates only — no rendering dependency.
//

import CoreLocation

public enum TrailSampler {

    /// `count` positions evenly spread along the recent path (last 8 samples).
    /// Ordered oldest → newest.
    public static func equalSpaced(from history: [CLLocationCoordinate2D],
                                   count: Int) -> [CLLocationCoordinate2D] {
        let window = Array(history.suffix(8))
        guard window.count >= 2 else { return Array(window.suffix(count)) }

        var cum = [Double](repeating: 0, count: window.count)
        for i in 1..<window.count {
            cum[i] = cum[i - 1] + Geo.distanceMeters(from: window[i - 1], to: window[i])
        }
        let total = cum.last!
        guard total > 0 else { return [window.last!] }

        var result: [CLLocationCoordinate2D] = []
        for k in 1...count {
            let target = total * Double(k) / Double(count)
            var seg = window.count - 2
            for i in 0..<window.count - 1 {
                if cum[i + 1] >= target { seg = i; break }
            }
            let seg1   = min(seg + 1, window.count - 1)
            let segLen = cum[seg1] - cum[seg]
            let t      = segLen > 0 ? (target - cum[seg]) / segLen : 0.0
            let lat    = window[seg].latitude  + t * (window[seg1].latitude  - window[seg].latitude)
            let lon    = window[seg].longitude + t * (window[seg1].longitude - window[seg].longitude)
            result.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return result
    }

    /// Exactly `count` positions spaced `spacingNM` NM apart, walking backward
    /// from the newest point; short history is projected backward. Oldest → newest.
    public static func fixedSpaced(from history: [CLLocationCoordinate2D],
                                   count: Int, spacingNM: Double) -> [CLLocationCoordinate2D] {
        guard history.count >= 2 else { return [] }
        let spacingMeters = spacingNM * 1852.0

        var result  = [CLLocationCoordinate2D]()
        var walked  = 0.0
        var dotNum  = 1
        var i       = history.count - 1

        while i > 0, result.count < count {
            let segTo   = history[i]
            let segFrom = history[i - 1]
            let segLen  = Geo.distanceMeters(from: segFrom, to: segTo)

            while Double(dotNum) * spacingMeters <= walked + segLen, result.count < count {
                let t   = segLen > 0 ? (Double(dotNum) * spacingMeters - walked) / segLen : 0
                let lat = segTo.latitude  + t * (segFrom.latitude  - segTo.latitude)
                let lon = segTo.longitude + t * (segFrom.longitude - segTo.longitude)
                result.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                dotNum += 1
            }

            walked += segLen
            i -= 1
        }

        if result.count < count {
            let backBearing = Geo.bearing(from: history[1], to: history[0])
            while result.count < count {
                let extra = Double(dotNum) * spacingMeters - walked
                result.append(Geo.offset(from: history[0],
                                         distanceMeters: extra,
                                         bearingDegrees: backBearing))
                dotNum += 1
            }
        }

        return result.reversed()
    }
}
