//
//  ExerciseRunwayLayoutTests.swift
//  VectraProTests
//
//  These rules used to live inside `MapViewModel.applyExercise` and so were never
//  tested. The one that matters most is the last: a runway end can be intercept-eligible
//  without its localizer being drawn, and conflating the two would either paint
//  localizers the exercise asked to hide, or refuse intercepts the exercise allows.
//

import Testing
import ATCSimKit
@testable import VectraPro

@MainActor
struct ExerciseRunwayLayoutTests {

    private func strip(_ name: String,
                       lat: Double?, lon: Double?,
                       active: Bool? = nil,
                       display: Bool? = nil) -> ExerciseDetail.Strip {
        ExerciseDetail.Strip(stripName: name,
                             stripLatitude: lat,
                             stripLongitude: lon,
                             activeLocalizer: active,
                             displayLocalizer: display)
    }

    private func runway(_ strips: [ExerciseDetail.Strip]?) -> ExerciseDetail.RunwayConfig {
        ExerciseDetail.RunwayConfig(runwayId: "r", runwayStrips: strips)
    }

    /// Both thresholds present → a runway between them.
    @Test func twoStripsBecomeOneRunway() {
        let layout = ExerciseRunwayLayout(from: [runway([
            strip("09", lat: 28.5, lon: 77.0),
            strip("27", lat: 28.5, lon: 77.1),
        ])])

        #expect(layout.runways.count == 1)
        #expect(layout.isEmpty == false)
        #expect(layout.runways[0].endA.designator == "09")
        #expect(layout.runways[0].endB.designator == "27")
    }

    /// A runway is the line between two thresholds, so one end is not enough. Skipping it
    /// matters more than it looks: a half-defined runway would otherwise land aircraft
    /// somewhere arbitrary.
    @Test func aRunwayMissingAThresholdIsSkipped() {
        let layouts = [
            ExerciseRunwayLayout(from: [runway([strip("09", lat: 28.5, lon: 77.0)])]),
            ExerciseRunwayLayout(from: [runway(nil)]),
            ExerciseRunwayLayout(from: [runway([
                strip("09", lat: 28.5, lon: 77.0),
                strip("27", lat: nil, lon: 77.1),      // no latitude
            ])]),
        ]

        for layout in layouts {
            #expect(layout.runways.isEmpty)
            #expect(layout.isEmpty)
        }
    }

    /// Only the ends the exercise marks active *and* displayed are painted.
    @Test func onlyActiveAndDisplayedLocalizersArePainted() {
        let layout = ExerciseRunwayLayout(from: [runway([
            strip("09", lat: 28.5, lon: 77.0, active: true, display: true),
            strip("27", lat: 28.5, lon: 77.1, active: false, display: true),
        ])])

        let runwayID = layout.runways[0].id
        #expect(layout.enabledApproaches == [ApproachID(runwayID: runwayID, side: .a)])
    }

    /// Nothing said → nothing enabled. An absent flag is not an implied yes.
    @Test func absentLocalizerFlagsEnableNothing() {
        let layout = ExerciseRunwayLayout(from: [runway([
            strip("09", lat: 28.5, lon: 77.0),
            strip("27", lat: 28.5, lon: 77.1),
        ])])

        #expect(layout.enabledApproaches.isEmpty)
        #expect(layout.activeLocalizerRunways.isEmpty)
    }

    /// The distinction that made this worth extracting: an active-but-hidden localizer is
    /// still intercept-eligible. `activeLocalizerRunways` tracks what may be flown;
    /// `enabledApproaches` only what is drawn.
    @Test func anActiveLocalizerIsInterceptEligibleEvenWhenNotDrawn() {
        let layout = ExerciseRunwayLayout(from: [runway([
            strip("09", lat: 28.5, lon: 77.0, active: true, display: false),
            strip("27", lat: 28.5, lon: 77.1, active: true, display: true),
        ])])

        // Canonical form drops the leading zero, so "09" and "9" name the same end —
        // which is what lets a spoken "runway nine" match a payload that said "09".
        #expect(layout.activeLocalizerRunways == ["9", "27"])
        #expect(layout.enabledApproaches == [ApproachID(runwayID: layout.runways[0].id, side: .b)])
    }
}
