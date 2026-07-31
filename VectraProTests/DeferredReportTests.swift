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

@MainActor
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
        // The aircraft's own callsign, not the spoken form — see
        // `testAReportRegisteredAgainstTheSpokenCallsignNeverFires`.
        let report = PendingReport(id: UUID(), callsign: "AIC123", condition: condition)
        tracker.register(report)

        var fired: [UUID] = []
        for latitude in [28.40, 28.50, 28.58, 28.63, 28.70] {
            fired += tracker.evaluate(aircraft: [plane(at: latitude)],
                                      fixes: [fix], runways: [])
        }

        XCTAssertEqual(fired, [report.id])
    }

    /// The bug this pair exists to prevent.
    ///
    /// `RecognizedCommand.callsign` is what the controller said — "air india 123".
    /// The aircraft is "AIC123". Registering the spoken form means the tracker
    /// never finds the aircraft, and housekeeping drops the report on the very next
    /// tick as belonging to something that has left the scene. Nothing is ever
    /// spoken and nothing reports an error.
    func testAReportRegisteredAgainstTheSpokenCallsignNeverFires() throws {
        let command = try command("air india 123 report passing papa juliet")
        let condition = try XCTUnwrap(
            CommandMapping.reportCondition(code: command.code, slots: command))

        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(),
                                       callsign: "air india 123",   // wrong on purpose
                                       condition: condition))

        // Housekeeping sees a callsign no aircraft answers to.
        XCTAssertEqual(tracker.forget(callsignsOtherThan: ["AIC123"]).count, 1)
        XCTAssertTrue(tracker.pending.isEmpty)
    }

    func testTheSameReportAgainstTheAircraftCallsignSurvivesHousekeeping() throws {
        let command = try command("air india 123 report passing papa juliet")
        let condition = try XCTUnwrap(
            CommandMapping.reportCondition(code: command.code, slots: command))

        var tracker = PendingReportTracker()
        tracker.register(PendingReport(id: UUID(), callsign: "AIC123", condition: condition))

        XCTAssertTrue(tracker.forget(callsignsOtherThan: ["AIC123"]).isEmpty)
        XCTAssertEqual(tracker.pending.count, 1)
    }

    /// The phrase still names the aircraft the way the controller said it — a pilot
    /// reads back their own callsign, not an ICAO designator.
    func testThePhraseKeepsTheSpokenCallsignEvenThoughTheTrackerUsesTheOther() throws {
        let command = try command("air india 123 report passing papa juliet")
        XCTAssertEqual(try XCTUnwrap(command.readback.deferred).spoken,
                       "air india one two three, PASSING papa juliet")
    }

    private func plane(at latitude: Double) -> Aircraft {
        Aircraft(callsign: "AIC123",
                 position: .init(latitude: latitude, longitude: 77.10),
                 headingDegrees: 0)
    }

    // MARK: - Instructions with nothing deferred

    func testAPlainVectorOwesNothing() throws {
        let command = try command("air india 123 turn right heading 250")
        XCTAssertNil(command.readback.deferred)
        XCTAssertNil(CommandMapping.reportCondition(code: command.code, slots: command))
    }

    // MARK: - Named points are checked before the pilot agrees

    private func context(_ fixes: [Fix]) -> CommandValidator.Context {
        CommandValidator.Context(runways: [], activeLocalizerRunways: [],
                                 holdingFixes: [], navigationFixes: fixes)
    }

    /// The fix names a command puts on the air, as the controller reads them.
    private func namedPoints(_ command: RecognizedCommand) -> [String] {
        command.slots.compactMap { slot in
            guard slot.kind == .fix, case .fix(let name)? = slot.value else { return nil }
            return name
        }
    }

    func testAReportForAPointThatIsNotInTheSceneIsRefused() throws {
        // Nothing named XYZ exists, so the report could never happen. Saying "wilco"
        // and then staying silent for the rest of the exercise is the failure this
        // prevents.
        let command = try command("air india 123 report passing xray yankee zulu")
        XCTAssertEqual(CommandValidator.validate(fixNames: namedPoints(command),
                                                 context: context([fix])),
                       .rejected("Unable, XYZ not found"))
    }

    func testAReportForAKnownPointIsAccepted() throws {
        let command = try command("air india 123 report passing papa juliet")
        XCTAssertEqual(CommandValidator.validate(fixNames: namedPoints(command),
                                                 context: context([fix])),
                       .ok)
    }

    /// The check reads the command's slots, not its effect, so it also covers
    /// phraseology that names a point without doing anything to the aircraft.
    func testAPointNamedByACoordinationMessageIsAlsoChecked() throws {
        let command = try command(
            "air india 123 radar request level change from delhi at xray yankee zulu")
        XCTAssertEqual(command.code, "123")
        XCTAssertEqual(CommandValidator.validate(fixNames: namedPoints(command),
                                                 context: context([fix])),
                       .rejected("Unable, XYZ not found"))
    }

    func testACommandNamingNoPointIsUnaffected() throws {
        let command = try command("air india 123 turn right heading 250")
        XCTAssertTrue(namedPoints(command).isEmpty)
        XCTAssertEqual(CommandValidator.validate(fixNames: namedPoints(command),
                                                 context: context([])),
                       .ok)
    }

    // MARK: - The coordinator

    func testCoordinatorRegistersOnlyWhatItCanSpeak() throws {
        let coordinator = DeferredReportCoordinator.shared
        coordinator.reset()

        coordinator.register(try command("air india 123 report passing papa juliet"),
                             aircraftCallsign: "AIC123")
        XCTAssertEqual(coordinator.pendingCount, 1)

        // A plain vector adds nothing.
        coordinator.register(try command("air india 123 turn right heading 250"),
                             aircraftCallsign: "AIC123")
        XCTAssertEqual(coordinator.pendingCount, 1)

        // Asking again does not owe it twice.
        coordinator.register(try command("air india 123 report passing papa juliet"),
                             aircraftCallsign: "AIC123")
        XCTAssertEqual(coordinator.pendingCount, 1)
        coordinator.reset()

    }

    func testCoordinatorSpeaksTheReportWhenTheAircraftPassesTheFix() throws {
        let coordinator = DeferredReportCoordinator.shared
        coordinator.reset()
        coordinator.register(try command("air india 123 report passing papa juliet"),
                             aircraftCallsign: "AIC123")
        XCTAssertEqual(coordinator.pendingCount, 1)

        for latitude in [28.40, 28.50, 28.58, 28.63, 28.70] {
            coordinator.advance(aircraft: [plane(at: latitude)],
                                allCallsigns: ["AIC123"],
                                fixes: [fix], runways: [])
        }
        XCTAssertEqual(coordinator.pendingCount, 0, "the report came due and was spoken")
        coordinator.reset()
    }

    func testCoordinatorKeepsTheReportWhileTheAircraftIsStillFlying() throws {
        let coordinator = DeferredReportCoordinator.shared
        coordinator.reset()
        coordinator.register(try command("air india 123 report passing papa juliet"),
                             aircraftCallsign: "AIC123")

        // Approaching but not yet past.
        for latitude in [28.30, 28.40, 28.50] {
            coordinator.advance(aircraft: [plane(at: latitude)],
                                allCallsigns: ["AIC123"],
                                fixes: [fix], runways: [])
        }
        XCTAssertEqual(coordinator.pendingCount, 1, "still owed")
        coordinator.reset()
    }

    func testCoordinatorForgetsReportsForAircraftThatHaveGone() throws {
        let coordinator = DeferredReportCoordinator.shared
        coordinator.reset()
        coordinator.register(try command("air india 123 report passing papa juliet"),
                             aircraftCallsign: "AIC123")

        coordinator.advance(aircraft: [], allCallsigns: ["BAW17"],
                            fixes: [fix], runways: [])
        XCTAssertEqual(coordinator.pendingCount, 0)
        coordinator.reset()
    }
}
