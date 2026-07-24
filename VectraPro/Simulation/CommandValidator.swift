//
//  CommandValidator.swift
//  VectraPro
//
//  Single validation layer for controller commands. Every command an aircraft
//  is about to receive is checked here first; an invalid one is rejected with a
//  spoken-feedback phrase and NOTHING is applied (all-or-nothing per utterance).
//  Stateless — the scene inputs it needs are passed in via Context.
//

import Foundation

enum CommandValidator {

    /// Scene inputs the validator needs (passed in, so this stays testable).
    struct Context {
        let runways: [Runway]
        let activeLocalizerRunways: Set<String>
        let holdingFixes: [ExerciseDetail.Fix]
    }

    enum Result: Equatable {
        case ok
        case rejected(String)   // phrase for spoken feedback
    }

    // MARK: Operational envelope

    static let minFlightLevel = 10       // FL010 (1 000 ft)
    static let maxFlightLevel = 450      // FL450
    static let minSpeedKnots  = 100.0
    static let maxSpeedKnots  = 350.0
    static let maxRelativeTurnDeg = 180.0

    /// Validate a whole utterance for one aircraft. Returns `.ok` or the first
    /// failure (so the pilot hears one clear reason).
    static func validate(_ commands: [AircraftCommand], for aircraft: Aircraft,
                         context: Context) -> Result {
        for command in commands {
            switch command {

            // MARK: altitude
            case .flightLevel(let fl):
                guard (minFlightLevel...maxFlightLevel).contains(fl) else {
                    return .rejected("Unable, flight level \(fl) is out of range")
                }
            case .altitudeBlock(let low, let high):
                let lo = min(low, high), hi = max(low, high)
                guard (minFlightLevel...maxFlightLevel).contains(lo),
                      (minFlightLevel...maxFlightLevel).contains(hi) else {
                    return .rejected("Unable, block altitude is out of range")
                }

            // MARK: speed
            case .speed(let kt), .minSpeed(let kt), .maxSpeed(let kt):
                guard (minSpeedKnots...maxSpeedKnots).contains(kt) else {
                    return .rejected("Unable, speed \(Int(kt)) is outside limits")
                }

            // MARK: vectoring (absolute headings are bounded 1…360 at parse)
            case .relativeTurn(let degrees, _):
                guard degrees > 0, degrees <= maxRelativeTurnDeg else {
                    return .rejected("Unable, cannot turn \(Int(degrees)) degrees")
                }

            // MARK: hold — the fix must exist and be a holding fix
            case .hold(let fix):
                guard FixLookup.fix(named: fix, in: context.holdingFixes) != nil else {
                    return .rejected("Unable, holding fix \(fix) not found")
                }

            // MARK: localizer intercept — active, established, and reachable
            case .interceptLocalizer(let runway):
                guard context.activeLocalizerRunways.contains(RunwayGeometry.canonical(runway)) else {
                    return .rejected("Localizer runway \(runway) not active")
                }
                guard LocalizerGuidanceService.isInCone(aircraft: aircraft, runway: runway,
                                                        runways: context.runways) else {
                    return .rejected("Unable, not established for localizer runway \(runway)")
                }
                guard LocalizerGuidanceService.canReachRunway(aircraft: aircraft, runway: runway,
                                                              runways: context.runways) else {
                    return .rejected("Unable, too high to intercept runway \(runway) — descend first")
                }

            case .heading, .headingTurn, .presentHeading:
                break   // absolute heading already bounded at parse; nothing to add
            }
        }
        return .ok
    }
}
