//
//  ATCTrafficKitTests.swift
//  ATCTrafficKit
//
//  Scheduling had no tests at all while it lived inside the view model — it needed
//  a running exercise to exercise it. The two that matter most here are
//  `testAFullAirspacePausesSpawningRatherThanEndingIt`, which pins the bug this
//  extraction fixed, and `testSharesAlwaysSumToTheCapacity`, because a plan that
//  quietly under-fills is invisible for a whole exercise.
//

import XCTest
@testable import ATCTrafficKit

final class CapacityPlanTests: XCTestCase {

    func testWeightsApplyWhenEveryCategoryIsOn() {
        XCTAssertEqual(CapacityPlan.split(total: 10, among: TrafficCategory.inPriorityOrder),
                       [4, 3, 3])
    }

    func testWeightsAreRenormalisedOverActiveCategoriesOnly() {
        // Arrival alone gets the whole capacity, not 40% of it.
        XCTAssertEqual(CapacityPlan.split(total: 10, among: [.arrival]), [10])
        // 40:30 between two — 6 and 4, not 4 and 3.
        XCTAssertEqual(CapacityPlan.split(total: 10, among: [.arrival, .departure]), [6, 4])
    }

    func testSharesAlwaysSumToTheCapacity() {
        for total in 0...50 {
            for categories in [[TrafficCategory.arrival],
                               [.arrival, .departure],
                               [.departure, .enroute],
                               TrafficCategory.inPriorityOrder] {
                let split = CapacityPlan.split(total: total, among: categories)
                XCTAssertEqual(split.reduce(0, +), total,
                               "total \(total) across \(categories.map(\.rawValue))")
            }
        }
    }

    func testNoCapacityOrNoCategoriesPlansNothing() {
        XCTAssertEqual(CapacityPlan.split(total: 0, among: TrafficCategory.inPriorityOrder),
                       [0, 0, 0])
        XCTAssertEqual(CapacityPlan.split(total: 10, among: []), [])
    }

    func testInitialRadarCategoriesLeaveDeparturesInTheHangar() {
        let initial = CapacityPlan.initialRadarCategories(
            count: 4, active: TrafficCategory.inPriorityOrder)
        XCTAssertEqual(initial.count, 4)
        XCTAssertFalse(initial.contains(.departure),
                       "a departure starts on the runway, not on the radar")
    }

    func testADepartureOnlyExerciseStillOpensWithSomethingOnTheRadar() {
        // Nothing else is eligible, so the batch falls back to arrivals rather than
        // the exercise starting on an empty screen.
        XCTAssertEqual(CapacityPlan.initialRadarCategories(count: 2, active: [.departure]),
                       [.arrival, .arrival])
    }
}

final class SpawnFrequencyTests: XCTestCase {

    func testCustomRateBecomesAnInterval() {
        // Six flights over thirty minutes is one every five.
        XCTAssertEqual(SpawnFrequency.custom(flights: 6, minutes: 30).fixedInterval, 300)
    }

    func testAMisconfiguredRateProducesNoTrafficRatherThanAFlood() {
        XCTAssertNil(SpawnFrequency.custom(flights: 0, minutes: 30).fixedInterval)
        XCTAssertNil(SpawnFrequency.custom(flights: 6, minutes: 0).fixedInterval)
        XCTAssertFalse(SpawnFrequency.custom(flights: 0, minutes: 0).isActive)
    }

    func testUnknownOrMissingTypeMeansOff() {
        XCTAssertEqual(SpawnFrequency(type: nil, flights: 6, minutes: 30), .none)
        XCTAssertEqual(SpawnFrequency(type: "None", flights: nil, minutes: nil), .none)
        XCTAssertEqual(SpawnFrequency(type: "whatever", flights: 6, minutes: 30), .none)
    }

    func testBackendStringsAreAccepted() {
        XCTAssertEqual(SpawnFrequency(type: "custom", flights: 6, minutes: 30),
                       .custom(flights: 6, minutes: 30))
        XCTAssertEqual(SpawnFrequency(type: "RANDOM", flights: nil, minutes: nil), .random)
    }
}

final class TrafficScheduleTests: XCTestCase {

    /// A generator these tests barely use — `.fixed` intervals ignore it — but the schedule now
    /// takes one, because it must draw from the caller's sequence rather than the system's.
    private var rng = SeededGenerator(seed: 1)

    override func setUp() {
        super.setUp()
        rng = SeededGenerator(seed: 1)
    }

    private func schedule(capacity: Int = 10,
                          frequencies: [TrafficCategory: SpawnFrequency],
                          interval: TimeInterval = 30) -> TrafficSchedule {
        TrafficSchedule(
            configuration: .init(frequencies: frequencies,
                                 airspaceCapacity: capacity,
                                 randomIntervals: [interval]),
            intervals: .fixed(interval),
            using: &rng)
    }

    /// Steps a schedule one second at a time, holding the aircraft count fixed.
    private func run(_ schedule: inout TrafficSchedule,
                     seconds: Int,
                     currentCount: Int = 0) -> [TrafficCategory] {
        var spawned: [TrafficCategory] = []
        for _ in 0..<seconds {
            spawned += schedule.advance(by: 1, currentCount: currentCount + spawned.count,
                                        using: &rng)
        }
        return spawned
    }

    // MARK: Activation

    func testOnlyConfiguredCategoriesProduceTraffic() {
        let schedule = schedule(frequencies: [.arrival: .custom(flights: 6, minutes: 30),
                                              .departure: .none])
        XCTAssertEqual(schedule.activeCategories, [.arrival])
        XCTAssertFalse(schedule.isActive(.departure))
    }

