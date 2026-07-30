//
//  AircraftPhysics.swift
//  VectraPro
//
//  Aircraft physics engine: command application and per-tick movement.
//  Owns turn rate, speed, and altitude step calculations.
//

import Foundation
import GeoNavKit

public final class AircraftPhysics {

    public static let shared = AircraftPhysics()
    private init() {}

    // MARK: - Constants

    private let accelKnotsPerSecond      = 4.0    // engine spool-up (gradual)
    private let decelKnotsPerSecond      = 6.0    // throttle + drag (faster)
    private let climbFeetPerSecond       = 33.0   // 2000 ft/min
    private let descentFeetPerSecond     = 33.0   // 2000 ft/min
    /// Steeper descent while tracking a localizer, so an aircraft cleared to
    /// intercept from above can actually capture the glide and reach the runway
    /// instead of arriving too high and going around.
    private let approachDescentFeetPerSecond = 50.0   // ~3000 ft/min
    private let takeoffAccelKnotsPerSec  = 8.0    // full takeoff thrust
    private let rotationSpeedKnots       = 150.0  // Vr — transition to climbout
    private let climboutAltitudeFt       = 1000.0 // feet AGL — end of climbout phase

    /// Altitude an aircraft climbs to when it goes around. A published missed
    /// approach would come from the procedure; there is no procedure model, so one
    /// figure standing in is honest rather than invented detail.
    public static let missedApproachAltitudeFeet = 3000.0

    // MARK: - Command application

    /// Applies ATC commands to a single aircraft struct.
    public func apply(_ commands: [AircraftCommand], to aircraft: inout Aircraft) {
        for command in commands {
            switch command {
            case .heading(let heading):
                aircraft.turnDirection = nil
                aircraft.targetHeading = heading
            case .headingTurn(let heading, let direction):
                aircraft.turnDirection = direction
                aircraft.targetHeading = heading
            case .relativeTurn(let degrees, let direction):
                let current = aircraft.headingDegrees
                let target = direction == .left ? current - degrees : current + degrees
                aircraft.turnDirection = direction
                aircraft.targetHeading = normalizeHeading(target)
            case .presentHeading:
                aircraft.turnDirection = nil
                aircraft.targetHeading = nil
            case .stopTurn(let heading):
                // Keep turning the way it already is, just stop on this heading.
                aircraft.targetHeading = heading
            case .altitude(let feet):
                aircraft.minAltitudeFeet = nil
                aircraft.maxAltitudeFeet = nil
                aircraft.targetAltitudeFeet = feet
            case .altitudeBlock(let low, let high):
                let lo = min(low, high)
                let hi = max(low, high)
                aircraft.minAltitudeFeet = lo
                aircraft.maxAltitudeFeet = hi
                let alt = aircraft.altitudeFeet
                if alt < lo { aircraft.targetAltitudeFeet = lo }
                else if alt > hi { aircraft.targetAltitudeFeet = hi }
                else { aircraft.targetAltitudeFeet = nil }
            case .speed(let knots):
                aircraft.minSpeedKnots = nil
                aircraft.maxSpeedKnots = nil
                aircraft.targetSpeedKnots = knots
            case .minSpeed(let knots):
                aircraft.maxSpeedKnots = nil
                aircraft.minSpeedKnots = knots
                if aircraft.speedKnots < knots { aircraft.targetSpeedKnots = knots }
            case .maxSpeed(let knots):
                aircraft.minSpeedKnots = nil
                aircraft.maxSpeedKnots = knots
                if aircraft.speedKnots > knots { aircraft.targetSpeedKnots = knots }
            case .stopClimb(let limit):
                // Only ever takes climb away. An aircraft already at or above the
                // level simply stops where it is; it must not be turned into a
                // descent, which is the opposite instruction.
                let current = aircraft.altitudeFeet
                guard let target = aircraft.targetAltitudeFeet, target > current else { break }
                aircraft.targetAltitudeFeet = max(current, min(target, limit))
            case .stopDescent(let limit):
                let current = aircraft.altitudeFeet
                guard let target = aircraft.targetAltitudeFeet, target < current else { break }
                aircraft.targetAltitudeFeet = min(current, max(target, limit))
            case .hold(let fixName):
                // Start navigating direct to the holding fix; the view model
                // steers the heading toward it each tick (auto-turn).
                aircraft.holdingTargetName = fixName
                aircraft.directToFix = nil
                aircraft.turnDirection = nil
            case .proceedDirect(let fixName):
                // Same steering as a hold, but the aircraft is not captured on
                // arrival — it carries on rather than entering a racetrack.
                aircraft.directToFix = fixName
                aircraft.holdingTargetName = nil
                aircraft.turnDirection = nil
            case .squawk(let code):
                aircraft.squawk = code
            case .clearedForTakeoff(let runway):
                // Recorded, not acted on: the aircraft is still in the hangar and
                // putting it on a runway threshold is the scene's job.
                aircraft.pendingTakeoffRunway = runway ?? ""
            case .goAround:
                // Off the approach and climbing. Dropping the localizer is what takes
                // it out of the landing sequence.
                aircraft.interceptRunway = nil
                aircraft.targetHeading = nil
                aircraft.turnDirection = nil
                aircraft.minAltitudeFeet = nil
                aircraft.maxAltitudeFeet = nil
                aircraft.targetAltitudeFeet = Self.missedApproachAltitudeFeet
                aircraft.targetSpeedKnots = Aircraft.defaultSpeedKnots
            case .interceptLocalizer(let runway):
                // Cleared to intercept the localizer for this runway. The view
                // model drives the actual intercept + tracking each tick.
                aircraft.interceptRunway = runway
                aircraft.turnDirection = nil
            }
        }
    }

