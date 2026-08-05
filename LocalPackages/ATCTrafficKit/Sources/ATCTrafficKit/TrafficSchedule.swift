//
//  TrafficSchedule.swift
//  ATCTrafficKit
//
//  Decides when the next aircraft appears, and of which kind.
//
//  Only the decision lives here. Creating an aircraft needs a position, a callsign
//  and a type, which needs geometry and therefore platform code; scheduling needs
//  counts, intervals and quotas and nothing else. Separating the two is what lets
//  this run on a platform that has no CoreLocation.
//
//  ── Capacity pauses, it does not stop ───────────────────────────────────────
//  When the airspace is full a spawner waits and tries again. The version this
//  replaces set its countdown to infinity, which permanently disabled it: capacity
//  is a moving figure — aircraft land and leave — so the first busy moment of an
//  exercise silently ended all further traffic for that category, with nothing
//  reporting it. A quota running out is different, and does stop the spawner for
//  good; that is what a quota means.
//
//  ── Randomness is injected ─────────────────────────────────────────────────
//  Interval choices come in through `IntervalChooser` rather than being drawn
//  inside, so a schedule can be stepped through deterministically in a test. The
//  production default still picks at random.
//

import Foundation

// MARK: - Interval choice

public struct IntervalChooser: Sendable {

    private let choose: @Sendable ([TimeInterval]) -> TimeInterval

    public init(_ choose: @escaping @Sendable ([TimeInterval]) -> TimeInterval) {
        self.choose = choose
    }

    func pick(from options: [TimeInterval]) -> TimeInterval {
        choose(options)
    }

    /// Production behaviour: an irregular rate.
    public static let random = IntervalChooser { $0.randomElement() ?? 30 }

    /// A fixed interval, for tests that need to know when the next one is due.
    public static func fixed(_ interval: TimeInterval) -> IntervalChooser {
        IntervalChooser { _ in interval }
    }

    /// Always the shortest option — useful for exercising quota exhaustion quickly.
    public static let shortest = IntervalChooser { $0.min() ?? 30 }
}

// MARK: - Schedule

public struct TrafficSchedule: Sendable {

    public struct Configuration: Equatable, Sendable {
        /// How each category produces traffic. Absent means off.
        public var frequencies: [TrafficCategory: SpawnFrequency]
        /// Most aircraft the airspace holds at once, radar and hangar together.
        public var airspaceCapacity: Int
        /// Interval choices for `.random` categories.
        public var randomIntervals: [TimeInterval]

        public init(frequencies: [TrafficCategory: SpawnFrequency],
                    airspaceCapacity: Int,
                    randomIntervals: [TimeInterval] = [15, 20, 30, 45, 60, 90]) {
            self.frequencies = frequencies
            self.airspaceCapacity = airspaceCapacity
            self.randomIntervals = randomIntervals
        }
    }

    private struct Spawner {
        let category: TrafficCategory
        /// Fixed rate, or nil when this category picks a new interval each time.
        let fixedInterval: TimeInterval?
        var remaining: Int
        var countdown: TimeInterval
    }

    public let configuration: Configuration
    private let chooser: IntervalChooser
    private var spawners: [Spawner]

    public init(configuration: Configuration, intervals: IntervalChooser = .random) {
        self.configuration = configuration
        self.chooser = intervals

        // Quotas follow the weighted split across whichever categories are on, so
        // the totals cannot exceed the airspace capacity however many are enabled.
        let active = TrafficCategory.inPriorityOrder.filter {
            configuration.frequencies[$0]?.isActive == true
        }
        let quotas = CapacityPlan.quotas(total: configuration.airspaceCapacity, among: active)

        self.spawners = active.compactMap { category in
            guard let quota = quotas[category], quota > 0,
                  let frequency = configuration.frequencies[category] else { return nil }

            let fixed = frequency.fixedInterval
            let first = fixed ?? intervals.pick(from: configuration.randomIntervals)
            return Spawner(category: category,
                           fixedInterval: fixed,
                           remaining: quota,
                           countdown: first)
        }
    }

    // MARK: Queries

    /// Categories that will produce traffic — those configured on and given a quota.
    public var activeCategories: [TrafficCategory] { spawners.map(\.category) }

    public func isActive(_ category: TrafficCategory) -> Bool {
        spawners.contains { $0.category == category }
    }

    /// Aircraft still to come, per category.
    public var remainingByCategory: [TrafficCategory: Int] {
        Dictionary(spawners.map { ($0.category, $0.remaining) }, uniquingKeysWith: +)
    }

    public var hasTrafficRemaining: Bool { spawners.contains { $0.remaining > 0 } }

    // MARK: Stepping

    /// Advances the schedule and returns the categories to spawn now.
    ///
    /// `currentCount` is every aircraft already in the exercise, radar and hangar
    /// together, so the capacity ceiling counts what is actually there rather than
    /// what this schedule produced.
    public mutating func advance(by elapsed: TimeInterval,
                                 currentCount: Int) -> [TrafficCategory] {
        var spawned: [TrafficCategory] = []

        for index in spawners.indices {
            guard spawners[index].remaining > 0 else { continue }   // quota done, for good

            spawners[index].countdown -= elapsed
            guard spawners[index].countdown <= 0 else { continue }

            guard currentCount + spawned.count < configuration.airspaceCapacity else {
                // Full for now. Hold at zero so the next tick tries again rather
                // than the spawner being switched off permanently.
                spawners[index].countdown = 0
                continue
            }

            spawned.append(spawners[index].category)
            spawners[index].remaining -= 1
            spawners[index].countdown = nextInterval(after: spawners[index])
        }
        return spawned
    }

    private func nextInterval(after spawner: Spawner) -> TimeInterval {
        guard spawner.remaining > 0 else { return .infinity }   // nothing further due
        if let fixed = spawner.fixedInterval { return fixed }
        return chooser.pick(from: configuration.randomIntervals)
    }
}

// MARK: - Radar promotion

/// Moves aircraft from the hangar onto the radar as room appears.
///
/// Separate from `TrafficSchedule` because it answers a different question: not
/// "should new traffic exist" but "should traffic that already exists become
/// visible". It pauses on a full radar for the same reason, and for the same
/// reason it previously did not.
public struct RadarPromotionSchedule: Sendable {

    public let intervals: [TimeInterval]
    private let chooser: IntervalChooser
    private var countdown: TimeInterval

    public init(intervals: [TimeInterval] = [15, 20, 30, 45, 60, 90],
                chooser: IntervalChooser = .random) {
        self.intervals = intervals
        self.chooser = chooser
        self.countdown = chooser.pick(from: intervals)
    }

    /// Brings the next promotion forward, for when a radar slot has just freed up.
    ///
    /// A vacancy should refill promptly rather than waiting out an interval that
    /// was timed against a full screen, so the wait is cut to one of the shorter
    /// choices — and only ever shortened, never extended.
    public mutating func hurry() {
        let shortest = intervals.sorted().prefix(3)
        let target = chooser.pick(from: Array(shortest))
        countdown = min(countdown, target)
    }

    /// True when an aircraft should be promoted now.
    public mutating func advance(by elapsed: TimeInterval,
                                 radarCount: Int,
                                 capacity: Int) -> Bool {
        guard radarCount < capacity else {
            countdown = max(countdown, 0)   // wait for room, do not switch off
            return false
        }
        countdown -= elapsed
        guard countdown <= 0 else { return false }
        countdown = chooser.pick(from: intervals)
        return true
    }
}
