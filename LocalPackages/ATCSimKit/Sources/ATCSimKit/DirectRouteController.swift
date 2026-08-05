//
//  DirectRouteController.swift
//  ATCSimKit
//
//  "Proceed direct to PJ" — steer to a fix and then carry on.
//
//  Deliberately separate from `HoldingController`, which does the same steering
//  but captures the aircraft at the fix and puts it into a racetrack. A re-route
//  must not do that: the aircraft passes the fix and keeps the heading it arrived
//  on, which is what a controller expects when they clear an aircraft direct
//  without a hold.
//

import Foundation
import GeoNavKit

public enum DirectRouteController {

    /// How close counts as having reached the fix. The same tolerance as a hold
    /// capture, so the two behave consistently.
    public static let arrivalRadiusM = HoldingController.captureRadiusM

    /// Continuously steer toward the commanded fix.
    public static func steer(_ aircraft: inout Aircraft, fixes: [Fix]) {
        guard let name = aircraft.directToFix,
              let position = FixLookup.position(named: name, in: fixes) else { return }
        aircraft.turnDirection = nil
        aircraft.targetHeading = Geo.bearing(from: aircraft.position, to: position)
    }

    /// Releases the aircraft once it reaches the fix, leaving it tracking the
    /// heading it arrived on until it is given something else.
    ///
    /// Returns true when an arrival happened, so a caller can report it.
    @discardableResult
    public static func releaseOnArrival(_ aircraft: inout Aircraft, fixes: [Fix]) -> Bool {
        guard let name = aircraft.directToFix,
              let position = FixLookup.position(named: name, in: fixes) else { return false }
        guard Geo.distanceMeters(from: aircraft.position, to: position) < arrivalRadiusM
        else { return false }

        aircraft.directToFix = nil
        aircraft.targetHeading = nil   // maintain present heading
        aircraft.turnDirection = nil
        return true
    }
}
