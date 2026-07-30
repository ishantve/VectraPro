//
//  TrafficCategory+FlightCategory.swift
//  VectraPro
//
//  Bridges the scheduler's category to the simulator's.
//
//  Two enums for the same three things looks like duplication, and is a deliberate
//  price. ATCTrafficKit has no dependencies at all — that is what allows it an FFI
//  and, through it, a Unity or React Native port. Sharing `FlightCategory` would
//  pull in ATCSimKit, and ATCSimKit carries CoreLocation, which no other platform
//  has. So the packages stay apart and the app pays for a three-case switch, which
//  is the only place the two vocabularies meet.
//

import ATCSimKit
import ATCTrafficKit

extension FlightCategory {
    var asTraffic: TrafficCategory {
        switch self {
        case .arrival:   return .arrival
        case .departure: return .departure
        case .enroute:   return .enroute
        }
    }
}

extension TrafficCategory {
    var asFlight: FlightCategory {
        switch self {
        case .arrival:   return .arrival
        case .departure: return .departure
        case .enroute:   return .enroute
        }
    }
}
