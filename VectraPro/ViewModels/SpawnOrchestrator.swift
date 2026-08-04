//
//  SpawnOrchestrator.swift
//  VectraPro
//
//  Decides *when* and *what* to spawn — not how to build it or where to put it.
//
//  This owns the spawn policy and the two schedules (hangar frequency + radar
//  promotion) that the map used to hold inline. It is deliberately a decision
//  engine, not a second view model: it never touches `AircraftSpawner`, never
//  sees a `SpawnContext`, and never holds an aircraft. It answers questions —
//  "which categories are due?", "promote now, and consuming which hangar slot?"
//  — and MapViewModel owns the published collections and makes the aircraft.
//
//  Keeping it here means a future spawning policy can change behind these same
//  intention-revealing calls without the map changing at all.
//

import Foundation
import ATCSimKit
import ATCTrafficKit

/// A decision to move one aircraft onto the radar.
struct RadarPromotion {
    /// The category of the aircraft to place on the radar.
    let category: FlightCategory
    /// The hangar aircraft this promotion consumes, or `nil` to spawn a fresh one.
    let vacatedHangarID: UUID?
}

final class SpawnOrchestrator {

    // MARK: - Configuration (from the exercise)

    private var freqDeparture: ExerciseDetail.FrequencyOfDeparture?
    private var freqArrival: ExerciseDetail.FrequencyOfArrival?
    private var freqEnroute: ExerciseDetail.FrequencyOfEnroute?

    private var isMultiMode = false
    private var airspaceCapacity = 1
    private var aircraftSpawningCount = 1

    // MARK: - Scheduling state (ATCTrafficKit owns the rules)

    private var schedule: TrafficSchedule?
    private var promotion = RadarPromotionSchedule()

    // The app target is @MainActor by default, so an implicit deinit here would be
    // isolated — and the runtime hops an isolated deinit onto the main executor,
    // which aborts the process. MapViewModel *uniquely* owns this collaborator (its
    // other collaborators are shared singletons that are never released), so
    // releasing a MapViewModel fires this deinit for real. Declaring it nonisolated
    // keeps the release off that path. Guarded by IsolatedDeinitScanTests.
    nonisolated deinit {}

    // MARK: - Lifecycle

    /// Take the spawn configuration from a started exercise.
    func configure(from detail: ExerciseDetail) {
        freqDeparture = detail.frequencyOfDeparture
        freqArrival = detail.frequencyOfArrival
        freqEnroute = detail.frequencyOfEnroute
        isMultiMode = detail.isMultiMode ?? false
        airspaceCapacity = detail.airspaceCapacity ?? 1
        aircraftSpawningCount = detail.aircraftSpawningCount ?? 1
    }

    /// Wipe all spawn state when leaving the radar screen.
    func clear() {
        freqDeparture = nil
        freqArrival = nil
        freqEnroute = nil
        isMultiMode = false
        airspaceCapacity = 1
        aircraftSpawningCount = 1
        schedule = nil
        promotion = RadarPromotionSchedule()
    }

    /// Rebuild the traffic schedule for a fresh run and return the categories to
    /// seed the hangar with (one departure, if departures are active) so the
    /// controller always has something to clear for takeoff. The caller makes the
    /// aircraft. Also resets the radar-promotion schedule.
    func beginTraffic() -> [FlightCategory] {
        schedule = TrafficSchedule(configuration: .init(
            frequencies: configuredFrequencies,
            airspaceCapacity: airspaceCapacity))
        promotion = RadarPromotionSchedule()

        var seed: [FlightCategory] = []
        if schedule?.isActive(.departure) == true { seed.append(.departure) }
        return seed
    }

    // MARK: - Policy (pure)

