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
//  Every command applied here carries a readback, because that is now the contract:
//  nothing assembles a reply from the command enum any more, so applying a command
//  the vocabulary cannot describe is a programming error the view model asserts on.
//

import XCTest
import ATCParserKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class MapViewModelCommandTests: XCTestCase {

    /// Records what would have been spoken instead of speaking it.
    private final class FeedbackSpy: CommandFeedback {
        var readbacks: [String] = []
        var errors: [String] = []
        var notFoundCount = 0

        func readback(_ spoken: String) { readbacks.append(spoken) }
        func commandError(_ phrase: String) { errors.append(phrase) }
        func aircraftNotFound() { notFoundCount += 1 }

        var saidNothing: Bool {
            readbacks.isEmpty && errors.isEmpty && notFoundCount == 0
        }
    }

    private final class ReportsSpy: DeferredReportAnnouncing {
        var advanceCount = 0
        var registered: [String] = []

        func register(_ command: RecognizedCommand, aircraftCallsign: String?) {
            registered.append(command.code)
        }

        func advance(aircraft: [Aircraft], allCallsigns: Set<String>,
                     fixes: [Fix], runways: [Runway]) {
            advanceCount += 1
        }
    }

    private var feedback: FeedbackSpy!
    private var viewModel: MapViewModel!

    /// Stands in for the phrase a template would have produced.
    private let reply = "TEST READBACK, test one"

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

    func testCommandsReachAnAircraftNamedByCallsign() {
        let callsign = spawnedCallsign
        XCTAssertFalse(callsign.isEmpty, "the view model starts with one aircraft")

        viewModel.applyToCallsign(callsign, commands: [.heading(270)], readback: reply)

        XCTAssertEqual(feedback.readbacks, [reply])
        XCTAssertEqual(viewModel.aircraft.first?.targetHeading, 270)
    }

    func testAnUnknownCallsignIsReportedRatherThanGuessedAt() {
        viewModel.applyToCallsign("ZZZ999", commands: [.heading(270)], readback: reply)

        XCTAssertEqual(feedback.notFoundCount, 1)
        XCTAssertTrue(feedback.readbacks.isEmpty,
                      "nothing may be applied to an aircraft that does not exist")
        XCTAssertNil(viewModel.aircraft.first?.targetHeading)
    }

    func testCallsignMatchingIgnoresCase() {
        viewModel.applyToCallsign(spawnedCallsign.lowercased(),
                                  commands: [.heading(90)], readback: reply)
        XCTAssertEqual(viewModel.aircraft.first?.targetHeading, 90)
    }

    // MARK: - Routing to the selection

    func testACommandWithNoCallsignNeedsASelectedAircraft() {
        // Nothing selected: the command must be refused, not applied to whichever
        // aircraft happens to be first.
        viewModel.apply([.heading(270)], readback: reply)

        XCTAssertEqual(feedback.notFoundCount, 1)
        XCTAssertNil(viewModel.aircraft.first?.targetHeading)
    }

    func testACommandWithNoCallsignGoesToTheSelectedAircraft() throws {
        viewModel.selectAircraft(try XCTUnwrap(viewModel.aircraft.first?.id))
        viewModel.apply([.heading(270)], readback: reply)

        XCTAssertEqual(viewModel.aircraft.first?.targetHeading, 270)
        // This path used to drop the phrase and fall back to English of its own.
        XCTAssertEqual(feedback.readbacks, [reply])
        XCTAssertEqual(feedback.notFoundCount, 0)
    }

    // MARK: - Readback

    func testTheTemplatePhrasingIsWhatIsSpoken() {
        viewModel.applyToCallsign(spawnedCallsign,
                                  commands: [.heading(270)],
                                  readback: "RADAR FLY HEADING two seven zero, test one")

        XCTAssertEqual(feedback.readbacks,
                       ["RADAR FLY HEADING two seven zero, test one"])
    }

    // MARK: - Validation

    func testAnIllegalValueIsRejectedAndNothingIsApplied() {
        // FL900 is outside the operational envelope.
        viewModel.applyToCallsign(spawnedCallsign,
                                  commands: [.altitude(feet: 90_000)], readback: reply)

        XCTAssertEqual(feedback.errors.count, 1)
        XCTAssertTrue(feedback.readbacks.isEmpty, "a rejected command is not read back")
        XCTAssertNil(viewModel.aircraft.first?.targetAltitudeFeet)
    }

    func testAWholeUtteranceIsRejectedTogether() {
        // One bad value in a group must not let the others through — a controller
        // who is told "unable" should not find half the instruction was obeyed.
        viewModel.applyToCallsign(spawnedCallsign,
                                  commands: [.heading(270), .altitude(feet: 90_000)],
                                  readback: reply)

        XCTAssertEqual(feedback.errors.count, 1)
        XCTAssertNil(viewModel.aircraft.first?.targetHeading)
        XCTAssertNil(viewModel.aircraft.first?.targetAltitudeFeet)
    }

    func testConflictingInstructionsAreRefused() {
        viewModel.applyToCallsign(spawnedCallsign,
                                  commands: [.presentHeading, .heading(270)],
                                  readback: reply)
        XCTAssertEqual(feedback.errors.count, 1)
    }

    // MARK: - Several commands at once

    func testSeveralInstructionsAllTakeEffect() {
        viewModel.applyToCallsign(spawnedCallsign,
                                  commands: [.headingTurn(250, .right),
                                             .altitude(feet: 26_000),
                                             .speed(300)],
                                  readback: reply)

        let aircraft = viewModel.aircraft.first
        XCTAssertEqual(aircraft?.targetHeading, 250)
        XCTAssertEqual(aircraft?.turnDirection, .right)
        XCTAssertEqual(aircraft?.targetAltitudeFeet, 26_000)
        XCTAssertEqual(aircraft?.targetSpeedKnots, 300)
        XCTAssertEqual(feedback.readbacks.count, 1, "one aircraft, one reply")
    }

    // MARK: - A phrase that changes nothing

    func testAnEmptyCommandListIsStillAnswered() {
        // "Wilco" for phraseology with no effect — answered, and not an error.
        viewModel.applyToCallsign(spawnedCallsign, commands: [], readback: reply)

        XCTAssertEqual(feedback.readbacks, [reply])
        XCTAssertTrue(feedback.errors.isEmpty)
        XCTAssertEqual(feedback.notFoundCount, 0)
    }
}
