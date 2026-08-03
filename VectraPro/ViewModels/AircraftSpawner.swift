//
//  AircraftSpawner.swift
//  VectraPro
//
//  Aircraft factory: spawns radar targets and hangar-list traffic.
//  Owns callsign generation and zone-avoidance logic.
//
//  Every random choice is drawn from a caller-supplied `SeededGenerator` rather than the system
//  generator, so the same exercise spawns the same traffic twice. The generator comes in as
//  `inout` — the draw advances it, and that advance has to be visible to the caller, since the
//  caller is what holds the simulation's random state.
//

import CoreLocation
import ATCSimKit
import GeoNavKit
import Foundation

// MARK: - Spawn context

/// All data the spawner needs to create an aircraft — avoids a long parameter list.
struct SpawnContext {
    let center:             CLLocationCoordinate2D
    let zoneShapes:         [ZoneShape]
    let fixes:              [ExerciseDetail.Fix]
    let airlines:           [ExerciseDetail.Airline]
    let aircraftTypes:      [ExerciseDetail.AircraftType]
    let runways:            [Runway]
    let historySampleTicks: Int
    let tickInterval:       Double
}

// MARK: - Spawner

final class AircraftSpawner {

    static let shared = AircraftSpawner()

    /// Not private: the spawner carries mutable state — the shuffled radial cycle and its index —
    /// so two simulations sharing one instance would draw from each other's cycle. A test that
    /// compares two runs needs a spawner each, and eventually so will two live sessions.
    init() {}

    /// The app target defaults to `MainActor` isolation, which makes an implicit deinit isolated
    /// too, and releasing an isolated deinit off the main actor aborts the process. It never showed
    /// before because this was only ever the shared singleton, which is never released. See
    /// `IsolatedDeinitScanTests`.
    nonisolated deinit { }

    // MARK: - Radial cycle (round-robin for arrival spawns)

    private typealias Radial = (origin: CLLocationCoordinate2D, angle: Double, lengthMeters: Double)

    /// Shuffled list of all VOR radials for the active exercise.
    private var radialCycle: [Radial] = []
    private var radialCycleIndex = 0

    /// Build and shuffle the radial list from the exercise fixes.
    /// Call this once at `reset()` so every exercise gets a fresh, consistent order.
    func resetRadialCycle(fixes: [ExerciseDetail.Fix], rng: inout SeededGenerator) {
        radialCycle = rng.shuffle(buildRadialList(fixes: fixes))
        radialCycleIndex = 0
    }

    /// Next radial in round-robin order; nil when the cycle is empty.
    private func nextCycledRadial() -> Radial? {
        guard !radialCycle.isEmpty else { return nil }
        let radial = radialCycle[radialCycleIndex % radialCycle.count]
        radialCycleIndex += 1
        return radial
    }

    // MARK: - Public: spawn

    /// Minimum separation between spawn points (radial or random).
    private let minSpawnSeparationM = 15.0 * Distance.metersPerNauticalMile

    /// Spawns a radar aircraft outside the 60–63 NM radius, heading roughly inbound.
    /// `existing` = positions of aircraft already on the radar; the spawn point is
    /// kept at least 15 NM from all of them (and outside every zone).
    func makeRandomAircraft(context: SpawnContext,
                            category: FlightCategory = .arrival,
                            existing: [CLLocationCoordinate2D] = [],
                            rng: inout SeededGenerator) -> Aircraft {
        var position = context.center
        var heading  = 0.0

        // Retry up to 20 times to find a spawn point clear of zones and traffic.
        for _ in 0..<20 {
            let candidate: CLLocationCoordinate2D
            let candidateHeading: Double

            if category == .arrival,
               let radial = nextCycledRadial() ?? randomVORRadial(fixes: context.fixes, rng: &rng) {
                let spawnDistance = min(63 * Distance.metersPerNauticalMile, radial.lengthMeters)
                candidate = Geo.offset(from: radial.origin,
                                       distanceMeters: spawnDistance,
                                       bearingDegrees: radial.angle)
                candidateHeading = Geo.bearing(from: candidate, to: context.center)
            } else {
                let spawnBearing = rng.double(in: 0..<360)
                let rangeNM = rng.double(in: 60..<63)
                candidate = Geo.offset(from: context.center,
                                       distanceMeters: rangeNM * Distance.metersPerNauticalMile,
                                       bearingDegrees: spawnBearing)
                let inbound = (spawnBearing + 180).truncatingRemainder(dividingBy: 360)
                candidateHeading = (inbound + rng.double(in: -40...40) + 360)
                    .truncatingRemainder(dividingBy: 360)
            }

            position = candidate
            heading  = candidateHeading
            let clearOfZones   = !isInsideAnyZone(candidate, zoneShapes: context.zoneShapes)
            let clearOfTraffic = existing.allSatisfy {
                Geo.distanceMeters(from: candidate, to: $0) >= minSpawnSeparationM
            }
            if clearOfZones && clearOfTraffic { break }
        }

        var ac = Aircraft(callsign: callsign(airlines: context.airlines, rng: &rng),
                          position: position,
                          headingDegrees: heading)
        ac.category = category
        ac.aircraftType = rng.pick(context.aircraftTypes)?.icaoCode
        ac.squawk = randomSquawk(rng: &rng)

        // Pre-populate 6 history dots so the trail is visible immediately at spawn.
        // Dot spacing = TAS × sampleInterval (distance between consecutive history samples).
        let sampleDistMeters = ac.speedKnots * 1852.0 / 3600.0
                               * Double(context.historySampleTicks) * context.tickInterval
        let backBearing = (heading + 180).truncatingRemainder(dividingBy: 360)
        for i in stride(from: 6, through: 1, by: -1) {
            ac.history.append(
                Geo.offset(from: position,
                           distanceMeters: Double(i) * sampleDistMeters,
                           bearingDegrees: backBearing)
            )
        }
        return ac
    }

