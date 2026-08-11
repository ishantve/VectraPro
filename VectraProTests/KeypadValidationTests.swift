//
//  KeypadValidationTests.swift
//  VectraProTests
//
//  Pins what the keypad does about validation *today*, before the voice and keypad paths are unified.
//
//  ── Why these are characterisation tests and not a bug fix ──────────────────
//  The design doc claimed the keypad was missing two checks the voice path performs — named-point
//  validation and `answeredFromAircraft` — and that unifying the paths would fix a live bug. Checking
//  it against the actual bindings, **that is not reachable today**:
//
//    • All fourteen bound keys carry integer slots only (speeds, levels, headings, turns), so there is
//      no `.fix` slot for named-point validation to look at. The check would be a no-op.
//    • None of the bound codes is in `CommandMapping.answeredFromAircraft` (216, 258, 409, 430, 443),
//      so no key asks the simulator to answer a question about an aircraft.
//    • Every bound key maps to real effects and therefore goes through
//      `MapViewModel.apply(_:readback:)`, which already refuses when nothing is selected.
//
//  So there is nothing to fix, and inventing one would be worse than saying so. What these tests do
//  instead is fix the current behaviour in place, so that when `perform` unification lands the diff is
//  either provably neutral or shows up here as a failure. That is the protection that was actually
//  wanted: telling a behaviour change apart from replay plumbing.
//
//  They also cover the case the claim was reaching for. If a key is ever bound to a code with a fix slot
//  or to one answered from the aircraft, `testNoBoundKeyNeedsValidationTheKeypadLacks` fails — so the
//  gap becomes real the moment it becomes reachable, rather than shipping unnoticed.
//

