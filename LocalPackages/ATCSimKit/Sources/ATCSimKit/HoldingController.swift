//
//  HoldingController.swift
//  VectraPro
//
//  Holding-pattern logic, extracted from MapViewModel. Stateless: it operates on
//  the aircraft/traffic arrays passed in and returns the captured ids so the
//  caller can apply the @Published side-effects (clearing selection, arming a
//  spawn refill). MapViewModel keeps ownership of all published state.
//

import CoreLocation
import GeoKit

public enum HoldingController {

    /// Radius (metres) within which an inbound aircraft is captured by a hold.
    public static let captureRadiusM = 1.0 * Distance.metersPerNauticalMile

    /// Continuously steer an aircraft's heading toward its commanded hold fix.
    public static func steer(_ aircraft: inout Aircraft, fixes: [Fix]) {
        guard let name = aircraft.holdingTargetName,
              let fixPos = FixLookup.position(named: name, in: fixes) else { return }
        aircraft.turnDirection = nil
        aircraft.targetHeading = Geo.bearing(from: aircraft.position, to: fixPos)
    }

    /// Move any aircraft that reached its commanded hold fix off the radar and
    /// into the holding hangar (as hangar traffic tagged with the fix name).
    /// Returns the captured aircraft ids (empty if none) — the caller clears the
    /// selection if needed and arms a refill for the freed radar slot.
    public static func capture(aircraft: inout [Aircraft], traffic: inout [Aircraft],
                        fixes: [Fix]) -> Set<UUID> {
        var capturedIDs = Set<UUID>()
        for index in aircraft.indices {
            guard let name = aircraft[index].holdingTargetName,
                  let fix = FixLookup.fix(named: name, in: fixes),
                  let fixPos = FixLookup.coordinate(of: fix) else { continue }
            // Capture as soon as the NOSE reaches the fix collider (not the body).
            let ac0 = aircraft[index]
            let noseReachM = (ac0.noseOffsetNM + ac0.noseForwardNM) * Distance.metersPerNauticalMile
            let nose = Geo.offset(from: ac0.position,
                                  distanceMeters: noseReachM,
                                  bearingDegrees: ac0.headingDegrees)
            guard Geo.distanceMeters(from: nose, to: fixPos) < captureRadiusM
            else { continue }

            var ac = aircraft[index]
            ac.holdingName          = fix.fixName   // canonical name → matches hangar filter
            ac.holdingTargetName    = nil
            ac.holdingInboundCourse = ac.headingDegrees   // course it arrived on = inbound leg
            ac.holdingProgress      = 0                   // start at the fix
            let entryTrack = HoldingRacetrack(fix: fixPos, inboundCourse: ac.headingDegrees,
                                              speedKnots: ac.speedKnots)
            ac.holdingRadiusM       = entryTrack.radiusM
            ac.holdingLegM          = entryTrack.legM
            ac.targetHeading        = nil
            ac.turnDirection        = nil
            ac.history              = []
            traffic.append(ac)
            capturedIDs.insert(ac.id)
        }
        guard !capturedIDs.isEmpty else { return [] }
        aircraft.removeAll { capturedIDs.contains($0.id) }
        return capturedIDs
    }

    /// Fly the holding racetracks for one step. Runs every tick regardless of the
    /// layer's visibility, so an aircraft keeps orbiting while hidden and
    /// reappears at its up-to-date position when the layer is turned back on.
    public static func flyRacetracks(traffic: inout [Aircraft], fixes: [Fix],
                              physics: AircraftPhysics, dt: Double,
                              sampleHistory: Bool, maxHistory: Int) {
        for i in traffic.indices where traffic[i].holdingName != nil {
            guard let ic = traffic[i].holdingInboundCourse else { continue }
            guard let fixPos = FixLookup.position(named: traffic[i].holdingName ?? "", in: fixes) else { continue }
            // Obey speed/altitude clearances (changes ground speed).
            physics.adjustSpeedAltitude(&traffic[i], dt: dt)

            // The aircraft keeps flying its CURRENT (committed) racetrack. A
            // speed change resizes the committed loop only once the aircraft is
            // on the inbound leg — until then it holds the old pattern.
            let turnLen   = Double.pi * traffic[i].holdingRadiusM
            let committedTotal = 2 * traffic[i].holdingLegM + 2 * turnLen
            let inboundStart = committedTotal > 0
                ? (2 * turnLen + traffic[i].holdingLegM) / committedTotal
                : 1
            if traffic[i].holdingProgress >= inboundStart {
                let cur = HoldingRacetrack(fix: fixPos, inboundCourse: ic,
                                           speedKnots: traffic[i].speedKnots)
                traffic[i].holdingRadiusM = cur.radiusM
                traffic[i].holdingLegM    = cur.legM
            }

            let track = HoldingRacetrack(fix: fixPos, inboundCourse: ic,
                                         radiusM: traffic[i].holdingRadiusM,
                                         legM: traffic[i].holdingLegM)
            let vmps  = traffic[i].speedKnots * Distance.metersPerNauticalMile / 3600
            let total = max(1, track.totalLength)
            // Re-anchor onto the (possibly just-updated) loop for continuity.
            let base  = track.nearestProgress(to: traffic[i].position,
                                              near: traffic[i].holdingProgress)
            var prog  = base + (vmps * dt) / total
            prog = prog.truncatingRemainder(dividingBy: 1)
            traffic[i].holdingProgress = prog
            let s = track.sample(at: prog * total)
            traffic[i].position       = s.position
            traffic[i].headingDegrees = s.heading
            if sampleHistory {
                traffic[i].history.append(traffic[i].position)
                if traffic[i].history.count > maxHistory {
                    traffic[i].history.removeFirst()
                }
            }
        }
    }
}