    func testCategoriesComeOutInPriorityOrder() {
        let schedule = schedule(frequencies: [.enroute: .random,
                                              .arrival: .random,
                                              .departure: .random])
        XCTAssertEqual(schedule.activeCategories, [.arrival, .departure, .enroute])
    }

    func testAMisconfiguredCategoryIsNotScheduled() {
        let schedule = schedule(frequencies: [.arrival: .custom(flights: 0, minutes: 0)])
        XCTAssertTrue(schedule.activeCategories.isEmpty)
    }

    // MARK: Rate

    func testTrafficArrivesAtTheConfiguredInterval() {
        var schedule = schedule(frequencies: [.arrival: .custom(flights: 6, minutes: 1)],
                                interval: 10)
        // Six flights a minute is one every ten seconds.
        XCTAssertEqual(run(&schedule, seconds: 9).count, 0)
        XCTAssertEqual(run(&schedule, seconds: 1), [.arrival])
    }

    func testNothingArrivesBeforeTheFirstIntervalElapses() {
        var schedule = schedule(frequencies: [.arrival: .random], interval: 30)
        XCTAssertTrue(run(&schedule, seconds: 29).isEmpty)
    }

    // MARK: Quota

    func testACategoryStopsForGoodOnceItsQuotaIsSpent() {
        // Arrival alone, capacity 3 → quota 3.
        var schedule = schedule(capacity: 3,
                                frequencies: [.arrival: .random],
                                interval: 10)
        // Count held at zero so capacity never intervenes.
        let spawned = run(&schedule, seconds: 200, currentCount: -3)
        XCTAssertEqual(spawned.count, 3, "the quota is a hard total")
        XCTAssertFalse(schedule.hasTrafficRemaining)
    }

    func testQuotasFollowTheCapacitySplit() {
        let schedule = schedule(capacity: 10,
                                frequencies: [.arrival: .random,
                                              .departure: .random,
                                              .enroute: .random])
        XCTAssertEqual(schedule.remainingByCategory,
                       [.arrival: 4, .departure: 3, .enroute: 3])
    }

    // MARK: Capacity — the behaviour this extraction fixed

    func testAFullAirspacePausesSpawningRatherThanEndingIt() {
        var schedule = schedule(capacity: 5,
                                frequencies: [.arrival: .random],
                                interval: 10)

        // Airspace full: the interval passes several times over and nothing spawns.
        for _ in 0..<50 {
            XCTAssertTrue(schedule.advance(by: 1, currentCount: 5, using: &rng).isEmpty)
        }
        XCTAssertTrue(schedule.hasTrafficRemaining, "still owed — it was only blocked")

        // An aircraft leaves. The previous version had switched the spawner off
        // permanently by now; it must resume on the very next tick.
        XCTAssertEqual(schedule.advance(by: 1, currentCount: 4, using: &rng), [.arrival])
    }

    func testCapacityCountsAircraftSpawnedWithinTheSameTick() {
        // Three categories all due at once, one seat left — only one gets it.
        var schedule = schedule(capacity: 10,
                                frequencies: [.arrival: .random,
                                              .departure: .random,
                                              .enroute: .random],
                                interval: 10)
        XCTAssertEqual(schedule.advance(by: 10, currentCount: 9, using: &rng).count, 1)
    }

    func testCapacityIsNotExceededOverALongRun() {
        var schedule = schedule(capacity: 6,
                                frequencies: [.arrival: .random, .departure: .random],
                                interval: 5)
        var count = 0
        for _ in 0..<500 {
            count += schedule.advance(by: 1, currentCount: count, using: &rng).count
            XCTAssertLessThanOrEqual(count, 6)
        }
    }
}

final class RadarPromotionScheduleTests: XCTestCase {

    private var rng = SeededGenerator(seed: 1)

    override func setUp() {
        super.setUp()
        rng = SeededGenerator(seed: 1)
    }

    func testPromotesOnceTheIntervalElapses() {
        var promotion = RadarPromotionSchedule(intervals: [10], chooser: .fixed(10), using: &rng)
        for _ in 0..<9 {
            XCTAssertFalse(promotion.advance(by: 1, radarCount: 0, capacity: 5, using: &rng))
        }
        XCTAssertTrue(promotion.advance(by: 1, radarCount: 0, capacity: 5, using: &rng))
    }

    func testAFullRadarPausesPromotionRatherThanEndingIt() {
        var promotion = RadarPromotionSchedule(intervals: [10], chooser: .fixed(10), using: &rng)
        for _ in 0..<50 {
            XCTAssertFalse(promotion.advance(by: 1, radarCount: 5, capacity: 5, using: &rng))
        }
        // Room appears; promotion must resume rather than having been switched off.
        var promoted = false
        for _ in 0..<11 where !promoted {
            promoted = promotion.advance(by: 1, radarCount: 4, capacity: 5, using: &rng)
        }
        XCTAssertTrue(promoted)
    }

    func testTheIntervalRestartsAfterEachPromotion() {
        var promotion = RadarPromotionSchedule(intervals: [10], chooser: .fixed(10), using: &rng)
        XCTAssertTrue(promotion.advance(by: 10, radarCount: 0, capacity: 5, using: &rng))
        XCTAssertFalse(promotion.advance(by: 9, radarCount: 0, capacity: 5, using: &rng))
        XCTAssertTrue(promotion.advance(by: 1, radarCount: 0, capacity: 5, using: &rng))
    }
}
