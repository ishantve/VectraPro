//
//  SpawnFrequency.swift
//  ATCTrafficKit
//
//  How often a category produces traffic, as an exercise configures it.
//
//  The backend expresses this as a type string plus a flight count and a time
//  window ("custom", 6 flights, 30 minutes). That shape is kept out of here: the
//  caller decodes its own payload and hands over a value, so a change of wire
//  format does not reach the scheduler.
//

import Foundation

public enum SpawnFrequency: Equatable, Sendable, Codable {

    /// Category switched off — no traffic at all.
    case none

    /// A fixed rate: `flights` aircraft spread evenly over `minutes`.
    case custom(flights: Int, minutes: Int)

    /// Irregular arrivals, drawn from the schedule's interval choices.
    case random

    /// Interval between spawns, or nil when the configuration produces none.
    ///
    /// A count or window of zero yields nil rather than an infinite or zero
    /// interval — a misconfigured exercise should produce no traffic, not one
    /// aircraft per tick.
    public var fixedInterval: TimeInterval? {
        guard case .custom(let flights, let minutes) = self,
              flights > 0, minutes > 0 else { return nil }
        return Double(minutes) * 60.0 / Double(flights)
    }

    public var isActive: Bool {
        switch self {
        case .none:            return false
        case .random:          return true
        case .custom:          return fixedInterval != nil
        }
    }

    /// Builds a frequency from the backend's string form.
    /// Anything unrecognised — including a missing value — means off.
    public init(type: String?, flights: Int?, minutes: Int?) {
        switch type?.lowercased() {
        case "custom":
            self = .custom(flights: flights ?? 0, minutes: minutes ?? 0)
        case "random":
            self = .random
        default:
            self = .none
        }
    }
}
