//
//  PendingReportTrackerTests.swift
//  ATCSimKit
//
//  When a "report …" instruction actually comes due.
//
//  Passing a point needs both halves of its rule pinned. `testAPassSlightlyOffTrack
//  StillFires` guards the one a plain radius would miss; `testATurnFarFromThePoint
//  IsNotAPass` guards the one closest approach alone got wrong, which is worse — it
//  reported a pass that never happened.
//

import XCTest
import CoreLocation
@testable import ATCSimKit

final class PendingReportTrackerTests: XCTestCase {

    private let fix = Fix(fixName: "PJ", type: "WAYPOINT", latitude: 28.60, longitude: 77.10)

    private func aircraft(at latitude: Double, longitude: Double,
                          callsign: String = "AIC123") -> Aircraft {
        Aircraft(callsign: callsign,
                 position: .init(latitude: latitude, longitude: longitude),
                 headingDegrees: 0)
    }

    /// Flies the aircraft through a series of positions, returning the ids fired.
    private func fly(_ tracker: inout PendingReportTracker,
                     through positions: [(Double, Double)],
                     callsign: String = "AIC123") -> [UUID] {
        var fired: [UUID] = []
        for (latitude, longitude) in positions {
            fired += tracker.evaluate(
                aircraft: [aircraft(at: latitude, longitude: longitude, callsign: callsign)],
                fixes: [fix],
                runways: [])
        }
        return fired
    }

    // MARK: - Passing a point

    func testPassingAFixFiresOnceTheAircraftIsPastIt() {
        var tracker = PendingReportTracker()
        let report = PendingReport(id: UUID(), callsign: "AIC123", condition: .passingFix("PJ"))
        tracker.register(report)

        // Northbound along 77.10, straight over the fix at 28.60.
        let fired = fly(&tracker, through: [(28.40, 77.10), (28.50, 77.10),
                                            (28.58, 77.10), (28.62, 77.10),
                                            (28.70, 77.10)])
        XCTAssertEqual(fired, [report.id])
        XCTAssertTrue(tracker.pending.isEmpty, "a fired report is not owed twice")
    }

    func testAPassSlightlyOffTrackStillFires() {
        // About two miles abeam — outside the radius a hold would capture with, but
        // plainly a pass, and a vectored aircraft will often be no closer.
        var tracker = PendingReportTracker()
        let report = PendingReport(id: UUID(), callsign: "AIC123", condition: .passingFix("PJ"))
        tracker.register(report)

        let fired = fly(&tracker, through: [(28.50, 77.135), (28.56, 77.135),
                                            (28.60, 77.135), (28.66, 77.135)])
        XCTAssertEqual(fired, [report.id])
    }

