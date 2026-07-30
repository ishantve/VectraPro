//
//  AircraftCommand.swift
//  VectraPro
//
//  A parsed instruction for an aircraft.
//

import Foundation

public enum AircraftCommand: Equatable {
    case heading(Double)                        // fly an absolute heading (shortest turn)
    case headingTurn(Double, TurnDirection)     // absolute heading, forced turn direction
    case relativeTurn(Double, TurnDirection)    // turn N degrees left / right
    case presentHeading                         // stop the turn, hold current heading
    /// Stop an ongoing turn on a given heading, keeping the direction already
    /// being turned. Distinct from `heading`, which clears the direction and takes
    /// the shortest way round — that could reverse a turn already in progress.
    case stopTurn(Double)
    /// Climb, descend or maintain — always in feet.
    ///
    /// Phraseology says either "flight level two six zero" or "eight thousand
    /// feet", but that difference is only ever heard, never flown: the aircraft
    /// stores one altitude and the readback comes from the template that was
    /// spoken. Carrying both forms down here would double every altitude case for
    /// no gain, and let the two drift apart.
    case altitude(feet: Double)
    /// Maintain a block between two altitudes, in feet. Phraseology allows the two
    /// ends to be given in different units ("block eight thousand feet to flight
    /// level two six zero"), which one representation handles for free.
    case altitudeBlock(lowFeet: Double, highFeet: Double)
    case speed(Double)          // maintain an exact speed in knots
    case minSpeed(Double)       // maintain xxx knots or greater (speed floor)
    case maxSpeed(Double)       // do not exceed xxx knots (speed ceiling)
    /// Stop an ongoing climb, levelling off at this altitude.
    ///
    /// Not the same as `altitude`: an aircraft already above the given level must
    /// stay where it is, not descend to it. "Stop climb" only ever removes climb.
    case stopClimb(atFeet: Double)
    /// Stop an ongoing descent, levelling off at this altitude.
    case stopDescent(atFeet: Double)
    case hold(String)           // proceed direct to a holding fix and hold there
    /// Proceed direct to a fix and carry on from there — a re-route, not a hold.
    case proceedDirect(fix: String)
    case interceptLocalizer(runway: String)   // intercept the localizer for a runway
    /// Set the transponder code.
    case squawk(code: String)
}