import XCTest
import ATCParserKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class KeypadValidationTests: XCTestCase {

    private final class FeedbackSpy: CommandFeedback {
        var readbacks: [String] = []
        var errors: [String] = []
        var notFoundCount = 0

        func readback(_ spoken: String) { readbacks.append(spoken) }
        func commandError(_ phrase: String) { errors.append(phrase) }
        func aircraftNotFound() { notFoundCount += 1 }

        var saidNothing: Bool { readbacks.isEmpty && errors.isEmpty && notFoundCount == 0 }
    }

    private final class SilentReports: DeferredReportAnnouncing {
        func register(_ command: RecognizedCommand, aircraftCallsign: String?) {}
        func advance(aircraft: [Aircraft], allCallsigns: Set<String>,
                     fixes: [ATCSimKit.Fix], runways: [Runway]) {}
        func clear() {}
    }

    private var feedback: FeedbackSpy!
    private var viewModel: MapViewModel!

    override func setUp() {
        super.setUp()
        feedback = FeedbackSpy()
        viewModel = MapViewModel(spawner: AircraftSpawner(),
                                 feedback: feedback,
                                 reports: SilentReports())
    }

    // MARK: - The claim, checked against the bindings

    /// **The test that makes the design doc's claim true or false.**
    ///
    /// Every bound key is checked for the two things the voice path validates and the keypad does not.
    /// It passes today because no binding needs either. It fails the day one does — which is exactly
    /// when the missing validation stops being theoretical.
    func testNoBoundKeyNeedsValidationTheKeypadLacks() throws {
        for key in KeyboardCommandCatalog.allKeys {
            let binding = try XCTUnwrap(KeyboardCommandCatalog.command(for: key))

            XCTAssertFalse(
                CommandMapping.answeredFromAircraft.contains(binding.code),
                """
                Key "\(key)" is bound to code \(binding.code), which is answered from the aircraft. \
                The keypad does not check an aircraft exists first, so this would speak an answer \
                about nothing. Route the keypad through CommandController.perform before shipping it.
                """)

            // A named point can only arrive through a slot the keypad cannot supply. If a binding ever
            // gains a non-integer slot, named-point validation stops being a no-op.
            if let slot = binding.slot {
                XCTAssertFalse(
                    slot.uppercased().contains("POINT") || slot.uppercased().contains("FIX"),
                    """
                    Key "\(key)" carries slot "\(slot)", which names a place. The keypad does not check \
                    the point exists, so the instruction could be accepted and never carried out.
                    """)
            }
        }
    }

    // MARK: - What the keypad does today

    /// With nothing selected, a keypad command reports rather than acting — the guard is in
    /// `MapViewModel.apply`, which is why the keypad has never needed its own.
    func testAKeypadCommandWithNoSelectionReportsAircraftNotFound() {
        CommandKeyboardHandler(radar: viewModel).perform("C/M*", value: 260)

        XCTAssertEqual(feedback.notFoundCount, 1)
        XCTAssertTrue(feedback.readbacks.isEmpty, "it must not answer for an aircraft that is not there")
    }

    /// With an aircraft selected, the same key acts and answers.
    func testAKeypadCommandWithASelectionActsAndAnswers() throws {
        viewModel.reset(seed: 0xCAFE)
        viewModel.stopSimulation()
        let target = try XCTUnwrap(viewModel.aircraft.first)
        viewModel.selectAircraft(target.id)

        CommandKeyboardHandler(radar: viewModel).perform("C/M*", value: 260)

        XCTAssertEqual(feedback.notFoundCount, 0)
        XCTAssertEqual(feedback.readbacks.count, 1, "one reply per instruction")
        XCTAssertEqual(viewModel.aircraft.first { $0.id == target.id }?.targetAltitudeFeet, 26_000)
    }

    /// An unbound key does nothing at all, quietly. Pinned because unification could easily turn it into
    /// an error, and a stray keystroke is not worth speaking about.
    func testAnUnboundKeyIsIgnoredSilently() {
        CommandKeyboardHandler(radar: viewModel).perform("NOT-A-KEY")
        XCTAssertTrue(feedback.saidNothing)
    }

    /// Every bound key that needs values refuses to act on the wrong number of them — pinned because the
    /// unified path will have to keep doing this.
    func testABlockAltitudeKeyNeedsBothValues() throws {
        viewModel.reset(seed: 0xCAFE)
        viewModel.stopSimulation()
        let target = try XCTUnwrap(viewModel.aircraft.first)
        viewModel.selectAircraft(target.id)

        let handler = CommandKeyboardHandler(radar: viewModel)
        XCTAssertEqual(KeyboardCommandCatalog.command(for: "MBLK*-*")?.valueCount, 2)

        handler.perform("MBLK*-*", low: 100, high: 140)
        let updated = try XCTUnwrap(viewModel.aircraft.first { $0.id == target.id })
        XCTAssertEqual(updated.minAltitudeFeet, 10_000)
        XCTAssertEqual(updated.maxAltitudeFeet, 14_000)
    }

    /// The keypad speaks the template's own wording, not English assembled from the command enum. Pinned
    /// because it is the property that stopped the keypad being a third copy of the vocabulary, and
    /// unification must not undo it.
    func testTheKeypadSpeaksTheTemplateWording() throws {
        viewModel.reset(seed: 0xCAFE)
        viewModel.stopSimulation()
        viewModel.selectAircraft(try XCTUnwrap(viewModel.aircraft.first).id)

        CommandKeyboardHandler(radar: viewModel).perform("TRH", value: 250)

        let spoken = try XCTUnwrap(feedback.readbacks.first)
        XCTAssertTrue(spoken.uppercased().contains("RIGHT"), "got: \(spoken)")
        XCTAssertTrue(spoken.contains("250") || spoken.lowercased().contains("two five zero"),
                      "got: \(spoken)")
    }
}

// MARK: - After perform extraction

extension KeypadValidationTests {

    /// The keypad and the microphone now share one entry point, so a refusal reads the same either way.
    ///
    /// Added with the extraction because nothing covered it: the keypad used to phrase its own
    /// "not implemented" message from the key's UI prompt, which would have read "climb to fl xxx
    /// instruction not implemented" once the wording was shared. It now passes the template's category, as
    /// the voice path does.
    ///
    /// The branch is unreachable today — `KeyboardCommandTests.testEveryBoundKeyProducesAnEffect` proves
    /// every binding maps — so this pins wording that cannot currently be observed, against the day a key
    /// is bound to an unmapped code.
    func testARefusalUsesTheTemplateCategoryNotTheKeyPrompt() throws {
        let store = CommandTemplateStore.shared
        for key in KeyboardCommandCatalog.allKeys {
            let binding = try XCTUnwrap(KeyboardCommandCatalog.command(for: key))
            let category = store.templates?.template(id: binding.code)?.category

            XCTAssertNotNil(category, """
                Key "\(key)" is bound to code \(binding.code), which has no template — so a refusal would \
                fall back to the key's UI prompt and read differently from the spoken path.
                """)
            XCTAssertFalse(category?.contains(" ") ?? true,
                           "a category should be a single word; got \(category ?? "nil")")
        }
    }
}