    /// How many aircraft to place on the radar at start.
    ///  • single mode → 1
    ///  • multi mode  → aircraftSpawningCount, capped at airspaceCapacity
    func initialSpawnCount() -> Int {
        guard isMultiMode else { return 1 }
        let capacity = max(airspaceCapacity, 0)
        let requested = max(aircraftSpawningCount, 0)
        return max(1, min(requested, capacity))
    }

    /// Categories for the initially-spawned (on-map) aircraft. Only Arrival &
    /// Enroute spawn on the radar — Departures leave from the runway, so they
    /// live only in the hangar list.
    func initialRadarCategories() -> [FlightCategory] {
        CapacityPlan.initialRadarCategories(count: initialSpawnCount(),
                                            active: activeCategories())
            .map(\.asFlight)
    }

    /// Whether a category is active (Custom or Random). Drives the hangar-list UI.
    var isArrivalActive:   Bool { frequency(for: .arrival).isActive   }
    var isDepartureActive: Bool { frequency(for: .departure).isActive }
    var isEnrouteActive:   Bool { frequency(for: .enroute).isActive   }

    // MARK: - Per-tick decisions

    /// Advance the hangar frequency schedule and return the categories whose
    /// interval elapsed this step. The caller adds them to the hangar.
    func dueHangarSpawns(by dt: Double, listCount: Int) -> [FlightCategory] {
        guard var schedule else { return [] }
        let categories = schedule.advance(by: dt, currentCount: listCount)
        self.schedule = schedule
        return categories.map(\.asFlight)
    }

    /// Advance the radar-promotion schedule. When a promotion is due, decide which
    /// hangar aircraft (if any) it consumes and which category to place on the
    /// radar. Reading the hangar is how an existing aircraft is preferred over a
    /// fresh spawn; the hangar is immutable input — the caller does the removal.
    func radarPromotion(by dt: Double, radarCount: Int, hangar: [Aircraft]) -> RadarPromotion? {
        guard promotion.advance(by: dt, radarCount: radarCount, capacity: airspaceCapacity) else {
            return nil
        }
        let eligible = hangar.filter {
            $0.holdingName == nil && ($0.category == .arrival || $0.category == .enroute)
        }
        if let chosen = eligible.randomElement() {
            return RadarPromotion(category: chosen.category, vacatedHangarID: chosen.id)
        }
        return RadarPromotion(category: Bool.random() ? .arrival : .enroute, vacatedHangarID: nil)
    }

    /// Arm a short-delay promotion so a freed radar slot refills promptly. Called
    /// after anything that can drop the radar below capacity (start, a hold
    /// capture, a destruction). Intention over mechanism: the policy decides how
    /// "maintaining capacity" is achieved.
    func maintainCapacity(radarCount: Int) {
        if radarCount < airspaceCapacity { promotion.hurry() }
    }

    // MARK: - Frequency reading (the only place the backend payload is read)

    private func frequency(for category: TrafficCategory) -> SpawnFrequency {
        switch category {
        case .arrival:
            return SpawnFrequency(type: freqArrival?.type,
                                  flights: freqArrival?.arrivalFlights,
                                  minutes: freqArrival?.arrivalFlightsTimeValue)
        case .departure:
            return SpawnFrequency(type: freqDeparture?.type,
                                  flights: freqDeparture?.departureFlights,
                                  minutes: freqDeparture?.departureFlightsTimeValue)
        case .enroute:
            return SpawnFrequency(type: freqEnroute?.type,
                                  flights: freqEnroute?.enrouteFlights,
                                  minutes: freqEnroute?.enrouteFlightsTimeValue)
        }
    }

    private var configuredFrequencies: [TrafficCategory: SpawnFrequency] {
        Dictionary(uniqueKeysWithValues: TrafficCategory.allCases.map {
            ($0, frequency(for: $0))
        })
    }

    /// Active categories in priority order (arrival → departure → enroute).
    private func activeCategories() -> [TrafficCategory] {
        TrafficCategory.inPriorityOrder.filter { frequency(for: $0).isActive }
    }
}
