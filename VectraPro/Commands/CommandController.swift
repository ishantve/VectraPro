//
//  CommandController.swift
//  VectraPro
//
//  Central place where transcribed voice commands are parsed and dispatched
//  to the aircraft. Start simple: heading, flight level, speed.
//
//  Examples it understands (digits may be spoken, e.g. "two seven zero"):
//    "turn left heading 270"      → heading(270)
//    "fly heading two seven zero" → heading(270)
//    "descend flight level 100"   → flightLevel(100)
//    "climb FL250"                → flightLevel(250)
//    "speed 250" / "reduce speed two five zero" → speed(250)
//

import Foundation

final class CommandController {

    private weak var mapViewModel: MapViewModel?

    init(mapViewModel: MapViewModel) {
        self.mapViewModel = mapViewModel
    }

    /// Parse a transcript and apply any recognised commands to the aircraft.
    func process(_ transcript: String) {
        let normalized = normalizeDigits(transcript.lowercased())

        // 1. Departure clearance: "Air India 235 cleared for takeoff"
        if isTakeoffClearance(normalized) {
            if let callsign = mapViewModel?.resolveDepartureCallsign(from: normalized) {
                mapViewModel?.clearForTakeoff(callsign: callsign)
            } else {
                CommandFeedbackManager.shared.aircraftNotFound()
            }
            return
        }

        // 2. Parse commands.
        let commands = parse(transcript)
        guard !commands.isEmpty else {
            CommandFeedbackManager.shared.commandError("Command not recognized")
            return
        }

        // 3. Route: spoken callsign in transcript → selected aircraft → not found.
        if let callsign = mapViewModel?.resolveRadarCallsign(from: normalized) {
            mapViewModel?.applyToCallsign(callsign, commands: commands)
        } else {
            mapViewModel?.apply(commands)
        }
    }

    private func isTakeoffClearance(_ normalized: String) -> Bool {
        normalized.contains("clear") &&
        (normalized.contains("takeoff") || normalized.contains("take off"))
    }

    // MARK: - Parsing

    func parse(_ transcript: String) -> [AircraftCommand] {
        let text = normalizeDigits(transcript.lowercased())
        var commands: [AircraftCommand] = []

        if let heading = number(in: text, after: "heading"), (0...360).contains(heading) {
            commands.append(.heading(Double(heading % 360)))
        }

        if let flightLevel = flightLevel(in: text) {
            commands.append(.flightLevel(flightLevel))
        }

        if let speed = number(in: text, after: "speed"), speed > 0 {
            commands.append(.speed(Double(speed)))
        }

        return commands
    }

    // MARK: - Helpers

    /// Map spoken digits to numerals and join them: "two seven zero" → "270".
    private func normalizeDigits(_ text: String) -> String {
        let map = [
            "zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3",
            "four": "4", "five": "5", "six": "6", "seven": "7",
            "eight": "8", "nine": "9", "niner": "9",
        ]
        let mapped = text.split(separator: " ").map { map[String($0)] ?? String($0) }
        var joined = mapped.joined(separator: " ")
        // Collapse spaces between adjacent single digits: "2 7 0" → "270".
        joined = joined.replacingOccurrences(
            of: "(?<=\\d) (?=\\d)", with: "", options: .regularExpression
        )
        return joined
    }

    /// First number appearing after `keyword`.
    private func number(in text: String, after keyword: String) -> Int? {
        guard let keywordRange = text.range(of: keyword) else { return nil }
        let rest = text[keywordRange.upperBound...]
        guard let match = rest.range(of: "\\d{1,3}", options: .regularExpression) else { return nil }
        return Int(rest[match])
    }

    /// "flight level 250" or "fl250".
    private func flightLevel(in text: String) -> Int? {
        if let fl = number(in: text, after: "flight level") { return fl }
        if let match = text.range(of: "fl\\s*\\d{2,3}", options: .regularExpression) {
            return Int(text[match].filter(\.isNumber))
        }
        return nil
    }
}
