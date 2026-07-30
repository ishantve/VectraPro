//
//  DeferredReportTests.swift
//  VectraProTests
//
//  "Report passing PAPA JULIET" end to end: the instruction is answered now, the
//  report is owed, and it is spoken when the aircraft actually gets there.
//
//  The three layers each have their own tests; what only this level can check is
//  that the phrase the parser rendered and the condition the simulator evaluates
//  refer to the same thing.
//

import XCTest
import CoreLocation
import ATCParserKit
import ATCSimKit
@testable import VectraPro

final class DeferredReportTests: XCTestCase {

    private var recognizer: CommandRecognizer!
    private let fix = Fix(fixName: "PJ", type: "WAYPOINT", latitude: 28.60, longitude: 77.10)

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VectraPro/Resources/CommandTemplates.json")
        var set = try TemplateSet(data: try Data(contentsOf: url))
        // Same correction the app applies at load — 320's readback as shipped names
        // a placeholder its request never supplies.
        set = set.applying([
            .init(id: "320",
                  readback: "WILCO, [CALLSIGN]. Later: [CALLSIGN], "
                          + "[DISTANCE] MILES DME FROM [SIGNIFICANT POINT].")
        ])
        recognizer = CommandRecognizer(templates: set)
    }

    private func command(_ transcript: String) throws -> RecognizedCommand {
        try XCTUnwrap(recognizer.recognize(transcript).commands.first)
    }

    // MARK: - Both halves of the readback

    func testTheImmediateReplyIsWilco() throws {
        let command = try command("air india 123 report passing papa juliet")
        XCTAssertEqual(command.code, "316")
        XCTAssertEqual(command.readback.primary.spoken, "WILCO, air india one two three")
    }

    func testTheDeferredHalfIsRenderedAndReady() throws {
        let command = try command("air india 123 report passing papa juliet")
        let deferred = try XCTUnwrap(command.readback.deferred)
        XCTAssertTrue(deferred.unresolvedSlots.isEmpty)
        XCTAssertEqual(deferred.spoken,
                       "air india one two three, PASSING papa juliet")
    }

    // MARK: - Phrase and condition agree

    func testTheConditionNamesTheSameFixThePhraseWillReport() throws {
        let command = try command("air india 123 report passing papa juliet")
        XCTAssertEqual(CommandMapping.reportCondition(code: command.code, slots: command),
                       .passingFix("PJ"))
    }

    func testDistanceReportCarriesBothItsRangeAndItsPoint() throws {
        let command = try command(
            "air india 123 report 10 miles dme from papa juliet")
        XCTAssertEqual(CommandMapping.reportCondition(code: command.code, slots: command),
                       .distanceFromFix(nauticalMiles: 10, fix: "PJ"))
        let deferred = try XCTUnwrap(command.readback.deferred)
        XCTAssertTrue(deferred.unresolvedSlots.isEmpty,
                      "the correction is what makes 320 speakable")
        XCTAssertEqual(deferred.spoken?.contains("one zero MILES"), true)
    }

    func testLocalizerReport() throws {
        let command = try command("air india 123 report established on ils localizer")
        XCTAssertEqual(command.code, "405")
        XCTAssertEqual(CommandMapping.reportCondition(code: command.code, slots: command),
                       .establishedOnLocalizer)
        XCTAssertEqual(try XCTUnwrap(command.readback.deferred).spoken,
                       "air india one two three, ESTABLISHED ON ILS LOCALIZER")
    }

    // MARK: - It fires at the right moment

    func testTheReportComesDueOnPassingTheFix() throws {
        let command = try command("air india 123 report passing papa juliet")
        let condition = try XCTUnwrap(
            CommandMapping.reportCondition(code: command.code, slots: command))

        var tracker = PendingReportTracker()
        let report = PendingReport(id: UUID(), callsign: "air india 123", condition: condition)
        tracker.register(report)

        var fired: [UUID] = []
        for latitude in [28.40, 28.50, 28.58, 28.63, 28.70] {
            let plane = Aircraft(callsign: "air india 123",
                                 position: .init(latitude: latitude, longitude: 77.10),
                                 headingDegrees: 0)
            fired += tracker.evaluate(aircraft: [plane], fixes: [fix], runways: [])
        }

        XCTAssertEqual(fired, [report.id])
    }

    // MARK: - Instructions with nothing deferred

    func testAPlainVectorOwesNothing() throws {
        let command = try command("air india 123 turn right heading 250")
        XCTAssertNil(command.readback.deferred)
        XCTAssertNil(CommandMapping.reportCondition(code: command.code, slots: command))
    }

    // MARK: - The coordinator

    func testCoordinatorRegistersOnlyWhatItCanSpeak() throws {
        let coordinator = DeferredReportCoordinator.shared
        coordinator.reset()

        coordinator.register(try command("air india 123 report passing papa juliet"))
        XCTAssertEqual(coordinator.pendingCount, 1)

        // A plain vector adds nothing.
        coordinator.register(try command("air india 123 turn right heading 250"))
        XCTAssertEqual(coordinator.pendingCount, 1)

        // Asking again does not owe it twice.
        coordinator.register(try command("air india 123 report passing papa juliet"))
        XCTAssertEqual(coordinator.pendingCount, 1)

        coordinator.reset()
    }

    func testCoordinatorForgetsReportsForAircraftThatHaveGone() throws {
        let coordinator = DeferredReportCoordinator.shared
        coordinator.reset()
        coordinator.register(try command("air india 123 report passing papa juliet"))

        coordinator.advance(aircraft: [], allCallsigns: ["BAW17"],
                            fixes: [fix], runways: [])
        XCTAssertEqual(coordinator.pendingCount, 0)
        coordinator.reset()
    }
}
