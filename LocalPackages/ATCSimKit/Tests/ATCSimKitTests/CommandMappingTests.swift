//
//  CommandMappingTests.swift
//  ATCSimKit
//
//  The seam between phraseology codes and aircraft behaviour.
//
//  The coverage test at the bottom is the important one: it prints every code in
//  the payload that has no mapping and is not deliberately effect-free, so the
//  remaining work is an explicit list. A silent gap here is indistinguishable from
//  a command that worked.
//

import XCTest
@testable import ATCSimKit

final class CommandMappingTests: XCTestCase {

    private func map(_ code: String,
                     integers: [String: [Int]] = [:],
                     texts: [String: [String]] = [:]) -> CommandMapping.Result {
        CommandMapping.map(code: code,
                           slots: StaticCommandSlots(integers: integers, texts: texts))
    }

    // MARK: - Vectoring

    func testFlyHeading() {
        XCTAssertEqual(map("245", integers: ["THREE DIGITS": [270]]),
                       .commands([.heading(270)]))
    }

    func testTurnLeftAndRightCarryTheirDirection() {
        XCTAssertEqual(map("246", integers: ["THREE DIGITS": [270]]),
                       .commands([.headingTurn(270, .left)]))
        XCTAssertEqual(map("247", integers: ["THREE DIGITS": [270]]),
                       .commands([.headingTurn(270, .right)]))
    }

    func testRelativeTurns() {
        // This pair was dead in the old parser: the enum case existed, the
        // physics handled it, but nothing ever produced it.
        XCTAssertEqual(map("250", integers: ["NUMBER OF DEGREES": [30]]),
                       .commands([.relativeTurn(30, .left)]))
        XCTAssertEqual(map("251", integers: ["NUMBER OF DEGREES": [30]]),
                       .commands([.relativeTurn(30, .right)]))
    }

    func testPresentHeading() {
        XCTAssertEqual(map("243"), .commands([.presentHeading]))
    }

    func testStopTurn() {
        XCTAssertEqual(map("254", integers: ["THREE DIGITS": [270]]),
                       .commands([.stopTurn(270)]))
    }

    func testHeading360BecomesZero() {
        XCTAssertEqual(map("245", integers: ["THREE DIGITS": [360]]),
                       .commands([.heading(0)]))
    }

    // MARK: - Missing values

    func testAMappingWithoutItsValueIsUnmappedNotSilent() {
        // "fly heading" with no heading must not quietly become a no-op.
        XCTAssertEqual(map("245"), .unmapped)
    }

    // MARK: - Vertical

    func testFlightLevelsBecomeFeet() {
        // The aircraft flies feet; the flight level is only how it was said.
        for code in ["101", "158", "184", "219"] {
            XCTAssertEqual(map(code, integers: ["LEVEL": [260]]),
                           .commands([.altitude(feet: 26_000)]), "code \(code)")
        }
    }

    func testFeetAltitudesPassStraightThrough() {
        for code in ["102", "159", "185", "220"] {
            XCTAssertEqual(map(code, integers: ["ALTITUDE": [8000]]),
                           .commands([.altitude(feet: 8000)]), "code \(code)")
        }
    }

    func testBlockInFlightLevels() {
        XCTAssertEqual(map("103", integers: ["LEVEL": [260, 280]]),
                       .commands([.altitudeBlock(lowFeet: 26_000, highFeet: 28_000)]))
        XCTAssertEqual(map("235", integers: ["LEVEL": [260, 280]]),
                       .commands([.altitudeBlock(lowFeet: 26_000, highFeet: 28_000)]))
    }

    func testBlockInFeet() {
        XCTAssertEqual(map("104", integers: ["ALTITUDE": [8000, 9000]]),
                       .commands([.altitudeBlock(lowFeet: 8000, highFeet: 9000)]))
    }

    func testBlockMixingFeetAndFlightLevel() {
        // "BLOCK 8000 FEET TO FLIGHT LEVEL 260" — the two ends use different units,
        // which one feet-based representation absorbs.
        XCTAssertEqual(map("105", integers: ["ALTITUDE": [8000], "LEVEL": [260]]),
                       .commands([.altitudeBlock(lowFeet: 8000, highFeet: 26_000)]))
        XCTAssertEqual(map("237", integers: ["ALTITUDE": [8000], "LEVEL": [260]]),
                       .commands([.altitudeBlock(lowFeet: 8000, highFeet: 26_000)]))
    }

    func testBlockNeedsBothEnds() {
        // Half a block is not a usable clearance.
        XCTAssertEqual(map("103", integers: ["LEVEL": [260]]), .unmapped)
    }

