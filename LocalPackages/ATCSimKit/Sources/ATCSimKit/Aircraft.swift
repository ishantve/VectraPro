//
//  Aircraft.swift
//  ATCSimKit
//
//  A radar aircraft target — the core simulation entity.
//

import CoreLocation
import Foundation

/// Forced turn direction for a vectoring command (nil = shortest way round).
public enum TurnDirection {
    case left, right
}

/// Departure takeoff phase. Set by clearForTakeoff(); nil once at normal cruise.
public enum TakeoffState: Equatable {
    /// Rolling on the runway accelerating to rotation speed.
    case groundRoll(runwayHeading: Double)
    /// Airborne but still in initial climb-out (until >1 000 ft).
    case climbout
}

/// Which radar list (hangar) an aircraft belongs to.
public enum FlightCategory {
    case arrival, departure, enroute
}

public struct Aircraft: Identifiable {
    public let id = UUID()
    public var callsign: String
    public var position: CLLocationCoordinate2D
    public var headingDegrees: Double
    /// Radar list this aircraft appears under (arrival / departure / enroute).
    public var category: FlightCategory = .arrival
    /// Assigned runway (e.g. "29L"); shown in the hangar list when set.
    public var assignedRunway: String? = nil
    /// Holding fix this aircraft is holding at (nil = not holding).
    public var holdingName: String? = nil
    /// Holding fix the aircraft is currently flying toward (auto-turn).
    public var holdingTargetName: String? = nil
    /// Inbound leg course (toward the fix) for the holding racetrack.
    public var holdingInboundCourse: Double? = nil
    /// Position around the holding loop as a fraction (0…1, 0 = fix).
    public var holdingProgress: Double = 0
    /// Racetrack geometry the aircraft is CURRENTLY flying.
    public var holdingRadiusM: Double = 0
    public var holdingLegM: Double = 0
    /// Runway designator the aircraft is cleared to intercept the localizer for.
    public var interceptRunway: String? = nil
    /// Takeoff phase; nil when airborne and under normal ATC control.
    public var takeoffState: TakeoffState? = nil
    /// ICAO type code of the aircraft (e.g. "AT72"), from the exercise.
    public var aircraftType: String? = nil
    /// SSR squawk code (4 octal digits, e.g. "2301").
    public var squawk: String = "2000"
    /// Free-text remarks line shown at the bottom of the data block.
    public var remarks: String? = nil
    /// Commanded heading the aircraft is turning toward (nil = none).
    public var targetHeading: Double? = nil
    /// Forced turn direction toward the target (nil = shortest way).
    public var turnDirection: TurnDirection? = nil
    public var speedKnots: Double = Aircraft.defaultSpeedKnots
    /// Commanded speed the aircraft is accelerating/decelerating to (nil = none).
    public var targetSpeedKnots: Double? = nil
    /// Speed clearance limits.
    public var minSpeedKnots: Double? = nil
    public var maxSpeedKnots: Double? = nil
    public var altitudeFeet: Double = Aircraft.defaultAltitudeFeet
    /// Commanded altitude the aircraft is climbing/descending to (nil = none).
    public var targetAltitudeFeet: Double? = nil
    /// Altitude block limits.
    public var minAltitudeFeet: Double? = nil
    public var maxAltitudeFeet: Double? = nil

    /// Horizontal separation ring radius (NM).
    public var colliderRadiusNM: Double = 2.5
    /// Body diamond half-extents.
    public var bodyForwardNM: Double = 0.6
    public var bodySideNM:    Double = 0.6
    /// Nose collider — thin rectangle from body-diamond front to leader-line tip.
    public var noseOffsetNM:  Double = 1.22
    public var noseForwardNM: Double = 0.62
    public var noseSideNM:    Double = 0.07

    /// Recent past positions (oldest first) used to draw the history trail.
    public var history: [CLLocationCoordinate2D] = []

    /// Data-block placement relative to the aircraft (polar offset). (View-layer
    /// state kept here for now; a candidate to move out of the model later.)
    public var labelBearingDegrees: Double = 45
    public var labelDistanceMeters: Double = 2.0 * 1852

    public static let defaultSpeedKnots = 250.0
    public static let defaultAltitudeFeet = 18_000.0   // FL180

    public init(callsign: String, position: CLLocationCoordinate2D, headingDegrees: Double) {
        self.callsign = callsign
        self.position = position
        self.headingDegrees = headingDegrees
    }

    /// Flight level (altitude in hundreds of feet), e.g. 180.
    public var flightLevel: Int {
        Int(altitudeFeet / 100)
    }

    /// Cache key for change detection — encodes every field visible in the data block.
    public var dataBlock: String {
        let tfl  = targetAltitudeFeet.map { "\(Int($0 / 100))" } ?? ""
        let tspd = targetSpeedKnots.map   { "\(Int($0))" }        ?? ""
        return "\(callsign)|\(aircraftType ?? "")|\(tfl)|\(flightLevel)|\(tspd)|\(Int(speedKnots))|\(Int(headingDegrees.rounded()))|\(squawk)|\(remarks ?? "")"
    }
}
