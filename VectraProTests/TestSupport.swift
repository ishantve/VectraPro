//
//  TestSupport.swift
//  VectraProTests
//
//  Shared fixtures + helpers for the Simulation/Map unit tests.
//

import CoreLocation
import GeoKit
@testable import VectraPro

/// Approximate coordinate equality (default ~1 m).
func approxEqual(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                 tol: Double = 1e-5) -> Bool {
    abs(a.latitude - b.latitude) < tol && abs(a.longitude - b.longitude) < tol
}

@MainActor
enum Fixtures {
    /// Reference point (~ Delhi / IGI).
    static let center = CLLocationCoordinate2D(latitude: 28.5665, longitude: 77.1031)

    static func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// A runway with `endA` at `a` and `endB` 3 km away on `bearingAB`.
    /// So `RunwayGeometry.threshold(for: designA)` returns `a` with inbound ≈ bearingAB.
    static func runway(_ designA: String = "09", at a: CLLocationCoordinate2D? = nil,
                       _ designB: String = "27", bearingAB: Double = 90) -> Runway {
        let origin = a ?? center
        let b = Geo.offset(from: origin, distanceMeters: 3000, bearingDegrees: bearingAB)
        return Runway(endA: RunwayThreshold(designator: designA, coordinate: origin),
                      endB: RunwayThreshold(designator: designB, coordinate: b),
                      lengthMeters: 3000)
    }

    static func fix(_ name: String, type: String = "HOLDING",
                    lat: Double? = 28.60, lon: Double? = 77.20) -> ExerciseDetail.Fix {
        ExerciseDetail.Fix(fixId: nil, fixName: name, fixType: nil, type: type,
                           latitude: lat, longitude: lon, radials: nil)
    }

    static func aircraft(_ callsign: String = "TST1",
                         at position: CLLocationCoordinate2D? = nil,
                         heading: Double = 0) -> Aircraft {
        Aircraft(callsign: callsign, position: position ?? center, headingDegrees: heading)
    }

    static func type(_ icao: String, wtc: String) -> ExerciseDetail.AircraftType {
        ExerciseDetail.AircraftType(icaoCode: icao, model: nil, icaoWTC: wtc,
                                    maxBankAngleSteepTurns: nil, steepTurnAirspeedKNTS: nil,
                                    bestGlideAirspeed: nil)
    }

    static func airline(_ icao: String, _ callSign: String) -> ExerciseDetail.Airline {
        ExerciseDetail.Airline(icaoCode: icao, callSign: callSign)
    }

    /// A point `nm` nautical miles from `origin` along `bearing`.
    static func offsetNM(from origin: CLLocationCoordinate2D, nm: Double, bearing: Double)
        -> CLLocationCoordinate2D {
        Geo.offset(from: origin, distanceMeters: nm * Distance.metersPerNauticalMile,
                   bearingDegrees: bearing)
    }
}
