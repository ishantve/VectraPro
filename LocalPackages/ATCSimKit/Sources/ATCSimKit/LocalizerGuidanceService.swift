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
import GeoKit

public enum LocalizerGuidanceService {

    /// Speed the aircraft is slowed to on final.
    public static let approachSpeedKnots = 160.0

    /// Minimum pure-pursuit lookahead — used once the aircraft is on/near the
    /// centreline. ~2 NM (≈ 2.3 × turn radius at 160 kt) tracks it firmly.
    private static let interceptLeadNM = 2.0
    /// Maximum intercept angle while still off the centreline. The lookahead is
    /// stretched so the aim never demands a turn sharper than this — a gradual
    /// straight intercept instead of a near-perpendicular swing.
    private static let maxInterceptDeg = 30.0
    /// Glide-path descent gradient (≈ 3°).
    private static let glideFeetPerNM = 320.0
    /// Intercept-cone half-angle for position and heading validation.
    public static let coneToleranceDeg = 30.0
    /// Altitude the aircraft can shed per NM of final at the steeper approach
    /// descent (~3000 ft/min, ≈ 50 ft/s, at approach speed). Used to reject an
    /// intercept the aircraft is simply too high to complete. Kept a touch below
    /// the physics limit (≈1125 ft/NM) so anything accepted actually lands.
    public static let maxDescentFtPerNM = 1100.0

    /// Steers a localizer-tracking aircraft for one step.
    public static func guide(_ ac: inout Aircraft, runways: [Runway]) {
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

        // Steer onto the centre-line at a BOUNDED intercept angle. The angle is
        // the pure-pursuit angle for a ~2 NM lookahead, capped at maxInterceptDeg:
        // far off the localizer that gives a gradual ~30° intercept (not a hard
        // near-perpendicular turn), and it eases smoothly to 0 as the cross-track
        // shrinks, so the aircraft rolls out aligned and tracks the centre-line.
        // Signed cross-track; its sign biases the inbound course to whichever
        // side steers the aircraft back toward the centre-line.
        let crossNM = (d * sin(rel * .pi / 180)) / Distance.metersPerNauticalMile
        let rawAngle = atan(abs(crossNM) / interceptLeadNM) * 180 / .pi
        let interceptAngle = min(maxInterceptDeg, rawAngle)
        let signedAngle = crossNM >= 0 ? interceptAngle : -interceptAngle
        ac.turnDirection = nil
        ac.targetHeading = ((info.inbound + signedAngle)
            .truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)

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
    public static func reachedRunway(_ ac: Aircraft, runways: [Runway]) -> Bool {
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
    public static func isInCone(aircraft ac: Aircraft, runway designator: String, runways: [Runway]) -> Bool {
        guard let (threshold, inbound) = RunwayGeometry.threshold(for: designator, in: runways) else { return false }
        let approachDir = (inbound + 180).truncatingRemainder(dividingBy: 360)
        let bearingToAircraft = Geo.bearing(from: threshold, to: ac.position)
        let inFunnel  = headingWithinCone(bearingToAircraft, of: approachDir, tolerance: coneToleranceDeg)
        let inbound30 = headingWithinCone(ac.headingDegrees, of: inbound, tolerance: coneToleranceDeg)
        return inFunnel && inbound30
    }

    /// True if the aircraft can descend to the runway over the remaining final —
    /// i.e. it is NOT being cleared to intercept from too high to make it down.
    /// Rejects when it's past the threshold (no final left) or above the descent
    /// budget for its along-track distance.
    public static func canReachRunway(aircraft ac: Aircraft, runway designator: String, runways: [Runway]) -> Bool {
        guard let info = RunwayGeometry.threshold(for: designator, in: runways) else { return false }
        let approachDir = (info.inbound + 180).truncatingRemainder(dividingBy: 360)
        let d   = Geo.distanceMeters(from: info.threshold, to: ac.position)
        let brg = Geo.bearing(from: info.threshold, to: ac.position)
        var rel = (brg - approachDir).truncatingRemainder(dividingBy: 360)
        if rel > 180 { rel -= 360 } else if rel < -180 { rel += 360 }
        let alongNM = (d * cos(rel * .pi / 180)) / Distance.metersPerNauticalMile
        guard alongNM > 0 else { return false }        // no final remaining
        return ac.altitudeFeet <= alongNM * maxDescentFtPerNM
    }

    /// Shortest-angular-distance check: is `angle` within `tolerance`° of `target`?
    private static func headingWithinCone(_ angle: Double, of target: Double, tolerance: Double) -> Bool {
        var diff = abs((angle - target).truncatingRemainder(dividingBy: 360))
        if diff > 180 { diff = 360 - diff }
        return diff <= tolerance
    }
}