    func testBlockEndsAreOrderedRegardlessOfHowTheyWereSaid() {
        XCTAssertEqual(map("103", integers: ["LEVEL": [280, 260]]),
                       .commands([.altitudeBlock(lowFeet: 26_000, highFeet: 28_000)]))
    }

    // MARK: - Speed

    func testSpeedPhrasings() {
        XCTAssertEqual(map("344", integers: ["NUMBER": [250]]), .commands([.speed(250)]))
        XCTAssertEqual(map("359", integers: ["NUMBER": [300]]), .commands([.speed(300)]))
        XCTAssertEqual(map("361", integers: ["NUMBER": [220]]), .commands([.speed(220)]))
        XCTAssertEqual(map("346", integers: ["NUMBER": [250]]), .commands([.minSpeed(250)]))
    }

    func testTwoPhrasingsOfTheSameCeiling() {
        // "or less" and "do not exceed" are one effect said two ways; the separate
        // codes exist so each gets its own readback.
        XCTAssertEqual(map("348", integers: ["NUMBER": [250]]), .commands([.maxSpeed(250)]))
        XCTAssertEqual(map("356", integers: ["NUMBER": [250]]), .commands([.maxSpeed(250)]))
    }

    // MARK: - Approach

    func testInterceptLocalizer() {
        XCTAssertEqual(map("454", texts: ["NUMBER": ["27L"]]),
                       .commands([.interceptLocalizer(runway: "27L")]))
    }

    // MARK: - Effect-free phraseology

    func testCommunicationOnlyIsNotAFailure() {
        for code in ["435", "432", "444", "316", "448", "430"] {
            XCTAssertEqual(map(code), .communicationOnly, "code \(code)")
        }
    }

    func testUnknownCodeIsReportedAsUnmapped() {
        XCTAssertEqual(map("999"), .unmapped)
    }

    func testCategoryDoesNotDecideWhetherSomethingIsActionable() {
        // Both live under "genphrase": one is chatter, one re-routes the aircraft.
        XCTAssertEqual(map("444"), .communicationOnly)   // DISREGARD
        XCTAssertEqual(map("445", texts: ["WAYPOINT/FIX": ["PJ"]]),
                       .commands([.proceedDirect(fix: "PJ")]))

        // And the reverse: 122/123 sit under "climb" but ask another control unit
        // for a level change — nothing happens to this aircraft.
        XCTAssertEqual(map("122"), .communicationOnly)
        XCTAssertEqual(map("123"), .communicationOnly)
    }

    func testLevelOffIsItsOwnInstruction() {
        // Not `altitude`: "stop climb at FL260" must never descend an aircraft that
        // is already above 260.
        XCTAssertEqual(map("124", integers: ["LEVEL": [260]]),
                       .commands([.stopClimb(atFeet: 26_000)]))
        XCTAssertEqual(map("125", integers: ["ALTITUDE": [8000]]),
                       .commands([.stopClimb(atFeet: 8000)]))
        XCTAssertEqual(map("182", integers: ["LEVEL": [260]]),
                       .commands([.stopDescent(atFeet: 26_000)]))
        XCTAssertEqual(map("183", integers: ["ALTITUDE": [8000]]),
                       .commands([.stopDescent(atFeet: 8000)]))
    }

    // MARK: - One phrase, several instructions

    func testHoldClearanceProducesBothInstructions() {
        // "PROCEED DIRECT TO PJ … AND HOLD AS PUBLISHED, MAINTAIN FL260" is two
        // things at once — the reason mapping returns a list.
        XCTAssertEqual(map("453", integers: ["LEVEL": [260]], texts: ["HOLDING FIX": ["PJ"]]),
                       .commands([.hold("PJ"), .altitude(feet: 26_000)]))
    }

    func testHoldClearanceNeedsBothParts() {
        XCTAssertEqual(map("453", texts: ["HOLDING FIX": ["PJ"]]), .unmapped)
    }

    // MARK: - Routing and transponder

    func testProceedDirectAndGoToAreTheSameEffect() {
        XCTAssertEqual(map("445", texts: ["WAYPOINT/FIX": ["PJ"]]),
                       .commands([.proceedDirect(fix: "PJ")]))
        XCTAssertEqual(map("446", texts: ["WAYPOINT/FIX": ["PJ"]]),
                       .commands([.proceedDirect(fix: "PJ")]))
    }

    func testSquawk() {
        XCTAssertEqual(map("218", texts: ["CODE": ["4567"]]),
                       .commands([.squawk(code: "4567")]))
        // Asking an aircraft to confirm its squawk changes nothing.
        XCTAssertEqual(map("216"), .communicationOnly)
    }