    /// Converge speed + altitude toward their commanded targets, without moving
    /// or turning. Used for holding aircraft (which are positioned by the
    /// racetrack, not normal physics) so speed/altitude clearances still apply.
    public func adjustSpeedAltitude(_ aircraft: inout Aircraft, dt: Double) {
        adjustSpeed(&aircraft, dt: dt)
        adjustAltitude(&aircraft, dt: dt)
    }

    // MARK: - Physics step

    /// Advances one aircraft through one simulation tick:
    /// turns, accelerates/decelerates, climbs/descends, then moves forward.
    public func stepPhysics(_ aircraft: inout Aircraft, dt: Double) {
        switch aircraft.takeoffState {

        case .groundRoll(let runwayHeading):
            // Lock heading to runway — no turning during roll.
            aircraft.headingDegrees = runwayHeading
            aircraft.targetHeading  = nil

            // Full-thrust acceleration toward rotation speed.
            aircraft.speedKnots = min(
                aircraft.speedKnots + takeoffAccelKnotsPerSec * dt,
                rotationSpeedKnots
            )
            let mps = aircraft.speedKnots * Distance.metersPerNauticalMile / 3600
            aircraft.position = Geo.offset(from: aircraft.position,
                                           distanceMeters: mps * dt,
                                           bearingDegrees: runwayHeading)

            if aircraft.speedKnots >= rotationSpeedKnots {
                aircraft.takeoffState = .climbout
            }
            return  // skip normal physics during ground roll

        case .climbout:
            // Normal physics resumes; clear phase once safely airborne.
            if aircraft.altitudeFeet >= climboutAltitudeFt {
                aircraft.takeoffState = nil
            }

        case nil:
            break
        }

        // Normal flight physics.
        turnTowardTarget(&aircraft, dt: dt)
        adjustSpeed(&aircraft, dt: dt)
        adjustAltitude(&aircraft, dt: dt)

        let metersPerSecond = aircraft.speedKnots * Distance.metersPerNauticalMile / 3600
        aircraft.position = Geo.offset(
            from: aircraft.position,
            distanceMeters: metersPerSecond * dt,
            bearingDegrees: aircraft.headingDegrees
        )
    }

    // MARK: - Private: turn

    /// Standard Rate 1 Turn: bank = atan(TAS / 362.1), capped at 30°.
    /// rate (°/s) = 1091 × tan(bank°) / TAS(kts)
    private func turnTowardTarget(_ aircraft: inout Aircraft, dt: Double) {
        guard let target = aircraft.targetHeading else { return }

        let speed = max(aircraft.speedKnots, 1.0)
        let neededBank = atan(speed / 362.1) * 180.0 / .pi
        let bankDeg = min(neededBank, 30.0)

        let current = aircraft.headingDegrees
        var diff = (target - current).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 } else if diff < -180 { diff += 360 }

        if let direction = aircraft.turnDirection {
            if direction == .right, diff < 0 { diff += 360 }
            if direction == .left,  diff > 0 { diff -= 360 }
        }

        let rate = 1091.0 * tan(bankDeg * .pi / 180.0) / speed
        let step = rate * dt

        if abs(diff) <= step {
            aircraft.headingDegrees = normalizeHeading(target)
            aircraft.targetHeading  = nil
            aircraft.turnDirection  = nil
        } else {
            aircraft.headingDegrees = normalizeHeading(current + (diff >= 0 ? step : -step))
        }
    }

    // MARK: - Private: speed & altitude

    private func adjustSpeed(_ aircraft: inout Aircraft, dt: Double) {
        guard let target = aircraft.targetSpeedKnots else { return }
        let diff = target - aircraft.speedKnots
        let step = (diff > 0 ? accelKnotsPerSecond : decelKnotsPerSecond) * dt
        if abs(diff) <= step {
            aircraft.speedKnots = target; aircraft.targetSpeedKnots = nil
        } else {
            aircraft.speedKnots += diff > 0 ? step : -step
        }
    }

    private func adjustAltitude(_ aircraft: inout Aircraft, dt: Double) {
        guard let target = aircraft.targetAltitudeFeet else { return }
        let diff = target - aircraft.altitudeFeet
        let descentRate = aircraft.interceptRunway != nil ? approachDescentFeetPerSecond
                                                          : descentFeetPerSecond
        let step = (diff > 0 ? climbFeetPerSecond : descentRate) * dt
        if abs(diff) <= step {
            aircraft.altitudeFeet = target; aircraft.targetAltitudeFeet = nil
        } else {
            aircraft.altitudeFeet += diff > 0 ? step : -step
        }
    }

    private func normalizeHeading(_ heading: Double) -> Double {
        let v = heading.truncatingRemainder(dividingBy: 360)
        return v < 0 ? v + 360 : v
    }
}
