//
//  ExerciseDetail+Domain.swift
//  VectraPro
//
//  Maps the API wire models (ExerciseDetail.*) onto ATCSimKit's clean domain
//  inputs, so the simulation package never depends on the network DTO.
//

import ATCSimKit

extension ExerciseDetail.Fix {
    var asDomain: ATCSimKit.Fix {
        ATCSimKit.Fix(fixName: fixName, type: type, latitude: latitude, longitude: longitude)
    }
}

extension ExerciseDetail.Airline {
    var asDomain: ATCSimKit.Airline {
        ATCSimKit.Airline(icaoCode: icaoCode, callSign: callSign)
    }
}

extension ExerciseDetail.AircraftType {
    var asDomain: ATCSimKit.AircraftType {
        ATCSimKit.AircraftType(icaoCode: icaoCode, icaoWTC: icaoWTC)
    }
}
