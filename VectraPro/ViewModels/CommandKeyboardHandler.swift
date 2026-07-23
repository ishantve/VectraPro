//
//  CommandKeyboardHandler.swift
//  VectraPro
//
//  Logic for the radar command keypad, kept separate from its view
//  (`CommandKeyboard`). One function per key — fill each in independently.
//
//  Some commands need a numeric value (the "*" in the key, e.g. ↑SPD*). For
//  those, `requiresValue` is true and the view collects a number via the
//  numeric keypad, then calls `perform(_:value:)`.
//

import Foundation

@MainActor
final class CommandKeyboardHandler {

    static let shared = CommandKeyboardHandler()

    /// The view-model commands are applied to — injected (defaults to the shared
    /// instance) rather than reached into globally, so the dependency is explicit.
    private let radar: MapViewModel
    private init(radar: MapViewModel? = nil) {
        self.radar = radar ?? .shared
    }

    // MARK: - Valued (numeric-entry) commands

    private enum Valued {
        case increaseSpeed, decreaseSpeed, maintainSpeed, minSpeed, maxSpeed
        case climbMaintain, descendMaintain, block
        case turnLeftHeading, turnRightHeading, turnDegreesLeft, turnDegreesRight, flyHeading
    }

    private func valuedKind(for command: String) -> Valued? {
        switch command {
        case "↑SPD*":   return .increaseSpeed
        case "↓SPD*":   return .decreaseSpeed
        case "SPD*":    return .maintainSpeed
        case "SPD≥*":   return .minSpeed
        case "SPD≤*":   return .maxSpeed
        case "C/M*":    return .climbMaintain
        case "D/M*":    return .descendMaintain
        case "MBLK*-*": return .block
        case "TLH":     return .turnLeftHeading
        case "TRH":     return .turnRightHeading
        case "T*DL":    return .turnDegreesLeft
        case "T*DR":    return .turnDegreesRight
        case "FH":      return .flyHeading
        default:        return nil
        }
    }

    /// True if the command needs a number entered before it applies.
    func requiresValue(_ command: String) -> Bool {
        valuedKind(for: command) != nil
    }

    /// How many numbers the command needs (block altitude needs two).
    func valueCount(for command: String) -> Int {
        valuedKind(for: command) == .block ? 2 : 1
    }

    /// Full command sentence shown on the keypad; the keypad replaces "xxx"
    /// with the value being typed.
    func prompt(for command: String) -> String {
        switch valuedKind(for: command) {
        case .increaseSpeed: return "Increase speed to xxx knots"
        case .decreaseSpeed: return "Reduce speed to xxx knots"
        case .maintainSpeed:    return "Maintain xxx knots"
        case .minSpeed:         return "Maintain xxx knots or greater"
        case .maxSpeed:         return "Do not exceed xxx knots"
        case .climbMaintain:     return "Climb and maintain FL xxx"
        case .descendMaintain:   return "Descend and maintain FL xxx"
        case .block:             return "Maintain block FL xxx through FL xxx"
        case .turnLeftHeading:   return "Turn left heading xxx"
        case .turnRightHeading:  return "Turn right heading xxx"
        case .turnDegreesLeft:   return "Turn xxx degrees left"
        case .turnDegreesRight:  return "Turn xxx degrees right"
        case .flyHeading:        return "Fly heading xxx"
        case nil:                return command
        }
    }

    /// Apply a single-value command with the number entered on the keypad.
    func perform(_ command: String, value: Int) {
        switch valuedKind(for: command) {
        case .increaseSpeed:   increaseSpeed(to: value)
        case .decreaseSpeed:   decreaseSpeed(to: value)
        case .maintainSpeed:   maintainSpeed(value)
        case .minSpeed:        maintainSpeedOrGreater(value)
        case .maxSpeed:        doNotExceedSpeed(value)
        case .climbMaintain:    climbMaintain(value)
        case .descendMaintain:  descendMaintain(value)
        case .turnLeftHeading:  turnLeftHeading(value)
        case .turnRightHeading: turnRightHeading(value)
        case .turnDegreesLeft:  turnDegreesLeft(value)
        case .turnDegreesRight: turnDegreesRight(value)
        case .flyHeading:       flyHeading(value)
        case .block, nil:       break
        }
    }

