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

public enum CommandValidator {

    /// Scene inputs the validator needs (passed in, so this stays testable).
    public struct Context {
        public let runways: [Runway]
        public let activeLocalizerRunways: Set<String>
        public let holdingFixes: [Fix]
        /// Every fix an aircraft may be routed direct to — waypoints and VORs as
        /// well as holding fixes. Separate from `holdingFixes` because only the
        /// latter can be held at.
        public let navigationFixes: [Fix]

        public init(runways: [Runway],
                    activeLocalizerRunways: Set<String>,
                    holdingFixes: [Fix],
                    navigationFixes: [Fix] = []) {
            self.runways = runways
            self.activeLocalizerRunways = activeLocalizerRunways
            self.holdingFixes = holdingFixes
            self.navigationFixes = navigationFixes.isEmpty ? holdingFixes : navigationFixes
        }
    }

    public enum Result: Equatable {
        case ok
        case rejected(String)   // phrase for spoken feedback
    }

    // MARK: Operational envelope

    public static let minFlightLevel = 10       // FL010 (1 000 ft)
    public static let maxFlightLevel = 450      // FL450
    /// Same envelope in feet, which is how altitudes are carried.
    public static var minAltitudeFeet: Double { Double(minFlightLevel) * 100 }
    public static var maxAltitudeFeet: Double { Double(maxFlightLevel) * 100 }
    public static let minSpeedKnots  = 100.0
    public static let maxSpeedKnots  = 350.0
    public static let maxRelativeTurnDeg = 180.0
    /// Below the transition altitude, indicated speed is capped (real ATC rule).
    public static let transitionAltitudeFeet = 10_000.0
    public static let speedLimitBelowTransition = 250.0

    /// Validate a whole utterance for one aircraft. Returns `.ok` or the first
    /// failure (so the pilot hears one clear reason).
    public static func validate(_ commands: [AircraftCommand], for aircraft: Aircraft,
                         context: Context) -> Result {

        // V9 — an aircraft still on the takeoff roll isn't under control yet
        // (its heading is locked to the runway); reject the whole utterance.
        if case .groundRoll = aircraft.takeoffState {
            return .rejected("Unable, aircraft is on the takeoff roll")
        }

        // V11 — reject mutually-exclusive instructions issued together.
        if contains(commands, .hold) && contains(commands, .intercept) {
            return .rejected("Unable, cannot hold and intercept at once")
        }
        if contains(commands, .presentHeading) && contains(commands, .turn) {
            return .rejected("Unable, conflicting heading instructions")
        }
        if contains(commands, .altitude) && contains(commands, .block) {
            return .rejected("Unable, conflicting altitude instructions")
        }

        for command in commands {
            switch command {

            // MARK: altitude
            case .altitude(let feet):
                guard (minAltitudeFeet...maxAltitudeFeet).contains(feet) else {
                    return .rejected("Unable, \(spoken(feet)) is out of range")
                }
            case .altitudeBlock(let low, let high):
                let lo = min(low, high), hi = max(low, high)
                guard (minAltitudeFeet...maxAltitudeFeet).contains(lo),
                      (minAltitudeFeet...maxAltitudeFeet).contains(hi) else {
                    return .rejected("Unable, block altitude is out of range")
                }

            // MARK: speed
            case .speed(let kt), .minSpeed(let kt), .maxSpeed(let kt):
                guard (minSpeedKnots...maxSpeedKnots).contains(kt) else {
                    return .rejected("Unable, speed \(Int(kt)) is outside limits")
                }
                // V8 — 250 kt maximum below the transition altitude.
                if kt > speedLimitBelowTransition, aircraft.altitudeFeet < transitionAltitudeFeet {
                    return .rejected("Unable, 250 knots maximum below flight level 100")
                }

            // MARK: vectoring (absolute headings are bounded 1…360 at parse)
            case .relativeTurn(let degrees, _):
                guard degrees > 0, degrees <= maxRelativeTurnDeg else {
                    return .rejected("Unable, cannot turn \(Int(degrees)) degrees")
                }

            // MARK: hold — the fix must exist and be a holding fix
            case .hold(let fix):
                guard aircraft.takeoffState == nil else {
                    return .rejected("Unable, aircraft is still departing")
                }
                guard FixLookup.fix(named: fix, in: context.holdingFixes) != nil else {
                    return .rejected("Unable, holding fix \(fix) not found")
                }

            // MARK: localizer intercept — active, established, and reachable
            case .interceptLocalizer(let runway):
                guard aircraft.takeoffState == nil else {
                    return .rejected("Unable, aircraft is still departing")
                }
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

            // MARK: level off — same envelope as any other altitude
            case .stopClimb(let feet), .stopDescent(let feet):
                guard (minAltitudeFeet...maxAltitudeFeet).contains(feet) else {
                    return .rejected("Unable, \(spoken(feet)) is out of range")
                }

            // MARK: direct routing — the fix has to exist
            case .proceedDirect(let fix):
                guard aircraft.takeoffState == nil else {
                    return .rejected("Unable, aircraft is still departing")
                }
                guard FixLookup.fix(named: fix, in: context.navigationFixes) != nil else {
                    return .rejected("Unable, \(fix) not found")
                }

            case .squawk(let code):
                // Four octal digits — the parser checks this too, but a command can
                // also arrive from the keyboard without passing through it.
                guard code.count == 4, code.allSatisfy({ ("0"..."7").contains($0) }) else {
                    return .rejected("Unable, \(code) is not a valid squawk")
                }

            case .clearedForTakeoff:
                guard aircraft.category == .departure else {
                    return .rejected("Unable, \(aircraft.callsign) is not a departure")
                }
                guard aircraft.takeoffState == nil else {
                    return .rejected("Unable, already cleared for takeoff")
                }

            case .goAround:
                guard aircraft.takeoffState == nil else {
                    return .rejected("Unable, aircraft is departing")
                }

            case .heading, .headingTurn, .presentHeading, .stopTurn:
                break   // absolute heading already bounded at parse; nothing to add
            }
        }
        return .ok
    }

    // MARK: - Command-kind matching (for the mutual-exclusion checks)

    /// Rejections are read out, so an altitude is described the way it would have
    /// been said — above the transition altitude as a flight level, below it in feet.
    private static func spoken(_ feet: Double) -> String {
        feet >= transitionAltitudeFeet
            ? "flight level \(Int(feet / 100))"
            : "\(Int(feet)) feet"
    }

    private enum Kind { case hold, intercept, presentHeading, turn, altitude, block }

    private static func contains(_ commands: [AircraftCommand], _ kind: Kind) -> Bool {
        commands.contains { cmd in
            switch (kind, cmd) {
            case (.hold, .hold),
                 (.intercept, .interceptLocalizer),
                 (.presentHeading, .presentHeading),
                 (.altitude, .altitude),
                 (.altitude, .stopClimb), (.altitude, .stopDescent),
                 (.block, .altitudeBlock):
                return true
            case (.turn, .heading), (.turn, .headingTurn), (.turn, .relativeTurn),
                 (.turn, .stopTurn):
                return true
            default:
                return false
            }
        }
    }
}
