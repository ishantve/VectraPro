//
//  CommandParserTests.swift
//  VectraProTests
//
//  Voice-command parsing: normalisation, digit-word expansion, and each
//  command family (heading, level/block, speed, hold, intercept). Pure logic.
//

import Testing
@testable import VectraPro

@MainActor
struct CommandParserTests {

    private func parse(_ raw: String) -> [AircraftCommand] {
        CommandParser.parse(CommandParser.normalize(raw))
    }

    // MARK: normalize

    @Test func normalizeDropsPunctuationAndLowercases() {
        #expect(CommandParser.normalize("Turn LEFT, heading 270.") == "turn left heading 270")
    }

    @Test func normalizeExpandsSpokenDigits() {
        #expect(CommandParser.normalize("flight level two five zero") == "flight level 250")
        #expect(CommandParser.normalize("heading zero niner zero") == "heading 090")
    }

    // MARK: heading

    @Test func headingAbsolute() {
        #expect(parse("fly heading 090") == [.heading(90)])
    }

    @Test func headingWithForcedTurnDirection() {
        #expect(parse("turn left heading 270") == [.headingTurn(270, .left)])
        #expect(parse("turn right heading 010") == [.headingTurn(10, .right)])
    }

    @Test func heading360NormalisesToZero() {
        #expect(parse("fly heading 360") == [.heading(0)])
    }

    // MARK: flight level / block

    @Test func flightLevelClimbDescend() {
        #expect(parse("climb flight level 250") == [.flightLevel(250)])
        #expect(parse("descend flight level one zero zero") == [.flightLevel(100)])
    }

    @Test func flightLevelShorthand() {
        #expect(parse("fl250") == [.flightLevel(250)])
    }

    @Test func altitudeBlockOrdersLowHigh() {
        #expect(parse("maintain block flight level 120 through 100") == [.altitudeBlock(low: 100, high: 120)])
    }

    // MARK: speed

    @Test func speedExact() {
        #expect(parse("reduce speed 210") == [.speed(210)])
        #expect(parse("maintain 250 knots") == [.speed(250)])
    }

    @Test func speedFloorAndCeiling() {
        #expect(parse("maintain 250 knots or greater") == [.minSpeed(250)])
        #expect(parse("do not exceed 280") == [.maxSpeed(280)])
    }

    // MARK: hold

    @Test func holdFoldsPhoneticToCode() {
        #expect(parse("hold at papa juliet") == [.hold("PJ")])
        #expect(parse("hold at bravo romeo") == [.hold("BR")])
        #expect(parse("hold at romeo echo 01") == [.hold("RE01")])
    }

    @Test func holdKeepsPlainFixNameAsIs() {
        #expect(parse("hold at clink") == [.hold("clink")])
    }

    // MARK: intercept localizer

    @Test func interceptLocalizerWithSide() {
        #expect(parse("intercept the localizer runway 27 left") == [.interceptLocalizer(runway: "27L")])
        #expect(parse("intercept localizer runway 9") == [.interceptLocalizer(runway: "9")])
    }

    // MARK: multiple commands in one transcript

    @Test func multipleCommandsParseTogether() {
        let cmds = parse("descend flight level 100 reduce speed 210")
        #expect(cmds.contains(.flightLevel(100)))
        #expect(cmds.contains(.speed(210)))
    }

    @Test func gibberishYieldsNoCommands() {
        #expect(parse("good morning tower").isEmpty)
    }
}
