//
//  KeyboardCommandTests.swift
//  VectraProTests
//
//  The keypad and the microphone must not drift apart.
//
//  Before this, each keypad key built its own `AircraftCommand` — a third copy of
//  the vocabulary, after the parser and the feedback layer. The test that matters
//  here is the one asserting a tapped key and the equivalent spoken instruction
//  produce the same effect, because that is the property the old design could not
//  guarantee.
//

import XCTest
import ATCParserKit
import ATCSimKit
@testable import VectraPro

final class KeyboardCommandTests: XCTestCase {

    private var recognizer: CommandRecognizer!
    private var templates: TemplateSet!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VectraPro/Resources/CommandTemplates.json")
        templates = try TemplateSet(data: try Data(contentsOf: url))
        recognizer = CommandRecognizer(templates: templates)
    }

    /// What a keypad key produces, without the view model.
    private func keyEffects(_ key: String, values: [Int]) throws -> [AircraftCommand] {
        let binding = try XCTUnwrap(KeyboardCommandCatalog.command(for: key),
                                    "key \(key) is not bound to a code")
        let slots = StaticCommandSlots(integers: binding.slot.map { [$0: values] } ?? [:])
        guard case .commands(let effects) = CommandMapping.map(code: binding.code, slots: slots)
        else { return [] }
        return effects
    }

    /// What the same instruction produces when spoken.
    private func spokenEffects(_ transcript: String) -> [AircraftCommand] {
        recognizer.recognize(transcript).commands.flatMap { command -> [AircraftCommand] in
            guard case .commands(let effects) = CommandMapping.map(code: command.code,
                                                                   slots: command)
            else { return [] }
            return effects
        }
    }

    // MARK: - The two input paths agree

    func testKeypadAndSpeechProduceTheSameEffect() throws {
        let cases: [(key: String, values: [Int], spoken: String)] = [
            ("FH",     [270], "air india 123 fly heading 270"),
            ("TLH",    [270], "air india 123 turn left heading 270"),
            ("TRH",    [270], "air india 123 turn right heading 270"),
            ("T*DL",   [30],  "air india 123 turn left 30 degrees"),
            ("T*DR",   [30],  "air india 123 turn right 30 degrees"),
            ("FPH",    [],    "air india 123 continue present heading"),
            ("↑SPD*",  [300], "air india 123 increase speed to 300 knots"),
            ("↓SPD*",  [250], "air india 123 reduce speed to 250 knots"),
            ("SPD*",   [250], "air india 123 maintain 250 knots"),
            ("SPD≥*",  [250], "air india 123 maintain 250 knots or greater"),
            ("SPD≤*",  [250], "air india 123 maintain 250 knots or less"),
            ("C/M*",   [260], "air india 123 climb to flight level 260"),
            ("D/M*",   [200], "air india 123 descend to flight level 200"),
        ]

        for (key, values, spoken) in cases {
            XCTAssertEqual(try keyEffects(key, values: values),
                           spokenEffects(spoken),
                           "key \(key) and \"\(spoken)\" disagree")
        }
    }

    func testBlockAltitudeTakesBothValues() throws {
        XCTAssertEqual(try keyEffects("MBLK*-*", values: [260, 280]),
                       [.altitudeBlock(lowFeet: 26_000, highFeet: 28_000)])
    }

    // MARK: - Keypad metadata comes from the binding

    func testValueCounts() {
        XCTAssertEqual(KeyboardCommandCatalog.command(for: "MBLK*-*")?.valueCount, 2)
        XCTAssertEqual(KeyboardCommandCatalog.command(for: "FH")?.valueCount, 1)
        XCTAssertEqual(KeyboardCommandCatalog.command(for: "FPH")?.valueCount, 0)
    }

    // MARK: - Every bound key points at a template that exists

    func testEveryKeyIsBoundToARealTemplate() {
        for (key, binding) in KeyboardCommandCatalog.byKey {
            XCTAssertNotNil(templates.template(id: binding.code),
                            "key \(key) names code \(binding.code), which is not in the payload")
        }
    }

    func testEveryBoundKeyProducesAnEffect() throws {
        for (key, binding) in KeyboardCommandCatalog.byKey {
            let values = Array(repeating: sampleValue(for: binding.slot),
                               count: max(binding.valueCount, 0))
            XCTAssertFalse(try keyEffects(key, values: values).isEmpty,
                           "key \(key) is bound to \(binding.code) but produces nothing")
        }
    }

    private func sampleValue(for slot: String?) -> Int {
        switch slot {
        case "THREE DIGITS":      return 270
        case "NUMBER OF DEGREES": return 30
        case "NUMBER":            return 250
        case "LEVEL":             return 260
        default:                  return 0
        }
    }

    // MARK: - Readback

    func testTheKeypadNowGetsAnICAOReadback() throws {
        // Previously the keypad path produced no ICAO phraseology at all.
        let binding = try XCTUnwrap(KeyboardCommandCatalog.command(for: "TRH"))
        let template = try XCTUnwrap(templates.template(id: binding.code))
        let readback = ReadbackRenderer().render(
            template,
            values: ["THREE DIGITS": [.integer(250)]],
            callsign: "air india 123")

        XCTAssertEqual(readback.text,
                       "RADAR TURN RIGHT HEADING two five zero, air india one two three.")
    }
}
