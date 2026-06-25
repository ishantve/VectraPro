//
//  AircraftCommand.swift
//  VectraPro
//
//  A parsed instruction for an aircraft.
//

import Foundation

enum AircraftCommand: Equatable {
    case heading(Double)        // turn to an absolute heading (0–359)
    case flightLevel(Int)       // climb / descend / maintain to a flight level
    case speed(Double)          // set speed in knots
}