    func testApproachClearanceAndLocalizerInterceptShareOneBehaviour() {
        // The simulator tracks the centreline in either way; the difference between
        // the two phrases survives in the readback, not here.
        let expected = CommandMapping.Result.commands([.interceptLocalizer(runway: "27L")])
        XCTAssertEqual(map("454", texts: ["NUMBER": ["27L"]]), expected)
        XCTAssertEqual(map("376", texts: ["NUMBER": ["27L"]]), expected)
    }

    // MARK: - Level-off behaviour

    func testStopClimbOnlyRemovesClimb() {
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        aircraft.altitudeFeet = 24_000
        AircraftPhysics.shared.apply([.altitude(feet: 30_000)], to: &aircraft)
        AircraftPhysics.shared.apply([.stopClimb(atFeet: 26_000)], to: &aircraft)
        XCTAssertEqual(aircraft.targetAltitudeFeet, 26_000)
    }

    func testStopClimbAboveTheLevelHoldsCurrentAltitudeRatherThanDescending() {
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        aircraft.altitudeFeet = 27_000
        AircraftPhysics.shared.apply([.altitude(feet: 30_000)], to: &aircraft)
        AircraftPhysics.shared.apply([.stopClimb(atFeet: 26_000)], to: &aircraft)
        // Level off where it is — never turned into a descent.
        XCTAssertEqual(aircraft.targetAltitudeFeet, 27_000)
    }

    func testStopClimbDoesNothingToAnAircraftThatIsNotClimbing() {
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        aircraft.altitudeFeet = 27_000
        AircraftPhysics.shared.apply([.altitude(feet: 20_000)], to: &aircraft)
        AircraftPhysics.shared.apply([.stopClimb(atFeet: 26_000)], to: &aircraft)
        XCTAssertEqual(aircraft.targetAltitudeFeet, 20_000, "a descent must be left alone")
    }

    func testStopDescentMirrorsIt() {
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        aircraft.altitudeFeet = 30_000
        AircraftPhysics.shared.apply([.altitude(feet: 20_000)], to: &aircraft)
        AircraftPhysics.shared.apply([.stopDescent(atFeet: 26_000)], to: &aircraft)
        XCTAssertEqual(aircraft.targetAltitudeFeet, 26_000)
    }

    // MARK: - Direct routing

    func testProceedDirectSteersWithoutEnteringAHold() {
        let fix = Fix(fixName: "PJ", type: "HOLDING", latitude: 29.0, longitude: 77.1)
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 270)
        AircraftPhysics.shared.apply([.proceedDirect(fix: "PJ")], to: &aircraft)
        XCTAssertEqual(aircraft.directToFix, "PJ")
        XCTAssertNil(aircraft.holdingTargetName, "a re-route must not arm a hold")

