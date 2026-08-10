//
//  ATCTrafficFFI.swift
//  ATCTrafficKit
//
//  Minimal C ABI over traffic scheduling, for consumers that call across a C
//  boundary (Unity via P/Invoke, React Native through a thin native module).
//
//  A schedule carries state between ticks, so unlike the parser's single pure call
//  this exposes a handle: create, step, release. Handles are opaque integers rather
//  than pointers, which is what keeps the surface usable from C# and JavaScript
//  without either side owning Swift memory.
//
//  Everything crossing the boundary is JSON; strings are caller-frees.
//

import Foundation
import ATCTrafficKit

// MARK: - Handle registry

/// Live schedules, keyed by the handle handed to the caller.
///
/// Serialised with a lock because a game engine may well step the simulation from
/// a thread of its own choosing.
private final class ScheduleRegistry {
    static let shared = ScheduleRegistry()

    private let lock = NSLock()
    private var schedules: [Int32: TrafficSchedule] = [:]
    private var promotions: [Int32: RadarPromotionSchedule] = [:]
    private var nextHandle: Int32 = 1

    func create(_ schedule: TrafficSchedule) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        let handle = nextHandle
        nextHandle += 1
        schedules[handle] = schedule
        promotions[handle] = RadarPromotionSchedule()
        return handle
    }

    func step(_ handle: Int32,
              elapsed: TimeInterval,
              currentCount: Int,
              radarCount: Int) -> (spawn: [TrafficCategory], promote: Bool)? {
        lock.lock(); defer { lock.unlock() }
        guard var schedule = schedules[handle], var promotion = promotions[handle] else {
            return nil
        }
        let spawn = schedule.advance(by: elapsed, currentCount: currentCount)
        let promote = promotion.advance(by: elapsed,
                                       radarCount: radarCount,
                                       capacity: schedule.configuration.airspaceCapacity)
        schedules[handle] = schedule
        promotions[handle] = promotion
        return (spawn, promote)
    }

    func release(_ handle: Int32) {
        lock.lock(); defer { lock.unlock() }
        schedules[handle] = nil
        promotions[handle] = nil
    }
}

// MARK: - Wire model

/// Input accepted by `atc_traffic_create`.
private struct CreateRequest: Decodable {
    struct Frequency: Decodable {
        let type: String?
        let flights: Int?
        let minutes: Int?
    }
    let capacity: Int
    let frequencies: [String: Frequency]
    let randomIntervals: [TimeInterval]?
}

private struct StepResponse: Encodable {
    let spawn: [String]
    let promote: Bool
}

// MARK: - C interface

/// Creates a schedule from a JSON configuration and returns its handle.
/// Returns 0 when the configuration cannot be read.
///
/// ```json
/// { "capacity": 10,
///   "frequencies": { "arrival": { "type": "custom", "flights": 6, "minutes": 30 },
///                    "departure": { "type": "random" } } }
/// ```
@_cdecl("atc_traffic_create")
func atc_traffic_create(_ configuration: UnsafePointer<CChar>?) -> Int32 {
    guard let configuration,
          let data = String(cString: configuration).data(using: .utf8),
          let request = try? JSONDecoder().decode(CreateRequest.self, from: data)
    else { return 0 }

    var frequencies: [TrafficCategory: SpawnFrequency] = [:]
    for (name, frequency) in request.frequencies {
        guard let category = TrafficCategory(rawValue: name.lowercased()) else { continue }
        frequencies[category] = SpawnFrequency(type: frequency.type,
                                               flights: frequency.flights,
                                               minutes: frequency.minutes)
    }

    let config = TrafficSchedule.Configuration(
        frequencies: frequencies,
        airspaceCapacity: request.capacity,
        randomIntervals: request.randomIntervals ?? [15, 20, 30, 45, 60, 90])

    return ScheduleRegistry.shared.create(TrafficSchedule(configuration: config))
}

/// Advances a schedule and returns what to do, as a JSON C string.
///
/// The pointer is heap-allocated and MUST be released with `atc_traffic_free`.
/// An unknown handle yields an error envelope rather than NULL.
@_cdecl("atc_traffic_step")
func atc_traffic_step(_ handle: Int32,
                      _ elapsedSeconds: Double,
                      _ currentCount: Int32,
                      _ radarCount: Int32) -> UnsafeMutablePointer<CChar>? {
    guard let result = ScheduleRegistry.shared.step(handle,
                                                    elapsed: elapsedSeconds,
                                                    currentCount: Int(currentCount),
                                                    radarCount: Int(radarCount)) else {
        return strdup(#"{"error":"unknown_handle"}"#)
    }
    let response = StepResponse(spawn: result.spawn.map(\.rawValue), promote: result.promote)
    guard let data = try? JSONEncoder().encode(response),
          let json = String(data: data, encoding: .utf8) else {
        return strdup(#"{"error":"encode_failed"}"#)
    }
    return strdup(json)
}

/// Splits a capacity across categories, as a JSON C string. Stateless.
@_cdecl("atc_traffic_capacity_split")
func atc_traffic_capacity_split(_ total: Int32,
                                _ categories: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    let names = categories.map { String(cString: $0) }?
        .split(separator: ",")
        .compactMap { TrafficCategory(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
        ?? []
    let quotas = CapacityPlan.quotas(total: Int(total), among: names)
    let wire = Dictionary(quotas.map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: { a, _ in a })

    guard let data = try? JSONEncoder().encode(wire),
          let json = String(data: data, encoding: .utf8) else {
        return strdup(#"{"error":"encode_failed"}"#)
    }
    return strdup(json)
}

/// Releases a schedule. Safe to call more than once.
@_cdecl("atc_traffic_release")
func atc_traffic_release(_ handle: Int32) {
    ScheduleRegistry.shared.release(handle)
}

/// Frees a string previously returned by this module.
@_cdecl("atc_traffic_free")
func atc_traffic_free(_ pointer: UnsafeMutablePointer<CChar>?) {
    free(pointer)
}
