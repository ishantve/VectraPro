//
//  MapViewModelCommandTests.swift
//  VectraProTests
//
//  The first tests this view model has ever had.
//
//  It could not be tested before for a plain reason: constructing one spoke out
//  loud, because it reached `CommandFeedbackManager.shared` from eight places. With
//  the dependency named, a spy can stand in and the routing decisions become
//  assertable — and those decisions are where a command ends up on the wrong
//  aircraft, or silently on none.
//

import XCTest
import ATCSimKit
@testable import VectraPro

@MainActor
final class MapViewModelCommandTests: XCTestCase {

    /// Records what would have been spoken instead of speaking it.
    private final class FeedbackSpy: CommandFeedback {
        var readbacks: [String] = []
        var accepted: [(callsign: String, commands: [AircraftCommand])] = []
        var errors: [String] = []
        var notFoundCount = 0

        func readback(_ spoken: String) { readbacks.append(spoken) }
        func commandAccepted(callsign: String, commands: [AircraftCommand]) {
            accepted.append((callsign, commands))
        }
        func commandError(_ phrase: String) { errors.append(phrase) }
        func aircraftNotFound() { notFoundCount += 1 }

        var saidNothing: Bool {
            readbacks.isEmpty && accepted.isEmpty && errors.isEmpty && notFoundCount == 0
        }
    }

    private final class ReportsSpy: DeferredReportAnnouncing {
        var advanceCount = 0
        func advance(aircraft: [Aircraft], allCallsigns: Set<String>,
                     fixes: [Fix], runways: [Runway]) {
            advanceCount += 1
        }
    }

    private var feedback: FeedbackSpy!
    private var viewModel: MapViewModel!

    override func setUp() {
        super.setUp()
        feedback = FeedbackSpy()
        viewModel = MapViewModel(feedback: feedback, reports: ReportsSpy())
    }

    /// The aircraft the view model spawns for itself at construction.
    private var spawnedCallsign: String {
        viewModel.aircraft.first?.callsign ?? ""
    }

    // MARK: - Routing by callsign

    func testCommandsReachAnAircraftNamedByCallsign() throws {
        let callsign = spawnedCallsign
        XCTAssertFalse(callsign.isEmpty, "the view model starts with one aircraft")

        viewModel.applyToCallsign(callsign, commands: [.heading(270)])

        XCTAssertEqual(feedback.accepted.count, 1)
        XCTAssertEqual(feedback.accepted.first?.callsign, callsign)
        XCTAssertEqual(viewModel.aircraft.first?.targetHeading, 270)
    }

    func testAnUnknownCallsignIsReportedRatherThanGuessedAt() {
        viewModel.applyToCallsign("ZZZ999", commands: [.heading(270)])

        XCTAssertEqual(feedback.notFoundCount, 1)
        XCTAssertTrue(feedback.accepted.isEmpty,
                      "nothing may be applied to an aircraft that does not exist")
        XCTAssertNil(viewModel.aircraft.first?.targetHeading)
    }

    func testCallsignMatchingIgnoresCase() {
        viewModel.applyToCallsign(spawnedCallsign.lowercased(), commands: [.heading(90)])
        XCTAssertEqual(viewModel.aircraft.first?.targetHeading, 90)
    }

    // MARK: - Routing to the selection

    func testACommandWithNoCallsignNeedsASelectedAircraft() {
        // Nothing selected: the command must be refused, not applied to whichever
        // aircraft happens to be first.
        viewModel.apply([.heading(270)])

        XCTAssertEqual(feedback.notFoundCount, 1)
        XCTAssertNil(viewModel.aircraft.first?.targetHeading)
    }

    func testACommandWithNoCallsignGoesToTheSelectedAircraft() throws {
        viewModel.selectAircraft(try XCTUnwrap(viewModel.aircraft.first?.id))
        viewModel.apply([.heading(270)])

        XCTAssertEqual(viewModel.aircraft.first?.targetHeading, 270)
        XCTAssertEqual(feedback.notFoundCount, 0)
    }

    // MARK: - Readback

    func testAPreRenderedReadbackIsSpokenInsteadOfTheLegacyEnglish() {
        viewModel.applyToCallsign(spawnedCallsign,
                                  commands: [.heading(270)],
                                  readback: "RADAR FLY HEADING two seven zero, test one")

        XCTAssertEqual(feedback.readbacks,
                       ["RADAR FLY HEADING two seven zero, test one"])
        XCTAssertTrue(feedback.accepted.isEmpty,
                      "the template phrasing replaces the assembled English")
    }

    func testWithoutAReadbackTheLegacyEnglishIsUsed() {
        viewModel.applyToCallsign(spawnedCallsign, commands: [.heading(270)])
        XCTAssertTrue(feedback.readbacks.isEmpty)
        XCTAssertEqual(feedback.accepted.count, 1)
    }

    // MARK: - Validation

    func testAnIllegalValueIsRejectedAndNothingIsApplied() {
        // FL900 is outside the operational envelope.
        viewModel.applyToCallsign(spawnedCallsign, commands: [.altitude(feet: 90_000)])

        XCTAssertEqual(feedback.errors.count, 1)
        XCTAssertTrue(feedback.accepted.isEmpty)
        XCTAssertNil(viewModel.aircraft.first?.targetAltitudeFeet)
    }

    func testAWholeUtteranceIsRejectedTogether() {
        // One bad value in a group must not let the others through — a controller
        // who is told "unable" should not find half the instruction was obeyed.
        viewModel.applyToCallsign(spawnedCallsign,
                                  commands: [.heading(270), .altitude(feet: 90_000)])

        XCTAssertEqual(feedback.errors.count, 1)
        XCTAssertNil(viewModel.aircraft.first?.targetHeading)
        XCTAssertNil(viewModel.aircraft.first?.targetAltitudeFeet)
    }

    func testConflictingInstructionsAreRefused() {
        viewModel.applyToCallsign(spawnedCallsign,
                                  commands: [.presentHeading, .heading(270)])
        XCTAssertEqual(feedback.errors.count, 1)
    }

    // MARK: - Several commands at once

    func testSeveralInstructionsAllTakeEffect() {
        viewModel.applyToCallsign(spawnedCallsign,
                                  commands: [.headingTurn(250, .right),
                                             .altitude(feet: 26_000),
                                             .speed(300)])

        let aircraft = viewModel.aircraft.first
        XCTAssertEqual(aircraft?.targetHeading, 250)
        XCTAssertEqual(aircraft?.turnDirection, .right)
        XCTAssertEqual(aircraft?.targetAltitudeFeet, 26_000)
        XCTAssertEqual(aircraft?.targetSpeedKnots, 300)
        XCTAssertEqual(feedback.accepted.count, 1, "one aircraft, one reply")
    }

    // MARK: - Nothing said when nothing happened

    func testAnEmptyCommandListSaysNothing() {
        viewModel.applyToCallsign(spawnedCallsign, commands: [])
        // An empty list still counts as accepted ("wilco"), but must not error.
        XCTAssertTrue(feedback.errors.isEmpty)
        XCTAssertEqual(feedback.notFoundCount, 0)
    }
}