        DirectRouteController.steer(&aircraft, fixes: [fix])
        // The fix is due north.
        XCTAssertEqual(aircraft.targetHeading ?? -1, 0, accuracy: 1)
    }

    func testArrivingAtTheFixReleasesTheAircraftOnItsPresentHeading() {
        let fix = Fix(fixName: "PJ", type: "HOLDING", latitude: 28.5, longitude: 77.1)
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        AircraftPhysics.shared.apply([.proceedDirect(fix: "PJ")], to: &aircraft)

        XCTAssertTrue(DirectRouteController.releaseOnArrival(&aircraft, fixes: [fix]))
        XCTAssertNil(aircraft.directToFix)
        XCTAssertNil(aircraft.targetHeading, "carries on as it arrived")
    }

    // MARK: - stopTurn behaviour

    func testStopTurnKeepsTheTurnDirectionAlreadyInProgress() {
        // The point of a separate case: `heading` would clear the direction and
        // take the shortest way round, which can reverse a turn in progress.
        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 350)
        AircraftPhysics.shared.apply([.headingTurn(180, .right)], to: &aircraft)
        XCTAssertEqual(aircraft.turnDirection, .right)

        AircraftPhysics.shared.apply([.stopTurn(30)], to: &aircraft)
        XCTAssertEqual(aircraft.targetHeading, 30)
        XCTAssertEqual(aircraft.turnDirection, .right, "stopTurn must not drop the direction")
    }

    func testStopTurnCountsAsAHeadingInstructionForConflicts() {
        let aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        let context = CommandValidator.Context(runways: [],
                                               activeLocalizerRunways: [],
                                               holdingFixes: [])
        XCTAssertEqual(CommandValidator.validate([.presentHeading, .stopTurn(270)],
                                                 for: aircraft, context: context),
                       .rejected("Unable, conflicting heading instructions"))
    }

    // MARK: - Clearances

    func testTakeoffClearanceIsRecordedNotPerformed() {
        // The scene, not the physics, puts an aircraft on a runway — so the command
        // records the clearance and stops. Same division `hold` uses.
        XCTAssertEqual(map("436", texts: ["NUMBER": ["27L"]]),
                       .commands([.clearedForTakeoff(runway: "27L")]))

        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 90)
        AircraftPhysics.shared.apply([.clearedForTakeoff(runway: "27L")], to: &aircraft)
        XCTAssertEqual(aircraft.pendingTakeoffRunway, "27L")
        XCTAssertNil(aircraft.takeoffState, "rolling is the scene's decision, not this one")
    }

    func testGoAroundTakesTheAircraftOffTheApproach() {
        XCTAssertEqual(map("327"), .commands([.goAround]))

        var aircraft = Aircraft(callsign: "AIC123",
                                position: .init(latitude: 28.5, longitude: 77.1),
                                headingDegrees: 270)
        aircraft.altitudeFeet = 2000
        AircraftPhysics.shared.apply([.interceptLocalizer(runway: "27L")], to: &aircraft)
        AircraftPhysics.shared.apply([.goAround], to: &aircraft)

        // Dropping the localizer is what removes it from the landing sequence.
        XCTAssertNil(aircraft.interceptRunway)
        XCTAssertEqual(aircraft.targetAltitudeFeet,
                       AircraftPhysics.missedApproachAltitudeFeet)
    }

    func testATakeoffClearanceIsOnlyForADeparture() {
        var arrival = Aircraft(callsign: "AIC123",
                               position: .init(latitude: 28.5, longitude: 77.1),
                               headingDegrees: 90)
        arrival.category = .arrival
        let context = CommandValidator.Context(runways: [], activeLocalizerRunways: [],
                                               holdingFixes: [])
        guard case .rejected = CommandValidator.validate([.clearedForTakeoff(runway: nil)],
                                                         for: arrival, context: context) else {
            return XCTFail("an arrival cannot be cleared for takeoff")
        }
    }

    // MARK: - Coverage

    /// Every code in the payload, by category. Kept here rather than read from the
    /// parser's fixture so this package needs no dependency on it; the parser's own
    /// inventory test is what guards the counts.
    private static let payloadCodes: [String: [String]] = [
        "reports": ["316", "317", "318", "319", "320"],
        "climb": ["101", "102", "103", "104", "105", "122", "123", "124", "125"],
        "departure": ["304"],
        "descend": ["158", "159", "182", "183", "184", "185"],
        "identification": ["258", "264"],
        "levelcheck": ["430"],
        "maintain": ["219", "220", "235", "236", "237"],
        "missed": ["327"],
        "radarterm": ["449"],
        "freqtransfer": ["448"],
        "squawk": ["216", "218"],
        "vectoring": ["243", "245", "246", "247", "250", "251", "254"],
        "vectorapproach": ["267"],
        "ilsvectoring": ["405", "406", "407", "408", "409", "410", "411", "412"],
        "speedcontrol": ["344", "346", "348", "356", "359", "361"],
        "pressurealt": ["371", "372"],
        "qnhtrans": ["431"],
        "standby": ["432", "433", "434"],
        "roger": ["435"],
        "termpressalt": ["437"],
        "genphrase": ["442", "443", "444", "445", "446"],
        "hold": ["453"],
        "approach": ["376", "454"],
        "takeoffclr": ["436"],
    ]

    func testEveryVectoringCodeIsMapped() {
        for code in Self.payloadCodes["vectoring"] ?? [] {
            let result = CommandMapping.map(
                code: code,
                slots: StaticCommandSlots(integers: ["THREE DIGITS": [270],
                                                     "NUMBER OF DEGREES": [30]]))
            guard case .commands(let commands) = result, !commands.isEmpty else {
                return XCTFail("vectoring code \(code) is not mapped: \(result)")
            }
        }
    }

    /// Not a pass/fail gate — the printed list is the remaining fan-out work.
    func testPrintUnmappedActionableCodes() {
        var remaining: [(String, String)] = []
        for category in Self.payloadCodes.keys.sorted() {
            for code in Self.payloadCodes[category] ?? [] {
                let result = CommandMapping.map(
                    code: code,
                    slots: StaticCommandSlots(
                        integers: ["THREE DIGITS": [270], "NUMBER OF DEGREES": [30],
                                   "LEVEL": [260, 280], "ALTITUDE": [8000, 9000],
                                   "NUMBER": [250], "CODE": [4567]],
                        texts: ["HOLDING FIX": ["PJ"], "WAYPOINT/FIX": ["PJ"],
                                "SIGNIFICANT POINT": ["PJ"], "NUMBER": ["27L"],
                                "CODE": ["4567"]]))
                if result == .unmapped { remaining.append((category, code)) }
            }
        }
        print("── actionable codes still unmapped (\(remaining.count)) ──")
        for (category, code) in remaining { print("   \(category)/\(code)") }
    }
}