    /// Apply a two-value (block altitude) command.
    func perform(_ command: String, low: Int, high: Int) {
        guard valuedKind(for: command) == .block else { return }
        maintainBlock(low: low, high: high)
    }

    // MARK: - Valueless commands

    /// Routes a tapped key (its title) to its function.
    func perform(_ command: String) {
        switch command {
        case "ILOC Rwy*": ilocRunway()
        case "C/T Rwy*":  clearedToRunway()
        case "GO ARD":    goAround()
        case "HLD":       hold()
        case "H/O":       handOff()
        case "DIR":       direct()
        case "FPH":       flyPresentHeading()
        default:
            #if DEBUG
            print("CommandKeyboard: unhandled command \(command)")
            #endif
        }
    }

    // MARK: - Speed commands

    /// "Increase speed to xxx knots."
    func increaseSpeed(to knots: Int) {
        radar.apply([.speed(Double(knots))])
    }

    /// "Decrease / reduce speed to xxx knots."
    func decreaseSpeed(to knots: Int) {
        radar.apply([.speed(Double(knots))])
    }

    /// "Maintain xxx knots."
    func maintainSpeed(_ knots: Int) {
        radar.apply([.speed(Double(knots))])
    }

    /// "Maintain xxx knots or greater."
    func maintainSpeedOrGreater(_ knots: Int) {
        radar.apply([.minSpeed(Double(knots))])
    }

    /// "Do not exceed xxx knots."
    func doNotExceedSpeed(_ knots: Int) {
        radar.apply([.maxSpeed(Double(knots))])
    }

    // MARK: - Altitude commands

    /// "Climb and maintain FL xxx."
    func climbMaintain(_ flightLevel: Int) {
        radar.apply([.flightLevel(flightLevel)])
    }

    /// "Descend and maintain FL xxx."
    func descendMaintain(_ flightLevel: Int) {
        radar.apply([.flightLevel(flightLevel)])
    }

    /// "Maintain block FL low through FL high."
    func maintainBlock(low: Int, high: Int) {
        radar.apply([.altitudeBlock(low: low, high: high)])
    }

    // MARK: - Vectoring commands

    /// "Turn left heading xxx" — absolute heading, forced left turn.
    func turnLeftHeading(_ heading: Int) {
        radar.apply([.headingTurn(Double(heading % 360), .left)])
    }

    /// "Turn right heading xxx" — absolute heading, forced right turn.
    func turnRightHeading(_ heading: Int) {
        radar.apply([.headingTurn(Double(heading % 360), .right)])
    }

    /// "Turn xxx degrees left" — relative turn.
    func turnDegreesLeft(_ degrees: Int) {
        radar.apply([.relativeTurn(Double(degrees), .left)])
    }

    /// "Turn xxx degrees right" — relative turn.
    func turnDegreesRight(_ degrees: Int) {
        radar.apply([.relativeTurn(Double(degrees), .right)])
    }

    /// "Fly heading xxx" — absolute heading, shortest turn.
    func flyHeading(_ heading: Int) {
        radar.apply([.heading(Double(heading % 360))])
    }

    /// "Fly present heading" — stop the turn and hold the current heading.
    func flyPresentHeading() {
        radar.apply([.presentHeading])
    }

    // MARK: - Other commands (fill these in)

    func ilocRunway()        { /* TODO */ }
    func clearedToRunway()   { /* TODO */ }
    func goAround()          { /* TODO */ }
    func hold()              { /* TODO */ }
    func handOff()           { /* TODO */ }
    func direct()            { /* TODO */ }
}
