//
//  CommandSliceTests.swift
//  VectraProTests
//
//  The contract this whole rewrite rests on, exercised end to end:
//
//      transcript → CommandRecognizer → code + slots
//                 → CommandMapping    → [AircraftCommand]
//                 → ReadbackComposer  → one spoken reply
//
//  Each layer has its own tests inside its own package. What none of them can
//  check is that the layers actually fit — that ATCSimKit's `CommandSlots` reads
//  what the parser produced, and that a transcript comes out the other end as both
//  aircraft behaviour and ICAO phraseology. That is what these cover, and it is
//  why they were written before mapping the remaining thirty-five codes.
//

import XCTest
import CoreLocation
import ATCParserKit
import ATCSimKit
@testable import VectraPro

final class CommandSliceTests: XCTestCase {

    private var recognizer: CommandRecognizer!

    override func setUpWithError() throws {
        // Read the payload from the repository rather than a bundle, so the test
        // does not depend on how resources happen to be packaged.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VectraPro/Resources/CommandTemplates.json")
        let set = try TemplateSet(data: try Data(contentsOf: url))
        recognizer = CommandRecognizer(templates: set)
    }

    /// Everything the controller layer does, minus the view model.
    private func effectsAndReadback(_ transcript: String)
    -> (effects: [AircraftCommand], readback: String?, callsign: String?) {
        let result = recognizer.recognize(transcript)
        var effects: [AircraftCommand] = []
        var spoken: [RecognizedCommand] = []

        for command in result.commands {
            guard command.outcome == .ok || command.outcome == .disabled else { continue }
            if command.outcome == .disabled {
                spoken.append(command)
                continue
            }
            switch CommandMapping.map(code: command.code, slots: command) {
            case .commands(let mapped):
                effects.append(contentsOf: mapped)
                spoken.append(command)
            case .communicationOnly:
                spoken.append(command)
            case .unmapped:
                continue
            }
        }
        let callsign = result.commands.first?.callsign
        return (effects, ReadbackComposer.compose(spoken, callsign: callsign), callsign)
    }

    // MARK: - The vectoring slice

    func testSingleVectorBecomesBehaviourAndPhraseology() {
        let (effects, readback, callsign) = effectsAndReadback(
            "air india 123 turn right heading 250")

        XCTAssertEqual(effects, [.headingTurn(250, .right)])
        XCTAssertEqual(callsign, "air india 123")
        XCTAssertEqual(readback,
                       "RADAR TURN RIGHT HEADING two five zero, air india one two three")
    }

    func testSeveralVectorsInOneTransmission() {
        let (effects, readback, _) = effectsAndReadback(
            "air india 123 turn left heading 270 then stop turn heading 300")

        XCTAssertEqual(effects, [.headingTurn(270, .left), .stopTurn(300)])
        // One reply, callsign once, at the end.
        XCTAssertEqual(readback, """
            RADAR TURN LEFT HEADING two seven zero, \
            RADAR STOP TURN HEADING three zero zero, air india one two three
            """)
    }

    func testRelativeTurnReachesThePhysicsLayerAtLast() {
        // The enum case and the physics existed all along; nothing ever produced it.
        let (effects, _, _) = effectsAndReadback("air india 123 turn left 30 degrees")
        XCTAssertEqual(effects, [.relativeTurn(30, .left)])
    }

    func testSpokenNumbersSurviveTheWholeChain() {
        let (effects, readback, _) = effectsAndReadback(
            "air india one two three fly heading two seven zero")
        XCTAssertEqual(effects, [.heading(270)])
        XCTAssertEqual(readback,
                       "RADAR FLY HEADING two seven zero, air india one two three")
    }

    // MARK: - Several aircraft

