//
//  SceneModels.swift
//  ATCSimKit
//
//  Clean domain inputs the simulation needs, decoupled from any wire/DTO format.
//  The host app maps its API models (e.g. ExerciseDetail.Fix) onto these.
//

import Foundation

/// A navigation fix (waypoint / holding fix).
public struct Fix {
    public let fixName: String?
    public let type: String?
    public let latitude: Double?
    public let longitude: Double?

    public init(fixName: String?, type: String?, latitude: Double?, longitude: Double?) {
        self.fixName = fixName
        self.type = type
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// An airline, for spoken-callsign resolution (ICAO code + spoken call sign).
public struct Airline {
    public let icaoCode: String?
    public let callSign: String?

    public init(icaoCode: String?, callSign: String?) {
        self.icaoCode = icaoCode
        self.callSign = callSign
    }
}

/// An aircraft type, for wake-turbulence separation (ICAO code + WTC).
public struct AircraftType {
    public let icaoCode: String?
    public let icaoWTC: String?

    public init(icaoCode: String?, icaoWTC: String?) {
        self.icaoCode = icaoCode
        self.icaoWTC = icaoWTC
    }
}
