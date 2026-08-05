//
//  ExerciseDetail+DebugDump.swift
//  VectraPro
//
//  Prints the started exercise to the console in DEBUG builds.
//
//  Three of these dumps were inline in `MapViewModel.applyExercise`, where fifty-odd
//  lines of print statements outnumbered the ten lines that actually did anything. They
//  are worth keeping — the backend payload is the usual suspect when a scene looks wrong,
//  and this is how we see what arrived — but they are not the view model's work.
//

import Foundation

extension ExerciseDetail {

    /// Dumps the payload: the exercise itself, its holding fixes, and its zones.
    ///
    /// `initialSpawnCount` is passed in rather than derived, since how many aircraft the
    /// exercise starts with is the view model's reading of the payload, not the payload's
    /// own — and seeing the two side by side is the point of printing it.
    func dumpToConsole(initialSpawnCount: Int) {
        #if DEBUG
        print("""
        ========== EXERCISE DETAIL ==========
        name: \(exerciseName)   icao: \(icaoCode ?? "—")   airport: \(airportName ?? "—")
        map: \(mapLatitude ?? 0), \(mapLongitude ?? 0)
        isMultiMode: \(String(describing: isMultiMode))
        airspaceCapacity: \(String(describing: airspaceCapacity))
        aircraftSpawningCount: \(String(describing: aircraftSpawningCount))
        → initialSpawnCount: \(initialSpawnCount)
        runways: \(runways.count)   fixes: \(fixes.count)   zones: \(zones.count)   obstructions: \(obstructions.count)
        airlines (\(airlines.count)): \(airlines.map { "\($0.icaoCode ?? "?")/\($0.callSign ?? "?")" })
        aircrafts (\(aircrafts.count)): \(aircrafts.map { "\($0.icaoCode ?? "?")=\($0.model ?? "?") [\($0.icaoWTC ?? "?")]" })
        freqDeparture: type=\(frequencyOfDeparture?.type ?? "—") flights=\(String(describing: frequencyOfDeparture?.departureFlights)) time=\(String(describing: frequencyOfDeparture?.departureFlightsTimeValue))
        freqArrival:   type=\(frequencyOfArrival?.type ?? "—") flights=\(String(describing: frequencyOfArrival?.arrivalFlights)) time=\(String(describing: frequencyOfArrival?.arrivalFlightsTimeValue))
        freqEnroute:   type=\(frequencyOfEnroute?.type ?? "—") flights=\(String(describing: frequencyOfEnroute?.enrouteFlights)) time=\(String(describing: frequencyOfEnroute?.enrouteFlightsTimeValue))
        =====================================
        """)
        dumpHoldingFixes()
        dumpZones()
        #endif
    }

    #if DEBUG
    private func dumpHoldingFixes() {
        let holdings = fixes.filter { $0.type?.uppercased() == "HOLDING" }
        print("📡 HOLDING FIXES FROM API — \(holdings.count) found")
        for f in holdings {
            print("""
              • fixId : \(f.fixId ?? "-")
                name  : \(f.fixName ?? "-")
                type  : \(f.type ?? "-")   fixType: \(f.fixType ?? "-")
                lat   : \(f.latitude.map { String($0) } ?? "-")
                lon   : \(f.longitude.map { String($0) } ?? "-")
                radials: \(f.radials?.count ?? 0)
            """)
        }
    }

    private func dumpZones() {
        print("========== ZONES (\(zones.count)) ==========")
        for z in zones {
            print("  zone: id=\(z.zoneId ?? "—")  name=\(z.zoneName ?? "—")  type=\(z.zoneType ?? "—")  isActive=\(String(describing: z.isActive))  color=\(z.color ?? "—")  colliders=\(z.colliders?.count ?? 0)")
            for (i, c) in (z.colliders ?? []).enumerated() {
                print("    [\(i)] lat=\(String(describing: c.latitude))  lon=\(String(describing: c.longitude))")
            }
        }
        print("==========================================")
    }
    #endif
}
