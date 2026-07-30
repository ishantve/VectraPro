//
//  ParsedCommand+AircraftCommand.swift
//  VectraPro
//
//  Integration glue: bridge ATCParserKit's platform-independent ParsedCommand
//  (flat, JSON-shaped) into the simulator's rich AircraftCommand enum used by
//  the validation, routing, and physics layers. Parsing lives once in
//  ATCParserKit; this maps its output into our domain model.
//

import ATCParserKit
import ATCSimKit

extension AircraftCommand {

    /// Build a simulator command from a parsed command. Returns nil if the
    /// parsed command is missing a field its type requires (defensive — the
    /// parser always populates the correct fields).
    nonisolated init?(_ parsed: ParsedCommand) {
        switch parsed.type {
        case .heading:
            guard let h = parsed.heading else { return nil }
            self = .heading(h)
        case .headingTurn:
            guard let h = parsed.heading, let d = parsed.direction else { return nil }
            self = .headingTurn(h, .init(d))
        case .relativeTurn:
            guard let deg = parsed.degrees, let d = parsed.direction else { return nil }
            self = .relativeTurn(deg, .init(d))
        case .presentHeading:
            self = .presentHeading
        case .flightLevel:
            guard let fl = parsed.flightLevel else { return nil }
            self = .altitude(feet: Double(fl) * 100)
        case .altitudeBlock:
            guard let lo = parsed.altitudeLow, let hi = parsed.altitudeHigh else { return nil }
            self = .altitudeBlock(lowFeet: Double(lo) * 100,
                                  highFeet: Double(hi) * 100)
        case .speed:
            guard let s = parsed.speed else { return nil }
            self = .speed(s)
        case .minSpeed:
            guard let s = parsed.speed else { return nil }
            self = .minSpeed(s)
        case .maxSpeed:
            guard let s = parsed.speed else { return nil }
            self = .maxSpeed(s)
        case .hold:
            guard let fix = parsed.fix else { return nil }
            self = .hold(fix)
        case .interceptLocalizer:
            guard let runway = parsed.runway else { return nil }
            self = .interceptLocalizer(runway: runway)
        }
    }
}

private extension ATCSimKit.TurnDirection {
    nonisolated init(_ direction: ATCParserKit.TurnDirection) {
        self = (direction == .left) ? .left : .right
    }
}
