//
//  HoldingRacetrack.swift
//  VectraPro
//
//  Geometry of a standard (right-turn) holding pattern, shared by the flight
//  logic (moves the aircraft along it) and the renderer (draws the oval), so
//  the aircraft is always exactly on the drawn path.
//
//  Layout (1-minute rule):
//    • Inbound leg ends AT the fix, flown on the inbound course.
//    • Turn 1 (semicircle, right) at the fix end → outbound leg.
//    • Outbound leg (1 min) parallel to inbound, offset 2·radius to the right.
//    • Turn 2 (semicircle, right) → back onto the inbound leg.
//  Turn radius + leg length are derived from the holding speed so the pattern
//  matches the aircraft's real turn performance (Rate-1 / 30°-bank cap).
//

import CoreLocation
import Foundation

struct HoldingRacetrack {

    let fix: CLLocationCoordinate2D
    let inboundCourse: Double     // degrees, direction of travel toward the fix
    let radiusM: Double           // turn radius (metres)
    let legM: Double              // straight-leg length (metres, 1-minute rule)

    /// Build the geometry from a holding speed (Rate-1 / 30°-bank turn radius,
    /// 1-minute legs).
    init(fix: CLLocationCoordinate2D, inboundCourse: Double, speedKnots: Double) {
        let speed = max(speedKnots, 1)
        let neededBank    = atan(speed / 362.1) * 180 / .pi
        let bank          = min(neededBank, 30)
        let rateDegPerSec = 1091 * tan(bank * .pi / 180) / speed
        let omega         = rateDegPerSec * .pi / 180          // rad/s
        let vmps          = speed * 1852 / 3600
        self.init(fix: fix, inboundCourse: inboundCourse,
                  radiusM: vmps / omega, legM: vmps * 60)
    }

    /// Build the geometry from explicit, fixed dimensions.
    init(fix: CLLocationCoordinate2D, inboundCourse: Double, radiusM: Double, legM: Double) {
        self.fix = fix
        self.inboundCourse = inboundCourse
        self.radiusM = radiusM
        self.legM = legM
    }

    var totalLength: Double { 2 * legM + 2 * .pi * radiusM }

    // MARK: - Key points

    private func off(_ from: CLLocationCoordinate2D, _ d: Double, _ b: Double) -> CLLocationCoordinate2D {
        Geo.offset(from: from, distanceMeters: d, bearingDegrees: b)
    }
    private var c1:      CLLocationCoordinate2D { off(fix, radiusM, inboundCourse + 90) }  // turn-1 centre
    private var fp:      CLLocationCoordinate2D { off(fix, 2 * radiusM, inboundCourse + 90) } // outbound start
    private var outEnd:  CLLocationCoordinate2D { off(fp, legM, inboundCourse + 180) }      // outbound end
    private var c2:      CLLocationCoordinate2D { off(outEnd, radiusM, inboundCourse - 90) } // turn-2 centre
    private var inStart: CLLocationCoordinate2D { off(fix, legM, inboundCourse + 180) }      // inbound start

    // MARK: - Sampling

    /// Position + heading at distance `s` along the loop.
    /// s = 0 is at the fix, entering turn 1 (flight order: turn1 → outbound → turn2 → inbound).
    func sample(at s0: Double) -> (position: CLLocationCoordinate2D, heading: Double) {
        let total = totalLength
        var s = s0.truncatingRemainder(dividingBy: total)
        if s < 0 { s += total }
        let turnLen = .pi * radiusM

        if s < turnLen {                                   // turn 1 (fix → fp)
            let brg = (inboundCourse - 90) + (s / turnLen) * 180
            return (off(c1, radiusM, brg), normalize(brg + 90))
        }
        s -= turnLen
        if s < legM {                                      // outbound leg
            return (off(fp, s, inboundCourse + 180), normalize(inboundCourse + 180))
        }
        s -= legM
        if s < turnLen {                                   // turn 2 (outEnd → inStart)
            let brg = (inboundCourse + 90) + (s / turnLen) * 180
            return (off(c2, radiusM, brg), normalize(brg + 90))
        }
        s -= turnLen
        return (off(inStart, s, inboundCourse), normalize(inboundCourse))  // inbound leg
    }

    /// Closed outline of the racetrack for drawing.
    func outline(segments: Int = 96) -> [CLLocationCoordinate2D] {
        (0...segments).map { sample(at: totalLength * Double($0) / Double(segments)).position }
    }

    private func normalize(_ h: Double) -> Double {
        let v = h.truncatingRemainder(dividingBy: 360)
        return v < 0 ? v + 360 : v
    }
}
