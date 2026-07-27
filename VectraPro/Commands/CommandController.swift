//
//  CommandController.swift
//  VectraPro
//
//  Receives raw voice transcripts, runs them through CommandParser,
//  and dispatches the resulting AircraftCommands to the correct aircraft.
//
//  Flow:
//    raw transcript
//      → CommandParser.normalize()          strip punctuation, expand digit words
//      → isTakeoffClearance check           early-exit if departure clearance
//      → CommandParser.extractCallsign()    identify & strip callsign prefix
//      → CommandParser.parse(commandText)   parse the instruction only
//      → route to aircraft                  via callsign or selected aircraft
//

import Foundation
import ATCSimKit

final class CommandController {

    private weak var mapViewModel: MapViewModel?

    init(mapViewModel: MapViewModel) {
        self.mapViewModel = mapViewModel
    }

    // MARK: - Main entry point

    func process(_ transcript: String) {
        let normalized = CommandParser.normalize(transcript)

        // 1. Departure clearance: "ACA 29 cleared for takeoff"
        if isTakeoffClearance(normalized) {
            if let callsign = mapViewModel?.resolveDepartureCallsign(from: normalized) {
                mapViewModel?.clearForTakeoff(callsign: callsign)
            } else {
                CommandFeedbackManager.shared.aircraftNotFound()
            }
            return
        }

        // 2. Extract callsign prefix (if present) and isolate the command text.
        //    "air canada 125 heading 270" → callsign="air canada 125", cmd="heading 270"
        //    "heading 270"               → no callsign found, cmd="heading 270"
        let extracted   = CommandParser.extractCallsign(from: normalized)
        let commandText = extracted?.commandText ?? normalized
        let callsignText = extracted?.callsign    // raw spoken callsign for routing

        // 3. Parse commands from the instruction portion only.
        //    Flight-number digits are gone, so they can't collide with command values.
        let commands = CommandParser.parse(commandText)
        guard !commands.isEmpty else {
            CommandFeedbackManager.shared.commandError("Command not recognized")
            return
        }

        // 4. Route: extracted callsign → full-text callsign search → selected aircraft.
        if let cs = callsignText,
           let callsign = mapViewModel?.resolveRadarCallsign(from: cs) {
            mapViewModel?.applyToCallsign(callsign, commands: commands)
        } else if let callsign = mapViewModel?.resolveRadarCallsign(from: normalized) {
            mapViewModel?.applyToCallsign(callsign, commands: commands)
        } else {
            mapViewModel?.apply(commands)
        }
    }

    // MARK: - Takeoff clearance detection

    private func isTakeoffClearance(_ normalized: String) -> Bool {
        normalized.contains("clear") &&
        (normalized.contains("takeoff") || normalized.contains("take off"))
    }
}
