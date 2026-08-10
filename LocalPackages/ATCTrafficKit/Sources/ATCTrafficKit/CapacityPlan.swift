//
//  CapacityPlan.swift
//  ATCTrafficKit
//
//  Divides a capacity between the categories an exercise has switched on.
//
//  The weights are fixed (40 arrival / 30 departure / 30 enroute) but the set of
//  active categories is not, so they are renormalised over whoever is present —
//  arrival alone gets the whole capacity, not 40% of it.
//
//  Rounding is corrected rather than left to chance: three shares rounded
//  independently need not add up to the total, and a capacity of 10 that plans for
//  9 aircraft quietly under-fills the airspace for the whole exercise. The
//  difference is pushed onto the largest share, where it is proportionally least
//  visible.
//

import Foundation

public enum CapacityPlan {

    /// Splits `total` across `categories` by weight, always summing to `total`.
    ///
    /// Order follows `categories`; the result is positionally aligned with it.
    public static func split(total: Int, among categories: [TrafficCategory]) -> [Int] {
        guard total > 0, !categories.isEmpty else {
            return Array(repeating: 0, count: categories.count)
        }
        let weights = categories.map(\.capacityWeight)
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else {
            return Array(repeating: 0, count: categories.count)
        }

        var shares = weights.map { Int((Double(total) * $0 / totalWeight).rounded()) }

        // Independent rounding can over- or under-shoot; correct on the largest
        // share so the plan and the capacity always agree.
        let difference = total - shares.reduce(0, +)
        if difference != 0,
           let largest = shares.indices.max(by: { shares[$0] < shares[$1] }) {
            shares[largest] += difference
        }
        return shares
    }

    /// The same split as a lookup, for callers that ask by category.
    public static func quotas(total: Int,
                             among categories: [TrafficCategory]) -> [TrafficCategory: Int] {
        Dictionary(uniqueKeysWithValues: zip(categories, split(total: total, among: categories)))
    }

    /// Categories to place on the radar at exercise start, one entry per aircraft.
    ///
    /// Departures are excluded — they leave from a runway, so they wait in the
    /// hangar. With no other category active the whole initial batch falls back to
    /// arrivals, so an exercise never opens on an empty radar.
    public static func initialRadarCategories(count: Int,
                                              active: [TrafficCategory]) -> [TrafficCategory] {
        guard count > 0 else { return [] }
        let eligible = active.filter(\.spawnsOnRadarInitially)
        guard !eligible.isEmpty else { return Array(repeating: .arrival, count: count) }

        return zip(eligible, split(total: count, among: eligible))
            .flatMap { Array(repeating: $0.0, count: $0.1) }
    }
}
