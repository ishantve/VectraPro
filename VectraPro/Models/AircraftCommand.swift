//
//  AircraftCommand.swift
//  VectraPro
//
//  A parsed instruction for an aircraft.
//

import Foundation

enum AircraftCommand: Equatable {
    case heading(Double)                        // fly an absolute heading (shortest turn)
    case headingTurn(Double, TurnDirection)     // absolute heading, forced turn direction
    case relativeTurn(Double, TurnDirection)    // turn N degrees left / right
    case presentHeading                         // stop the turn, hold current heading
    case flightLevel(Int)       // climb / descend / maintain to a flight level
    case altitudeBlock(low: Int, high: Int)   // maintain block FL low through FL high
    case speed(Double)          // maintain an exact speed in knots
    case minSpeed(Double)       // maintain xxx knots or greater (speed floor)
    case maxSpeed(Double)       // do not exceed xxx knots (speed ceiling)
    case hold(String)           // proceed direct to a holding fix and hold there
    case interceptLocalizer(runway: String)   // intercept the localizer for a runway
}