    func testATurnFarFromThePointIsNotAPass() {
        // Closest approach alone made this a pass: the aircraft closes on the point,
        // turns twenty miles short, and opens again. Nothing passed anything, and
        // announcing "passing" here is a wrong readback rather than a missing one.
        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123",
                                       condition: .passingFix("PJ")))

        // Northbound to 28.28 (~19 NM short of the fix at 28.60), then back south.
        let fired = fly(&tracker, through: [(28.10, 77.10), (28.20, 77.10),
                                            (28.28, 77.10), (28.20, 77.10),
                                            (28.10, 77.10)])
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(tracker.pending.count, 1, "still owed — it never got there")
    }

    func testTheRadiusIsConfigurable() {
        // A deployment that wants a tighter or looser idea of "passing" can say so.
        var tight = PendingReportTracker(passingRadiusNM: 1)
        tight.register(PendingReport(id: UUID(), callsign: "AIC123",
                                    condition: .passingFix("PJ")))
        // The same two-mile-abeam track that fires with the default radius.
        XCTAssertTrue(fly(&tight, through: [(28.50, 77.135), (28.56, 77.135),
                                            (28.60, 77.135), (28.66, 77.135)]).isEmpty)
    }

    func testAnAircraftFlyingAwayFromTheStartDoesNotReportImmediately() {
        // Without requiring an approach first, the very first opening distance
        // would look exactly like a pass.
        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123",
                                       condition: .passingFix("PJ")))

        let fired = fly(&tracker, through: [(28.50, 77.10), (28.40, 77.10),
                                            (28.30, 77.10), (28.20, 77.10)])
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(tracker.pending.count, 1, "still owed — it never got there")
    }

    func testNothingFiresOnTheFirstEvaluation() {
        // One position is not a direction of travel.
        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123",
                                       condition: .passingFix("PJ")))
        XCTAssertTrue(fly(&tracker, through: [(28.59, 77.10)]).isEmpty)
    }

    // MARK: - Distance from a point

    func testDistanceReportFiresOnCrossingTheRange() {
        var tracker = PendingReportTracker()
        let report = PendingReport(id: UUID(), callsign: "AIC123",
                                   condition: .distanceFromFix(nauticalMiles: 10, fix: "PJ"))
        tracker.register(report)

        // Inbound from about 24 NM south, through 10 NM (≈0.167°).
        let fired = fly(&tracker, through: [(28.20, 77.10), (28.35, 77.10),
                                            (28.42, 77.10), (28.47, 77.10)])
        XCTAssertEqual(fired, [report.id])
    }

    func testDistanceReportDoesNotFireBeforeTheRange() {
        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123",
                                       condition: .distanceFromFix(nauticalMiles: 10, fix: "PJ")))
        // Stays 15 NM or more out.
        XCTAssertTrue(fly(&tracker, through: [(28.20, 77.10), (28.25, 77.10),
                                              (28.32, 77.10)]).isEmpty)
    }

    func testDistanceReportAlsoFiresOutbound() {
        // "Report 10 miles from PJ" while departing is still a range crossing.
        var tracker = PendingReportTracker()
        let report = PendingReport(id: UUID(), callsign: "AIC123",
                                   condition: .distanceFromFix(nauticalMiles: 10, fix: "PJ"))
        tracker.register(report)

        let fired = fly(&tracker, through: [(28.60, 77.10), (28.68, 77.10),
                                            (28.78, 77.10)])
        XCTAssertEqual(fired, [report.id])
    }

    // MARK: - Localizer

    func testLocalizerReportNeedsTheAircraftToBeClearedFirst() {
        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123",
                                       condition: .establishedOnLocalizer))
        // No intercept clearance — nothing to be established on.
        XCTAssertTrue(tracker.evaluate(aircraft: [aircraft(at: 28.5, longitude: 77.1)],
                                       fixes: [fix], runways: []).isEmpty)
        XCTAssertEqual(tracker.pending.count, 1)
    }

    // MARK: - Housekeeping

    func testAskingTwiceDoesNotOweTheReportTwice() {
        var tracker = PendingReportTracker()
        let first = PendingReport(id: UUID(), callsign: "AIC123", condition: .passingFix("PJ"))
        let second = PendingReport(id: UUID(), callsign: "AIC123", condition: .passingFix("PJ"))

        XCTAssertNil(tracker.register(first))
        XCTAssertEqual(tracker.register(second), first.id, "the earlier one is displaced")
        XCTAssertEqual(tracker.pending.count, 1)
        XCTAssertEqual(tracker.pending.first?.id, second.id)
    }

    func testDifferentConditionsForOneAircraftBothStand() {
        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123",
                                       condition: .passingFix("PJ")))
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123",
                                       condition: .distanceFromFix(nauticalMiles: 10, fix: "PJ")))
        XCTAssertEqual(tracker.pending.count, 2)
    }

    func testReportsAreForgottenWhenTheAircraftLeavesTheScene() {
        var tracker = PendingReportTracker()
        let report = PendingReport(id: UUID(), callsign: "AIC123", condition: .passingFix("PJ"))
        tracker.register(report)

        XCTAssertEqual(tracker.forget(callsignsOtherThan: ["BAW17"]), [report.id])
        XCTAssertTrue(tracker.pending.isEmpty)
    }

    func testReportsSurviveWhileTheAircraftIsStillAround() {
        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123",
                                       condition: .passingFix("PJ")))
        XCTAssertTrue(tracker.forget(callsignsOtherThan: ["aic123", "BAW17"]).isEmpty,
                      "callsign comparison must not be case-sensitive")
        XCTAssertEqual(tracker.pending.count, 1)
    }

    func testAnUnknownFixNeverFires() {
        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123",
                                       condition: .passingFix("NOPE")))
        XCTAssertTrue(fly(&tracker, through: [(28.4, 77.1), (28.6, 77.1), (28.8, 77.1)]).isEmpty)
    }

    // MARK: - Validation

    private func context(_ fixes: [Fix]) -> CommandValidator.Context {
        CommandValidator.Context(runways: [], activeLocalizerRunways: [],
                                 holdingFixes: [], navigationFixes: fixes)
    }

    func testAReportForAKnownPointIsAccepted() {
        XCTAssertEqual(CommandValidator.validate(.passingFix("PJ"), context: context([fix])),
                       .ok)
        XCTAssertEqual(
            CommandValidator.validate(.distanceFromFix(nauticalMiles: 10, fix: "PJ"),
                                      context: context([fix])),
            .ok)
    }

    /// The gap this closes.
    ///
    /// A report condition never reaches command validation, because the phraseology
    /// carrying it produces no AircraftCommand. So "report passing XYZ" for a point
    /// that does not exist used to be answered "wilco" and then never reported —
    /// the tracker looked the fix up every tick, found nothing, and stayed silent
    /// forever. A hold to the same unknown fix is rejected, so this must be too.
    func testAReportForAnUnknownPointIsRejected() {
        XCTAssertEqual(CommandValidator.validate(.passingFix("XYZ"), context: context([fix])),
                       .rejected("Unable, XYZ not found"))
        XCTAssertEqual(
            CommandValidator.validate(.distanceFromFix(nauticalMiles: 10, fix: "XYZ"),
                                      context: context([fix])),
            .rejected("Unable, XYZ not found"))
    }

    func testALocalizerReportNeedsNothingValidated() {
        // A controller may ask for it before issuing the approach clearance; it just
        // waits until there is one.
        XCTAssertEqual(CommandValidator.validate(.establishedOnLocalizer, context: context([])),
                       .ok)
    }

    func testAnUnknownFixWouldOtherwiseNeverFire() {
        // What the validation prevents, shown directly: the tracker cannot report a
        // point it cannot find, and says nothing about it.
        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123",
                                       condition: .passingFix("XYZ")))
        XCTAssertTrue(fly(&tracker, through: [(28.4, 77.1), (28.6, 77.1), (28.8, 77.1)]).isEmpty)
        XCTAssertEqual(tracker.pending.count, 1, "owed forever, in silence")
    }

    // MARK: - Mapping

    func testConditionsComeFromTheCode() {
        XCTAssertEqual(
            CommandMapping.reportCondition(
                code: "316",
                slots: StaticCommandSlots(texts: ["SIGNIFICANT POINT": ["PJ"]])),
            .passingFix("PJ"))

        XCTAssertEqual(
            CommandMapping.reportCondition(
                code: "319",
                slots: StaticCommandSlots(integers: ["DISTANCE": [10]],
                                          texts: ["DME STATION": ["PJ"]])),
            .distanceFromFix(nauticalMiles: 10, fix: "PJ"))

        XCTAssertEqual(
            CommandMapping.reportCondition(code: "405", slots: StaticCommandSlots()),
            .establishedOnLocalizer)

        // 320's condition uses the point its own template names, not the station
        // its readback mistakenly mentions.
        XCTAssertEqual(
            CommandMapping.reportCondition(
                code: "320",
                slots: StaticCommandSlots(integers: ["DISTANCE": [10]],
                                          texts: ["SIGNIFICANT POINT": ["PJ"]])),
            .distanceFromFix(nauticalMiles: 10, fix: "PJ"))
    }

    func testCommandsThatAskForNothingDeferredHaveNoCondition() {
        XCTAssertNil(CommandMapping.reportCondition(code: "247",
                                                    slots: StaticCommandSlots()))
        XCTAssertNil(CommandMapping.reportCondition(code: "435",
                                                    slots: StaticCommandSlots()))
    }
}
