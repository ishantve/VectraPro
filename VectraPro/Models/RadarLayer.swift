//
//  RadarLayer.swift
//  VectraPro
//
//  The top-right radar layer toggles (Obstacles / Zone / Holding / Enroute /
//  Arrival / Departure). This is a domain model — it was previously nested
//  inside the MapScreen view; lifting it out keeps the view free of model
//  definitions and lets other types refer to it without depending on the view.
//

import Foundation

enum RadarLayer: String, CaseIterable, Identifiable {
    case obstacle, zone, holdingPattern, enroute, arrival, departure
    var id: String { rawValue }
    var asset: String { rawValue }

    /// Title shown above the hangar list.
    var title: String {
        switch self {
        case .arrival:   return "Arrival"
        case .departure: return "Departure"
        case .enroute:   return "Enroute"
        default:         return rawValue.capitalized
        }
    }

    /// The aircraft category this layer lists (nil = not a flight list).
    var flightCategory: FlightCategory? {
        switch self {
        case .arrival:   return .arrival
        case .departure: return .departure
        case .enroute:   return .enroute
        default:         return nil
        }
    }

    /// Layers that open a list panel (single-select among themselves).
    var opensHangar: Bool {
        flightCategory != nil || self == .holdingPattern || self == .zone || self == .obstacle
    }

    /// Enroute / Arrival / Departure ship with the grey bg + border baked into
    /// the asset; the first three are plain icons we style to match in code.
    var hasBakedStyle: Bool {
        switch self {
        case .enroute, .arrival, .departure: return true
        default: return false
        }
    }
}
