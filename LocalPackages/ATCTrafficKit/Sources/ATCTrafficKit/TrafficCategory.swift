//
//  TrafficCategory.swift
//  ATCTrafficKit
//
//  The three kinds of traffic an exercise generates.
//
//  Declared here rather than reusing the simulator's own flight category, because
//  this package must stay free of it: sharing that type would pull in the whole
//  simulator, and with it CoreLocation, which is what stops a package from being
//  ported. Callers map between the two at their boundary — a three-case switch, in
//  exchange for scheduling logic that runs anywhere.
//

import Foundation

public enum TrafficCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case arrival
    case departure
    case enroute

    /// Share of airspace capacity each category is entitled to. Renormalised over
    /// whichever categories an exercise actually enables, so the weights hold
    /// whether all three are on or only one.
    public var capacityWeight: Double {
        switch self {
        case .arrival:   return 40
        case .departure: return 30
        case .enroute:   return 30
        }
    }

    /// Priority order used wherever categories are listed or split.
    public static let inPriorityOrder: [TrafficCategory] = [.arrival, .departure, .enroute]

    /// Departures start on the runway, so they are never placed on the radar at
    /// exercise start — they wait in the hangar for a takeoff clearance.
    public var spawnsOnRadarInitially: Bool { self != .departure }
}
