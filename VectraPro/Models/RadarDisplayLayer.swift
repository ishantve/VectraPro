//
//  RadarDisplayLayer.swift
//  VectraPro
//
//  Single source of truth for the map "Display" layers (the MAP LAYERS menu
//  toggles). Previously these were bare strings duplicated across MapScreen,
//  MapViewModel, and both radar controllers — a typo in any copy silently broke
//  a layer. The raw value of each case is the historic key string, so stored
//  state and behaviour are unchanged; only the call sites become type-safe.
//

import Foundation

enum RadarDisplayLayer: String, CaseIterable, Identifiable {
    case weather          = "Weather"
    case radials          = "Radials"
    case radialsNames     = "Radials Names"
    case fixes            = "Fixes"
    case fixesNames       = "Fixes Names"
    case notam            = "NOTAM"
    case zone             = "Zone"
    case holding          = "Holding"
    case holdingRacetrack = "Holding racetrack"
    case trail            = "Trail"
    case obstacles        = "Obstacles"
    case wind             = "Wind"
    case windSpeed        = "Wind Speed"
    case clouds           = "Clouds"
    case lightning        = "Lightening"      // historic spelling preserved
    case thunderstorm     = "Thunderstorm"

    var id: String { rawValue }

    /// Label shown in the MAP LAYERS menu.
    var title: String { rawValue }

    /// SF Symbol shown beside the row.
    var icon: String {
        switch self {
        case .weather:          return "cloud.fill"
        case .radials:          return "scope"
        case .radialsNames:     return "scope"
        case .fixes:            return "triangle.fill"
        case .fixesNames:       return "triangle.fill"
        case .notam:            return "exclamationmark.triangle.fill"
        case .zone:             return "nosign"
        case .holding:          return "smallcircle.filled.circle"
        case .holdingRacetrack: return "oval"
        case .trail:            return "point.3.connected.trianglepath.dotted"
        case .obstacles:        return "mountain.2.fill"
        case .wind:             return "wind"
        case .windSpeed:        return "wind"
        case .clouds:           return "cloud.fill"
        case .lightning:        return "bolt.fill"
        case .thunderstorm:     return "cloud.bolt.rain.fill"
        }
    }

    /// Whether the layer is visible by default when an exercise starts.
    var defaultOn: Bool {
        switch self {
        case .radials, .fixes, .fixesNames, .zone, .holding, .trail: return true
        default: return false
        }
    }

    /// A child layer whose visibility follows this one (parent → labels).
    var dependentLayer: RadarDisplayLayer? {
        switch self {
        case .fixes:   return .fixesNames
        case .radials: return .radialsNames
        default:       return nil
        }
    }
}
