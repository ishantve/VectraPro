//
//  ExerciseRunwayLayout.swift
//  VectraPro
//
//  Turns the exercise payload's runways into the scene's runways, the approaches that
//  start out enabled, and the runway ends an aircraft may be cleared to intercept.
//
//  This was inline in `MapViewModel.applyExercise`, mixed in with a dozen unrelated
//  field assignments, which meant these rules — which strips count, which localizers
//  show, which ends are intercept-eligible — could not be tested without a view model
//  and an exercise. They are a plain function of the payload, so they are one here.
//

import Foundation
import CoreLocation
import ATCSimKit

struct ExerciseRunwayLayout {

    let runways: [Runway]
    /// Approaches drawn from the start: the localizer is both set to display *and* active.
    let enabledApproaches: Set<ApproachID>
    /// Canonical designators of ends with an active localizer, whether or not it is drawn.
    /// An aircraft may be cleared to intercept these; `enabledApproaches` is only about
    /// what is painted.
    let activeLocalizerRunways: Set<String>

    /// An exercise that defined no usable runway. The caller keeps whatever runways it
    /// already had rather than emptying the scene.
    var isEmpty: Bool { runways.isEmpty }

    init(from payloadRunways: [ExerciseDetail.RunwayConfig]) {
        var runways: [Runway] = []
        var enabled: Set<ApproachID> = []
        var activeLocalizers: Set<String> = []

        for rw in payloadRunways {
            // A runway is the line between two thresholds, so anything without both
            // coordinates is not a runway we can draw or land on.
            let strips = rw.runwayStrips ?? []
            guard strips.count >= 2,
                  let aLat = strips[0].stripLatitude, let aLon = strips[0].stripLongitude,
                  let bLat = strips[1].stripLatitude, let bLon = strips[1].stripLongitude
            else { continue }

            let runway = Runway(
                endA: RunwayThreshold(designator: strips[0].stripName ?? "",
                                      coordinate: CLLocationCoordinate2D(latitude: aLat, longitude: aLon)),
                endB: RunwayThreshold(designator: strips[1].stripName ?? "",
                                      coordinate: CLLocationCoordinate2D(latitude: bLat, longitude: bLon)),
                lengthMeters: nil
            )
            runways.append(runway)

            let sides: [(ExerciseDetail.Strip, RunwayEndSide)] = [(strips[0], .a), (strips[1], .b)]
            for (strip, side) in sides {
                guard strip.activeLocalizer == true else { continue }
                activeLocalizers.insert(RunwayGeometry.canonical(strip.stripName ?? ""))
                // Active but not set to display: usable, just not painted.
                if strip.displayLocalizer == true {
                    enabled.insert(ApproachID(runwayID: runway.id, side: side))
                }
            }
        }

        self.runways = runways
        self.enabledApproaches = enabled
        self.activeLocalizerRunways = activeLocalizers
    }
}