    /// Creates a hangar-list aircraft (not drawn on the map).
    func makeListAircraft(context: SpawnContext,
                          category: FlightCategory,
                          rng: inout SeededGenerator) -> Aircraft {
        var ac = Aircraft(callsign: Self.randomCallsign(rng: &rng),
                          position: context.center,
                          headingDegrees: 0)
        ac.category = category
        ac.altitudeFeet = Double(rng.int(in: 80...350)) * 100   // FL080–FL350
        ac.speedKnots   = Double(rng.int(in: 180...450))
        if let runway = rng.pick(context.runways) {
            ac.assignedRunway = rng.bool() ? runway.endA.designator : runway.endB.designator
        }
        return ac
    }

    // MARK: - Public: callsigns

    /// Callsign from exercise airlines (ICAO + flight number), or built-in fallback.
    func callsign(airlines: [ExerciseDetail.Airline], rng: inout SeededGenerator) -> String {
        let codes = airlines.compactMap(\.icaoCode).filter { !$0.isEmpty }
        if let code = rng.pick(codes) {
            return code + String(rng.int(in: 100...999))
        }
        return Self.randomCallsign(rng: &rng)
    }

    static func randomCallsign(rng: inout SeededGenerator) -> String {
        let carriers = ["ACA", "AIC", "IGO", "VTI", "UAE", "SIA"]
        return (rng.pick(carriers) ?? "ACA") + String(rng.int(in: 10...99))
    }

    // MARK: - Private

    private func randomSquawk(rng: inout SeededGenerator) -> String {
        // Built digit by digit rather than with map, so the draws happen in a defined order —
        // `map` over a range is sequential today but nothing in its contract promises that, and a
        // reordering here would silently change every saved simulation.
        var digits = ""
        for _ in 0..<4 { digits += String(rng.int(in: 0...7)) }
        return digits
    }

    private func isInsideAnyZone(_ point: CLLocationCoordinate2D, zoneShapes: [ZoneShape]) -> Bool {
        zoneShapes.contains { polygonContains($0.coordinates, point: point) }
    }

    /// All VOR radials from the given fixes, in declaration order.
    private func buildRadialList(fixes: [ExerciseDetail.Fix]) -> [Radial] {
        var list: [Radial] = []
        for fix in fixes where fix.type?.uppercased() == "VOR" {
            guard let lat = fix.latitude, let lon = fix.longitude, let radials = fix.radials else { continue }
            let origin = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            for r in radials {
                guard let angle = r.angle, let distNM = r.distance, distNM > 0 else { continue }
                // FixRadialRenderer draws each radial at 3× its reported distance.
                list.append((origin, angle, distNM * 3 * Distance.metersPerNauticalMile))
            }
        }
        return list
    }

    /// Random radial pick — fallback when the cycle is empty (e.g. no fixes loaded yet).
    private func randomVORRadial(fixes: [ExerciseDetail.Fix],
                                 rng: inout SeededGenerator) -> Radial? {
        rng.pick(buildRadialList(fixes: fixes))
    }

    private func polygonContains(_ polygon: [CLLocationCoordinate2D],
                                  point: CLLocationCoordinate2D) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude, yi = polygon[i].latitude
            let xj = polygon[j].longitude, yj = polygon[j].latitude
            let crossesY = (yi > point.latitude) != (yj > point.latitude)
            let xIntersect = (xj - xi) * (point.latitude - yi) / (yj - yi) + xi
            if crossesY && point.longitude < xIntersect { inside = !inside }
            j = i
        }
        return inside
    }
}
