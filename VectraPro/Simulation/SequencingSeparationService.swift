//
//  SequencingSeparationService.swift
//  VectraPro
//
//  Landing-sequence separation on final approach, extracted from MapViewModel.
//  Stateless: it reads the aircraft list, runways, and aircraft-type table and
//  returns the set of aircraft that are too close in trail. Wake-turbulence
//  categories drive the required spacing.
//

import Foundation

enum SequencingSeparationService {

    /// Wake category of an aircraft from its type's ICAO WTC (L / M / H).
    static func wakeCategory(_ ac: Aircraft,
                             aircraftTypes: [ExerciseDetail.AircraftType]) -> String {
        guard let code = ac.aircraftType else { return "M" }
        return aircraftTypes.first { $0.icaoCode?.uppercased() == code.uppercased() }?
            .icaoWTC?.uppercased() ?? "M"
    }

    /// Required in-trail separation (NM): 10 if either aircraft is small (Light),
    /// otherwise 8 for medium/heavy.
    static func requiredSeparationNM(_ a: Aircraft, _ b: Aircraft,
                                     aircraftTypes: [ExerciseDetail.AircraftType]) -> Double {
        (wakeCategory(a, aircraftTypes: aircraftTypes) == "L" ||
         wakeCategory(b, aircraftTypes: aircraftTypes) == "L") ? 10 : 8
    }

    /// Aircraft on final (localizer) that are closer than the required separation
    /// to the aircraft ahead of them on the same runway.
    static func conflicts(among aircraft: [Aircraft], runways: [Runway],
                          aircraftTypes: [ExerciseDetail.AircraftType]) -> Set<UUID> {
        var conflicts = Set<UUID>()
        let onFinal = aircraft.filter { $0.interceptRunway != nil }
        let byRunway = Dictionary(grouping: onFinal) { $0.interceptRunway! }

        for (rwy, group) in byRunway {
            guard group.count >= 2,
                  let info = RunwayGeometry.threshold(for: rwy, in: runways) else { continue }
            // Nearest-to-threshold first (the leader of the sequence).
            let sorted = group.sorted {
                Geo.distanceMeters(from: $0.position, to: info.threshold)
                    < Geo.distanceMeters(from: $1.position, to: info.threshold)
            }
            for i in 1..<sorted.count {
                let leader = sorted[i - 1], follower = sorted[i]
                let gapNM = Geo.distanceMeters(from: leader.position, to: follower.position)
                    / Distance.metersPerNauticalMile
                if gapNM < requiredSeparationNM(leader, follower, aircraftTypes: aircraftTypes) {
                    conflicts.insert(leader.id)
                    conflicts.insert(follower.id)
                }
            }
        }
        return conflicts
    }
}
