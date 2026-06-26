//
//  MapProvider.swift
//  VectraPro
//
//  Which base map renders behind the radar overlays. The selection is a user
//  setting; everything else (overlays, aircraft, controls) is provider-agnostic.
//

import Foundation

enum MapProvider: String, CaseIterable, Identifiable {
    case mapLibre
    case google
    case arcgis

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mapLibre: return "MapLibre (OpenStreetMap)"
        case .google: return "Google Maps"
        case .arcgis: return "ArcGIS (Esri)"
        }
    }

    /// ArcGIS is rendered through MapLibre with Esri tiles (no separate SDK).
    var usesMapLibre: Bool { self == .mapLibre || self == .arcgis }

    /// Persisted choice (UserDefaults / @AppStorage key "mapProvider").
    static let storageKey = "mapProvider"

    static var current: MapProvider {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        return MapProvider(rawValue: raw) ?? .mapLibre
    }
}
