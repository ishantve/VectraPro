//
//  Aircraft.swift
//  VectraPro
//
//  A radar aircraft target.
//

import CoreLocation
import Foundation

/// Forced turn direction for a vectoring command (nil = shortest way round).
enum TurnDirection {
    case left, right
}

/// Departure takeoff phase. Set by clearForTakeoff(); nil once the aircraft is
/// at normal cruise and fully under ATC control.
enum TakeoffState: Equatable {
    /// Aircraft is rolling on the runway accelerating to rotation speed.
    case groundRoll(runwayHeading: Double)
    /// Airborne but still in initial climb-out (until >1 000 ft).
    case climbout
}

/// Which radar list (hangar) an aircraft belongs to.
enum FlightCategory {
    case arrival, departure, enroute
}

struct Aircraft: Identifiable {
    let id = UUID()
    var callsign: String
    var position: CLLocationCoordinate2D
    var headingDegrees: Double
    /// Radar list this aircraft appears under (arrival / departure / enroute).
    var category: FlightCategory = .arrival
    /// Assigned runway (e.g. "29L"); shown in the hangar list when set.
    var assignedRunway: String? = nil
    /// Holding fix this aircraft is holding at (nil = not holding).
    var holdingName: String? = nil
    /// Takeoff phase; nil when the aircraft is airborne and under normal ATC control.
    var takeoffState: TakeoffState? = nil
    /// ICAO type code of the aircraft (e.g. "AT72"), from the exercise.
    var aircraftType: String? = nil
    /// SSR squawk code (4 octal digits, e.g. "2301").
    var squawk: String = "2000"
    /// Free-text remarks line shown at the bottom of the data block (nil = hidden).
    var remarks: String? = nil
    /// Commanded heading the aircraft is turning toward (nil = none).
    var targetHeading: Double? = nil
    /// Forced turn direction toward the target (nil = take the shortest way).
    var turnDirection: TurnDirection? = nil
    var speedKnots: Double = Aircraft.defaultSpeedKnots
    /// Commanded speed the aircraft is accelerating/decelerating to (nil = none).
    var targetSpeedKnots: Double? = nil
    /// Speed clearance limits: "maintain xxx or greater" / "do not exceed xxx".
    var minSpeedKnots: Double? = nil
    var maxSpeedKnots: Double? = nil
    var altitudeFeet: Double = Aircraft.defaultAltitudeFeet
    /// Commanded altitude the aircraft is climbing/descending to (nil = none).
    var targetAltitudeFeet: Double? = nil
    /// Altitude block limits: "maintain block FL low through FL high".
    var minAltitudeFeet: Double? = nil
    var maxAltitudeFeet: Double? = nil

    /// Horizontal separation ring radius (NM).
    /// Conflict is flagged when another aircraft enters this zone at a similar altitude.
    var colliderRadiusNM: Double = 2.5
    /// Body diamond — vertices sit on the outer edge of the aircraft body diamond.
    /// half=5.5 pt on a 100pt canvas at zoom 8.8 / 65 NM view ≈ 0.6 NM per half-step.
    var bodyForwardNM: Double = 0.6
    var bodySideNM:    Double = 0.6
    /// Nose collider — thin rectangle from body-diamond front to leader-line tip.
    /// Body front ≈ 0.6 NM, leader tip ≈ 1.85 NM → centre 1.22 NM, half-length 0.62 NM.
    var noseOffsetNM:  Double = 1.22
    var noseForwardNM: Double = 0.62
    var noseSideNM:    Double = 0.07

    /// Recent past positions (oldest first) used to draw the history trail.
    var history: [CLLocationCoordinate2D] = []

    /// Data-block placement relative to the aircraft (polar offset). The user
    /// can drag the block; this offset keeps it attached as the aircraft moves.
    var labelBearingDegrees: Double = 45
    var labelDistanceMeters: Double = 2.0 * 1852   // 2 NM gap; block is corner-anchored up-right

    static let defaultSpeedKnots = 250.0
    static let defaultAltitudeFeet = 18_000.0   // FL180

    /// Flight level (altitude in hundreds of feet), e.g. 180.
    var flightLevel: Int {
        Int(altitudeFeet / 100)
    }

    /// Cache key for change detection — encodes every field visible in the data block.
    var dataBlock: String {
        let tfl  = targetAltitudeFeet.map { "\(Int($0 / 100))" } ?? ""
        let tspd = targetSpeedKnots.map   { "\(Int($0))" }        ?? ""
        return "\(callsign)|\(aircraftType ?? "")|\(tfl)|\(flightLevel)|\(tspd)|\(Int(speedKnots))|\(Int(headingDegrees.rounded()))|\(squawk)|\(remarks ?? "")"
    }
}
