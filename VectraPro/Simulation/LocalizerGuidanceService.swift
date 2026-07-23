//
//  LocalizerGuidanceService.swift
//  VectraPro
//
//  Localizer-intercept guidance, extracted from MapViewModel. Stateless: it
//  mutates the passed aircraft and reads the runway set — no simulation state.
//
//  Given an aircraft cleared to intercept a runway's localizer, it aims at a
//  point on the extended centreline ahead of the aircraft (pure-pursuit) so the
//  aircraft turns to intercept, tracks the centreline in, descends on a ~3°
//  glide path, and slows to approach speed.
//

import CoreLocation

enum LocalizerGuidanceService {

    /// Speed the aircraft is slowed to on final.
    static let approachSpeedKnots = 160.0

    /// Pure-pursuit lookahead. ~2 NM (≈ 2.3 × turn radius at 160 kt) captures
    /// firmly onto the centreline without weaving, established before the runway.
    private static let interceptLeadNM = 2.0
    /// Glide-path descent gradient (≈ 3°).
    private static let glideFeetPerNM = 320.0
    /// Intercept-cone half-angle for position and heading validation.
    static let coneToleranceDeg = 30.0

    /// Steers a localizer-tracking aircraft for one step.
    static func guide(_ ac: inout Aircraft, runways: [Runway]) {
        guard let rwy = ac.interceptRunway,
              let info = RunwayGeometry.threshold(for: rwy, in: runways) else { return }
        let approachDir = (info.inbound + 180).truncatingRemainder(dividingBy: 360)  // threshold → outward
        let d   = Geo.distanceMeters(from: info.threshold, to: ac.position)
        let brg = Geo.bearing(from: info.threshold, to: ac.position)

        // Signed along-track distance out on final (foot of perpendicular on the
        // centre-line). Positive = still out on final; negative = past the threshold.
        var rel = (brg - approachDir).truncatingRemainder(dividingBy: 360)
        if rel > 180 { rel -= 360 } else if rel < -180 { rel += 360 }
        let alongM  = d * cos(rel * .pi / 180)
        let alongNM = alongM / Distance.metersPerNauticalMile

        // Overshoot / missed approach: the aircraft has crossed the threshold but
        // is still airborne (too high to land — it could not lose altitude in time,
        // or the glide never captured). Don't spin it back toward the runway; end
        // the approach and let it fly straight ahead on the inbound course so the
        // controller can re-vector. (An actual touchdown is handled by reachedRunway
        // before we ever get here.)
        if alongM < -0.2 * Distance.metersPerNauticalMile {
            ac.interceptRunway = nil
            ac.turnDirection = nil
            ac.targetHeading = info.inbound
            ac.minAltitudeFeet = nil; ac.maxAltitudeFeet = nil; ac.targetAltitudeFeet = nil
            ac.minSpeedKnots = nil; ac.maxSpeedKnots = nil; ac.targetSpeedKnots = nil
            return
        }

        // Pure-pursuit: aim a lead ahead of the foot, toward the threshold, ON the
        // centre-line, so the aircraft turns to intercept then TRACKS the localizer
        // (not parallel).
        let leadM = interceptLeadNM * Distance.metersPerNauticalMile
        let aimAlong = max(0, alongM - leadM)
        let aim = Geo.offset(from: info.threshold, distanceMeters: aimAlong, bearingDegrees: approachDir)
        ac.turnDirection = nil
        ac.targetHeading = Geo.bearing(from: ac.position, to: aim)

        // Descend on the glide path. Only ever descend.
        ac.minAltitudeFeet = nil
        ac.maxAltitudeFeet = nil
        ac.targetAltitudeFeet = min(ac.altitudeFeet, max(0, alongNM) * glideFeetPerNM)

        // Slow to approach speed on final.
        ac.minSpeedKnots = nil
        ac.maxSpeedKnots = nil
        ac.targetSpeedKnots = approachSpeedKnots
    }

    /// True when a localizer-tracking aircraft has actually touched down: at the
    /// threshold horizontally AND descended to (near) ground level.
    static func reachedRunway(_ ac: Aircraft, runways: [Runway]) -> Bool {
        guard let rwy = ac.interceptRunway,
              let info = RunwayGeometry.threshold(for: rwy, in: runways) else { return false }
        let atThreshold = Geo.distanceMeters(from: ac.position, to: info.threshold) < 0.4 * Distance.metersPerNauticalMile
        let onGround = ac.altitudeFeet <= 200
        return atThreshold && onGround
    }

    /// True if the aircraft can intercept the runway's localizer. Two conditions:
    ///   1. POSITION — the aircraft sits inside the approach funnel: its bearing
    ///      from the threshold is within ±30° of the approach direction (the
    ///      reciprocal of the landing course = the extended centreline).
    ///   2. HEADING — the aircraft is flying TOWARD the localizer: its heading is
    ///      within ±30° of the inbound landing course (a valid intercept angle).
    /// Both must hold — in the cone but pointing the wrong way can't intercept.
    static func isInCone(aircraft ac: Aircraft, runway designator: String, runways: [Runway]) -> Bool {
        guard let (threshold, inbound) = RunwayGeometry.threshold(for: designator, in: runways) else { return false }
        let approachDir = (inbound + 180).truncatingRemainder(dividingBy: 360)
        let bearingToAircraft = Geo.bearing(from: threshold, to: ac.position)
        let inFunnel  = headingWithinCone(bearingToAircraft, of: approachDir, tolerance: coneToleranceDeg)
        let inbound30 = headingWithinCone(ac.headingDegrees, of: inbound, tolerance: coneToleranceDeg)
        return inFunnel && inbound30
    }

    /// Shortest-angular-distance check: is `angle` within `tolerance`° of `target`?
    private static func headingWithinCone(_ angle: Double, of target: Double, tolerance: Double) -> Bool {
        var diff = abs((angle - target).truncatingRemainder(dividingBy: 360))
        if diff > 180 { diff = 360 - diff }
        return diff <= tolerance
    }
}
