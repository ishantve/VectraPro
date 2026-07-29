//
//  CommandController.swift
//  VectraPro
//
//  Receives raw voice transcripts, parses them with ATCParserKit, and
//  dispatches the resulting AircraftCommands to the correct aircraft.
//
//  Flow:
//    raw transcript
//      → ATCParser().parse()                normalize + callsign + commands
//      → isTakeoffClearance check           early-exit if departure clearance
//      → map ParsedCommand → AircraftCommand
//      → route to aircraft                  via callsign or selected aircraft
//

import Foundation
import ATCParserKit
import ATCSimKit

final class CommandController {

    private weak var mapViewModel: MapViewModel?

    init(mapViewModel: MapViewModel) {
        self.mapViewModel = mapViewModel
    }

    // MARK: - Main entry point

    func process(_ transcript: String) {
        // Parse once (normalize + callsign extraction + command parsing) via the
        // shared ATCParserKit core.
        guard let result = try? ATCParser().parse(transcript) else {
            CommandFeedbackManager.shared.commandError("Command not recognized")
            return
        }
        let normalized = result.normalized

        // 1. Departure clearance: "ACA 29 cleared for takeoff"
        if isTakeoffClearance(normalized) {
            if let callsign = mapViewModel?.resolveDepartureCallsign(from: normalized) {
                mapViewModel?.clearForTakeoff(callsign: callsign)
            } else {
                CommandFeedbackManager.shared.aircraftNotFound()
            }
            return
        }

        // 2. Map the parsed commands into the simulator's command enum.
        //    The parser already stripped the callsign prefix, so flight-number
        //    digits can't collide with command values.
        let commands = result.commands.compactMap(AircraftCommand.init)
        guard !commands.isEmpty else {
            CommandFeedbackManager.shared.commandError("Command not recognized")
            return
        }

        // 3. Route: extracted callsign → full-text callsign search → selected aircraft.
        if let cs = result.callsign,
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
