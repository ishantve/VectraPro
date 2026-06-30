//
//  RadarLayerHandler.swift
//  VectraPro
//
//  Logic for the top-right radar layer toggles (Obstacles / Enroute /
//  Arrival / Departure), kept separate from the MapScreen view.
//  Fill each function in independently.
//

import Foundation

@MainActor
final class RadarLayerHandler {

    static let shared = RadarLayerHandler()
    private init() {}

    private var radar: MapViewModel { MapViewModel.shared }

    /// Routes a layer toggle to its function.
    func toggle(_ layer: MapScreen.RadarLayer, isOn: Bool) {
        switch layer {
        case .obstacle:       obstacle(isOn)
        case .zone:           zone(isOn)
        case .holdingPattern: holdingPattern(isOn)
        case .enroute:        enroute(isOn)
        case .arrival:        arrival(isOn)
        case .departure:      departure(isOn)
        }
    }

    // MARK: - Per-layer functions (fill these in)

    func obstacle(_ isOn: Bool)       { /* TODO */ }
    func zone(_ isOn: Bool)           { /* TODO */ }
    func holdingPattern(_ isOn: Bool) { /* TODO */ }
    func enroute(_ isOn: Bool)        { /* TODO */ }
    func arrival(_ isOn: Bool)        { /* TODO */ }
    func departure(_ isOn: Bool)      { /* TODO */ }
}
