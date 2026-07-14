//
//  AircraftSpawner.swift
//  VectraPro
//
//  Aircraft factory: spawns radar targets and hangar-list traffic.
//  Owns callsign generation and zone-avoidance logic.
//

import CoreLocation
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
    private init() {}

    // MARK: - Radial cycle (round-robin for arrival spawns)

    private typealias Radial = (origin: CLLocationCoordinate2D, angle: Double, lengthMeters: Double)

    /// Shuffled list of all VOR radials for the active exercise.
    private var radialCycle: [Radial] = []
    private var radialCycleIndex = 0

    /// Build and shuffle the radial list from the exercise fixes.
    /// Call this once at `reset()` so every exercise gets a fresh, consistent order.
    func resetRadialCycle(fixes: [ExerciseDetail.Fix]) {
        radialCycle = buildRadialList(fixes: fixes).shuffled()
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
                            existing: [CLLocationCoordinate2D] = []) -> Aircraft {
        var position = context.center
        var heading  = 0.0

        // Retry up to 20 times to find a spawn point clear of zones and traffic.
        for _ in 0..<20 {
            let candidate: CLLocationCoordinate2D
            let candidateHeading: Double

            if category == .arrival, let radial = nextCycledRadial() ?? randomVORRadial(fixes: context.fixes) {
                let spawnDistance = min(63 * Distance.metersPerNauticalMile, radial.lengthMeters)
                candidate = Geo.offset(from: radial.origin,
                                       distanceMeters: spawnDistance,
                                       bearingDegrees: radial.angle)
                candidateHeading = Geo.bearing(from: candidate, to: context.center)
            } else {
                let spawnBearing = Double.random(in: 0..<360)
                let rangeNM = Double.random(in: 60..<63)
                candidate = Geo.offset(from: context.center,
                                       distanceMeters: rangeNM * Distance.metersPerNauticalMile,
                                       bearingDegrees: spawnBearing)
                let inbound = (spawnBearing + 180).truncatingRemainder(dividingBy: 360)
                candidateHeading = (inbound + Double.random(in: -40...40) + 360)
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

        var ac = Aircraft(callsign: callsign(airlines: context.airlines),
                          position: position,
                          headingDegrees: heading)
        ac.category = category
        ac.aircraftType = context.aircraftTypes.randomElement()?.icaoCode
        ac.squawk = randomSquawk()

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
    func makeListAircraft(context: SpawnContext, category: FlightCategory) -> Aircraft {
        var ac = Aircraft(callsign: Self.randomCallsign(),
                          position: context.center,
                          headingDegrees: 0)
        ac.category = category
        ac.altitudeFeet = Double(Int.random(in: 80...350)) * 100   // FL080–FL350
        ac.speedKnots   = Double(Int.random(in: 180...450))
        if let runway = context.runways.randomElement() {
            ac.assignedRunway = Bool.random() ? runway.endA.designator : runway.endB.designator
        }
        return ac
    }

    // MARK: - Public: callsigns

    /// Callsign from exercise airlines (ICAO + flight number), or built-in fallback.
    func callsign(airlines: [ExerciseDetail.Airline]) -> String {
        if let code = airlines.compactMap({ $0.icaoCode }).filter({ !$0.isEmpty }).randomElement() {
            return code + String(Int.random(in: 100...999))
        }
        return Self.randomCallsign()
    }

    static func randomCallsign() -> String {
        let carriers = ["ACA", "AIC", "IGO", "VTI", "UAE", "SIA"]
        return (carriers.randomElement() ?? "ACA") + String(Int.random(in: 10...99))
    }

    // MARK: - Private

    private func randomSquawk() -> String {
        (0..<4).map { _ in String(Int.random(in: 0...7)) }.joined()
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
    private func randomVORRadial(fixes: [ExerciseDetail.Fix]) -> Radial? {
        buildRadialList(fixes: fixes).randomElement()
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
