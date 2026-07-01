//
//  ExerciseDetail.swift
//  VectraPro
//
//  Full exercise configuration from GET /atc?exerciseId=… — airport, runways,
//  aircraft, airlines, commands, traffic frequencies. Loaded when an exercise
//  is started and used to set up the radar.
//
//  Nested types use all-optional fields so decoding never fails on a
//  missing/null value.
//

import Foundation

struct ExerciseDetailResponse: Decodable {
    let status: Bool
    let record: ExerciseDetail?

    enum CodingKeys: String, CodingKey { case status, record }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decodeIfPresent(Bool.self, forKey: .status)) ?? false
        record = try? c.decodeIfPresent(ExerciseDetail.self, forKey: .record)
    }
}

struct ExerciseDetail: Decodable {
    let id: String
    let exerciseName: String
    let icaoCode: String?
    let airportName: String?
    let vorName: String?
    let mapLatitude: Double?
    let mapLongitude: Double?
    let isRunwayEnabled: Bool?
    let runways: [RunwayConfig]
    let aircrafts: [AircraftType]
    let airlines: [Airline]
    let commands: Commands?
    let fixes: [Fix]
    let zones: [Zone]
    let obstructions: [Obstruction]
    let frequencyOfDeparture: FrequencyOfDeparture?
    let frequencyOfArrival: FrequencyOfArrival?
    let frequencyOfEnroute: FrequencyOfEnroute?

    struct MapLocation: Decodable { let mapLatitude: Double?; let mapLongitude: Double? }

    struct RunwayConfig: Decodable {
        let runwayId: String?
        let runwayStrips: [Strip]?
    }

    struct Strip: Decodable {
        let stripName: String?
        let stripLatitude: Double?
        let stripLongitude: Double?
        let activeLocalizer: Bool?
        let displayLocalizer: Bool?
    }

    struct AircraftType: Decodable {
        let icaoCode: String?
        let model: String?
        let icaoWTC: String?
        let maxBankAngleSteepTurns: Int?
        let steepTurnAirspeedKNTS: Int?
        let bestGlideAirspeed: Int?
    }

    struct Airline: Decodable {
        let icaoCode: String?
        let callSign: String?
    }

    struct Commands: Decodable {
        let altitude: [String]?
        let speed: [String]?
        let vectoring: [String]?
        let approach: [String]?
        let takeoff: [String]?
        let abbreviationCodes: [String]?
    }

    struct Fix: Decodable {
        let fixId: String?
        let fixName: String?
        let fixType: String?
        let type: String?
        let latitude: Double?
        let longitude: Double?
        let radials: [Radial]?
    }

    struct Radial: Decodable {
        let radialId: String?
        let name: String?
        let angle: Double?
        let distance: Double?
        let source: String?
    }

    struct Zone: Decodable {
        let zoneId: String?
        let zoneName: String?
        let zoneType: String?
        let isActive: Bool?
        let colliders: [Collider]?
        let color: String?
    }

    struct Collider: Decodable {
        let latitude: Double?
        let longitude: Double?
    }

    /// Spawn frequency for each traffic type (type + flight count + time value).
    struct FrequencyOfDeparture: Decodable {
        let type: String?
        let departureFlights: Int?
        let departureFlightsTimeValue: Int?
    }
    struct FrequencyOfArrival: Decodable {
        let type: String?
        let arrivalFlights: Int?
        let arrivalFlightsTimeValue: Int?
    }
    struct FrequencyOfEnroute: Decodable {
        let type: String?
        let enrouteFlights: Int?
        let enrouteFlightsTimeValue: Int?
    }

    /// An obstruction (shown in the UI as an "obstacle").
    struct Obstruction: Decodable {
        let obstructionId: String?
        let obstructionName: String?
        let obstructionType: String?
        let elevationInFeet: Double?
        let latitude: Double?
        let longitude: Double?
        let isLighted: Bool?
    }

    enum CodingKeys: String, CodingKey {
        case id, exerciseName, icaoCode, airportName, vorName
        case mapLocation, isRunwayEnabled, runwaysResponse, aircrafts, airlines, commands, fixes, zone
        case obstruction
        case frequencyOfDeparture, frequencyOfArrival, frequencyOfEnroute
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        exerciseName    = (try? c.decodeIfPresent(String.self, forKey: .exerciseName)) ?? ""
        icaoCode        = try? c.decodeIfPresent(String.self, forKey: .icaoCode)
        airportName     = try? c.decodeIfPresent(String.self, forKey: .airportName)
        vorName         = try? c.decodeIfPresent(String.self, forKey: .vorName)
        let map         = try? c.decodeIfPresent(MapLocation.self, forKey: .mapLocation)
        mapLatitude     = map?.mapLatitude
        mapLongitude    = map?.mapLongitude
        isRunwayEnabled = try? c.decodeIfPresent(Bool.self, forKey: .isRunwayEnabled)
        runways         = (try? c.decodeIfPresent([RunwayConfig].self, forKey: .runwaysResponse)) ?? []
        aircrafts       = (try? c.decodeIfPresent([AircraftType].self, forKey: .aircrafts)) ?? []
        airlines        = (try? c.decodeIfPresent([Airline].self, forKey: .airlines)) ?? []
        commands        = try? c.decodeIfPresent(Commands.self, forKey: .commands)
        fixes           = (try? c.decodeIfPresent([Fix].self, forKey: .fixes)) ?? []
        zones           = (try? c.decodeIfPresent([Zone].self, forKey: .zone)) ?? []
        obstructions    = (try? c.decodeIfPresent([Obstruction].self, forKey: .obstruction)) ?? []
        frequencyOfDeparture = try? c.decodeIfPresent(FrequencyOfDeparture.self, forKey: .frequencyOfDeparture)
        frequencyOfArrival   = try? c.decodeIfPresent(FrequencyOfArrival.self, forKey: .frequencyOfArrival)
        frequencyOfEnroute   = try? c.decodeIfPresent(FrequencyOfEnroute.self, forKey: .frequencyOfEnroute)
    }
}
