//
//  AircraftPhysics.swift
//  VectraPro
//
//  Aircraft physics engine: command application and per-tick movement.
//  Owns turn rate, speed, and altitude step calculations.
//

import Foundation

final class AircraftPhysics {

    static let shared = AircraftPhysics()
    private init() {}

    // MARK: - Constants

    private let accelKnotsPerSecond  = 4.0    // engine spool-up (gradual)
    private let decelKnotsPerSecond  = 6.0    // throttle + drag (faster)
    private let climbFeetPerSecond   = 33.0   // 2000 ft/min
    private let descentFeetPerSecond = 33.0   // 2000 ft/min

    // MARK: - Command application

    /// Applies ATC commands to a single aircraft struct.
    func apply(_ commands: [AircraftCommand], to aircraft: inout Aircraft) {
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
            case .flightLevel(let flightLevel):
                aircraft.minAltitudeFeet = nil
                aircraft.maxAltitudeFeet = nil
                aircraft.targetAltitudeFeet = Double(flightLevel) * 100
            case .altitudeBlock(let low, let high):
                let lo = Double(min(low, high)) * 100
                let hi = Double(max(low, high)) * 100
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
            }
        }
    }

    // MARK: - Physics step

    /// Advances one aircraft through one simulation tick:
    /// turns, accelerates/decelerates, climbs/descends, then moves forward.
    func stepPhysics(_ aircraft: inout Aircraft, dt: Double) {
        turnTowardTarget(&aircraft, dt: dt)
        adjustSpeed(&aircraft, dt: dt)
        adjustAltitude(&aircraft, dt: dt)

        // distance = TAS (m/s) × dt;  1 kt = 1852 m/hr
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
        let step = (diff > 0 ? climbFeetPerSecond : descentFeetPerSecond) * dt
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
