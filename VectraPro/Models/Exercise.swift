//
//  Exercise.swift
//  VectraPro
//
//  Exercise shown on the home screen, fetched from /atc/excercise.
//

import Foundation

/// Response wrapper for the exercise list.
struct ExercisesResponse: Decodable {
    let status: Bool
    let record: [Exercise]

    enum CodingKeys: String, CodingKey { case status, record }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decodeIfPresent(Bool.self, forKey: .status)) ?? false
        record = (try? c.decodeIfPresent([Exercise].self, forKey: .record)) ?? []
    }
}

struct Exercise: Decodable, Identifiable, Hashable {
    let id: String
    let exerciseName: String
    let aircraftMode: String?
    let isMultiMode: Bool?
    let airspaceCapacity: Int?
    let airspaceRadius: Int?
    let aircraftSpawningCount: Int?
    let gameEndTime: Int?
    let weatherEnabled: Bool?
    let weatherType: String?
    let departureFlights: Int?
    let arrivalFlights: Int?

    // MARK: Display helpers (for the card)

    var weatherValue: String { weatherType ?? ((weatherEnabled ?? false) ? "On" : "Off") }
    var departureValue: String { "\(departureFlights ?? 0)/min" }
    var arrivalValue: String { "\(arrivalFlights ?? 0)/min" }

    // MARK: Nested decoding

    private struct GameEnd: Decodable { let time: Int? }
    private struct WeatherBlock: Decodable { let isEnabled: Bool?; let type: String? }
    private struct DepartureBlock: Decodable { let type: String?; let departureFlights: Int? }
    private struct ArrivalBlock: Decodable { let type: String?; let arrivalFlights: Int? }

    enum CodingKeys: String, CodingKey {
        case id, exerciseName, aircraftMode, isMultiMode
        case airspaceCapacity, airspaceRadius, aircraftSpawningCount
        case gameEnd, weather, frequencyOfDeparture, frequencyOfArrival
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                    = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        exerciseName          = (try? c.decodeIfPresent(String.self, forKey: .exerciseName)) ?? ""
        aircraftMode          = try? c.decodeIfPresent(String.self, forKey: .aircraftMode)
        isMultiMode           = try? c.decodeIfPresent(Bool.self, forKey: .isMultiMode)
        airspaceCapacity      = try? c.decodeIfPresent(Int.self, forKey: .airspaceCapacity)
        airspaceRadius        = try? c.decodeIfPresent(Int.self, forKey: .airspaceRadius)
        aircraftSpawningCount = try? c.decodeIfPresent(Int.self, forKey: .aircraftSpawningCount)
        gameEndTime           = (try? c.decodeIfPresent(GameEnd.self, forKey: .gameEnd))?.time

        let weather = try? c.decodeIfPresent(WeatherBlock.self, forKey: .weather)
        weatherEnabled  = weather?.isEnabled
        weatherType     = weather?.type
        departureFlights = (try? c.decodeIfPresent(DepartureBlock.self, forKey: .frequencyOfDeparture))?.departureFlights
        arrivalFlights   = (try? c.decodeIfPresent(ArrivalBlock.self, forKey: .frequencyOfArrival))?.arrivalFlights
    }

    /// Memberwise init for previews / local construction.
    init(id: String,
         exerciseName: String,
         aircraftMode: String? = nil,
         isMultiMode: Bool? = nil,
         airspaceCapacity: Int? = nil,
         airspaceRadius: Int? = nil,
         aircraftSpawningCount: Int? = nil,
         gameEndTime: Int? = nil,
         weatherEnabled: Bool? = nil,
         weatherType: String? = nil,
         departureFlights: Int? = nil,
         arrivalFlights: Int? = nil) {
        self.id = id
        self.exerciseName = exerciseName
        self.aircraftMode = aircraftMode
        self.isMultiMode = isMultiMode
        self.airspaceCapacity = airspaceCapacity
        self.airspaceRadius = airspaceRadius
        self.aircraftSpawningCount = aircraftSpawningCount
        self.gameEndTime = gameEndTime
        self.weatherEnabled = weatherEnabled
        self.weatherType = weatherType
        self.departureFlights = departureFlights
        self.arrivalFlights = arrivalFlights
    }

    static func == (lhs: Exercise, rhs: Exercise) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