    func testTwoAircraftInOneTransmissionStayApart() {
        let result = recognizer.recognize(
            "air india 123 turn right heading 250, baw17 turn left heading 090")
        let groups = result.groupedByCallsign()

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].callsign, "air india 123")
        XCTAssertEqual(groups[1].callsign, "baw17")

        // Each aircraft's own instruction, not the other's.
        XCTAssertEqual(CommandMapping.map(code: groups[0].commands[0].code,
                                          slots: groups[0].commands[0]),
                       .commands([.headingTurn(250, .right)]))
        XCTAssertEqual(CommandMapping.map(code: groups[1].commands[0].code,
                                          slots: groups[1].commands[0]),
                       .commands([.headingTurn(90, .left)]))
    }

    // MARK: - The other three outcome paths

    func testCommunicationOnlyPhraseAnswersWithoutDoingAnything() {
        let (effects, readback, _) = effectsAndReadback("air india 123 standby")
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(readback, "STANDING BY, air india one two three")
    }

    func testAPhraseNeedingNoReadbackProducesNeitherEffectNorSpeech() {
        let (effects, readback, _) = effectsAndReadback("air india 123 roger")
        XCTAssertTrue(effects.isEmpty)
        XCTAssertNil(readback)
    }

    func testDisabledPhraseIsAnsweredButNotActedOn() {
        let (effects, readback, _) = effectsAndReadback(
            "air india 123 radar service terminated due weather")
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(readback, "UNABLE, air india one two three")
    }

    func testIllegalValueProducesNoEffect() {
        let result = recognizer.recognize("air india 123 fly heading 450")
        let command = result.commands.first
        XCTAssertEqual(command?.outcome,
                       .invalidValue(slot: "THREE DIGITS", value: .integer(450)))

        let (effects, _, _) = effectsAndReadback("air india 123 fly heading 450")
        XCTAssertTrue(effects.isEmpty, "an out-of-range heading must never be applied")
    }

    func testUnmappedButRecognisedPhraseIsNotMistakenForSuccess() throws {
        // "GO AROUND" is recognised phraseology the simulator has no behaviour for
        // yet. It must report as unmapped rather than quietly doing nothing, which
        // would be indistinguishable from a command that worked.
        let result = recognizer.recognize("air india 123 go around")
        let command = try XCTUnwrap(result.commands.first)
        XCTAssertEqual(command.code, "327")
        XCTAssertEqual(command.outcome, .ok)
        XCTAssertEqual(CommandMapping.map(code: "327", slots: command), .unmapped)
    }

    // MARK: - Routing, level off, transponder

    func testProceedDirectRoutesWithoutHolding() {
        let (effects, readback, _) = effectsAndReadback(
            "air india 123 proceed direct to papa juliet")
        XCTAssertEqual(effects, [.proceedDirect(fix: "PJ")])
        XCTAssertEqual(readback,
                       "PROCEED DIRECT TO papa juliet, air india one two three")
    }

    func testHoldClearanceCarriesBothInstructions() {
        let (effects, _, _) = effectsAndReadback(
            "air india 123 proceed direct to papa juliet ndb and hold as published maintain flight level 260")
        XCTAssertEqual(effects, [.hold("PJ"), .altitude(feet: 26_000)])
    }

    func testLevelOffReachesTheAircraft() {
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        aircraft.altitudeFeet = 24_000
        AircraftPhysics.shared.apply(
            effectsAndReadback("air india 123 climb to flight level 300").effects,
            to: &aircraft)
        AircraftPhysics.shared.apply(
            effectsAndReadback("air india 123 stop climb at flight level 260").effects,
            to: &aircraft)
        XCTAssertEqual(aircraft.targetAltitudeFeet, 26_000)
    }

    func testSquawkSetsTheTransponder() {
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        let (effects, readback, _) = effectsAndReadback("air india 123 squawk 4567")
        AircraftPhysics.shared.apply(effects, to: &aircraft)

        XCTAssertEqual(aircraft.squawk, "4567")
        XCTAssertEqual(readback, "SQUAWK four five six seven, air india one two three")
    }

    // MARK: - Vertical and speed, end to end

    func testFlightLevelBecomesFeetAndReadsBackAsAFlightLevel() {
        let (effects, readback, _) = effectsAndReadback(
            "air india 123 descend to flight level 260")
        // One representation inside, the spoken form from the template.
        XCTAssertEqual(effects, [.altitude(feet: 26_000)])
        XCTAssertEqual(readback,
                       "RADAR DESCEND TO FLIGHT LEVEL two six zero, air india one two three")
    }

    func testFeetAltitudeReadsBackAsFeet() {
        let (effects, readback, _) = effectsAndReadback(
            "air india 123 climb to eight thousand feet")
        XCTAssertEqual(effects, [.altitude(feet: 8000)])
        XCTAssertEqual(readback,
                       "RADAR CLIMB TO eight thousand FEET, air india one two three")
    }

    func testBlockMixingUnitsResolvesToOneRange() {
        let (effects, _, _) = effectsAndReadback(
            "air india 123 climb to and maintain block eight thousand feet to flight level 260")
        XCTAssertEqual(effects, [.altitudeBlock(lowFeet: 8000, highFeet: 26_000)])
    }

    func testSpeedControl() {
        XCTAssertEqual(effectsAndReadback("air india 123 reduce speed to 250 knots").effects,
                       [.speed(250)])
        XCTAssertEqual(effectsAndReadback("air india 123 maintain 250 knots or greater").effects,
                       [.minSpeed(250)])
        XCTAssertEqual(effectsAndReadback("air india 123 do not exceed 250 knots").effects,
                       [.maxSpeed(250)])
    }

    func testTheOriginalThreeInstructionTransmission() {
        // The example this whole rewrite started from.
        let (effects, readback, callsign) = effectsAndReadback(
            "Air india 123 climb and maintain FL260, increase speed to 300 knots, turn right heading 250")

        XCTAssertEqual(effects, [.altitude(feet: 26_000),
                                 .speed(300),
                                 .headingTurn(250, .right)])
        XCTAssertEqual(callsign, "air india 123")
        XCTAssertEqual(readback, """
            RADAR CLIMB TO FLIGHT LEVEL two six zero, \
            RADAR INCREASE SPEED TO three zero zero KNOTS, \
            RADAR TURN RIGHT HEADING two five zero, air india one two three
            """)
    }

    func testAltitudeAndSpeedReachThePhysicsLayer() {
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        let (effects, _, _) = effectsAndReadback(
            "air india 123 descend to flight level 200 reduce speed to 220 knots")
        AircraftPhysics.shared.apply(effects, to: &aircraft)

        XCTAssertEqual(aircraft.targetAltitudeFeet, 20_000)
        XCTAssertEqual(aircraft.targetSpeedKnots, 220)
    }

    // MARK: - Applied behaviour

    func testCommandsActuallyMoveTheAircraft() {
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        let (effects, _, _) = effectsAndReadback("air india 123 turn right heading 250")
        AircraftPhysics.shared.apply(effects, to: &aircraft)

        XCTAssertEqual(aircraft.targetHeading, 250)
        XCTAssertEqual(aircraft.turnDirection, .right)
    }

    // MARK: - Unrecognised speech

    func testChatterIsReportedRatherThanSwallowed() {
        let result = recognizer.recognize(
            "air india 123 turn right heading 250 and have a good flight")
        XCTAssertEqual(result.commands.count, 1)
        XCTAssertFalse(result.unrecognized.isEmpty)
    }
}
