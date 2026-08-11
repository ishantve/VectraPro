//
//  SideEffectBoundaryTests.swift
//  VectraProTests
//
//  Two things: that suppression works, and that nothing can quietly bypass it.
//
//  The second is a source scan, which is unusual in a test suite and is the only thing that can enforce
//  this rule. A side effect added by reaching for a singleton compiles, runs, and behaves correctly in a
//  live exercise — the failure only appears the day someone scrubs a replay and hears forty readbacks, or
//  a year later when reviewing a session inflates its own analytics. There is no runtime assertion that
//  catches "somebody called a global"; there is a grep.
//

import XCTest
import ATCParserKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class SideEffectBoundaryTests: XCTestCase {

    private final class FeedbackSpy: CommandFeedback {
        var readbacks: [String] = []
        var errors: [String] = []
        var notFoundCount = 0

        func readback(_ spoken: String) { readbacks.append(spoken) }
        func commandError(_ phrase: String) { errors.append(phrase) }
        func aircraftNotFound() { notFoundCount += 1 }

        var total: Int { readbacks.count + errors.count + notFoundCount }
    }

    // MARK: - The gate

    func testLiveModeLetsEverythingThrough() {
        let spy = FeedbackSpy()
        let gate = SideEffectGate(presentation: spy, mode: .live)

        gate.readback("CLIMBING TO FLIGHT LEVEL 260")
        gate.commandError("Unable")
        gate.aircraftNotFound()

        XCTAssertEqual(spy.total, 3)
        XCTAssertEqual(gate.suppressedCount, 0)
    }

    /// **The case the gate exists for.** Seeking through four hundred ticks must not queue forty
    /// utterances at a reviewer who is scrubbing, not watching.
    func testSuppressedModeDropsPresentationAndCountsIt() {
        let spy = FeedbackSpy()
        let gate = SideEffectGate(presentation: spy, mode: .suppressed)

        for _ in 0..<40 { gate.readback("CLIMBING") }
        gate.commandError("Unable")
        gate.aircraftNotFound()

        XCTAssertEqual(spy.total, 0, "something leaked while suppressed")
        XCTAssertEqual(gate.suppressedCount, 42, "dropped effects must be countable, not invisible")
    }

    /// A replay being watched deliberately speaks — but reports nothing outward. The events were counted
    /// when they were recorded, and counting them again would inflate every statistic each time a session
    /// is reviewed.
    func testReplayingSpeaksButDoesNotReportOutward() {
        let spy = FeedbackSpy()
        let gate = SideEffectGate(presentation: spy, mode: .replaying)

        gate.readback("CLIMBING")
        gate.report("command_issued", ["code": "101"])

        XCTAssertEqual(spy.readbacks.count, 1, "a watched replay should be audible")
        XCTAssertEqual(gate.suppressedCount, 1, "the outward report should have been dropped")
    }

    func testOnlyLiveModeReportsOutward() {
        XCTAssertTrue(SideEffectMode.live.allowsReporting)
        XCTAssertFalse(SideEffectMode.replaying.allowsReporting)
        XCTAssertFalse(SideEffectMode.suppressed.allowsReporting)

        XCTAssertTrue(SideEffectMode.live.allowsPresentation)
        XCTAssertTrue(SideEffectMode.replaying.allowsPresentation)
        XCTAssertFalse(SideEffectMode.suppressed.allowsPresentation)
    }

    /// Scoped rather than a pair of set-calls, so an early return or a thrown error cannot leave the app
    /// permanently mute — which is exactly the bug a manual pair produces, and a silent one.
    func testSuppressingRestoresTheModeEvenOnThrow() {
        let gate = SideEffectGate(presentation: FeedbackSpy(), mode: .live)

        struct Boom: Error {}
        XCTAssertThrowsError(try gate.suppressing { throw Boom() })
        XCTAssertEqual(gate.mode, .live, "a throw left the app muted")

        gate.suppressing { XCTAssertEqual(gate.mode, .suppressed) }
        XCTAssertEqual(gate.mode, .live)
    }

    // MARK: - The simulation cannot bypass it

    /// One gate, shared. Two would sit in two modes, and a seek would silence only one of them — so the
    /// keypad would keep talking while the microphone path went quiet.
    func testTheKeypadAndTheVoicePathShareOneGate() {
        let spy = FeedbackSpy()
        let viewModel = MapViewModel(spawner: AircraftSpawner(), feedback: spy,
                                     reports: SilentReports())

        viewModel.sideEffects.mode = .suppressed
        CommandKeyboardHandler(radar: viewModel).perform("C/M*", value: 260)

        XCTAssertEqual(spy.total, 0, "the keypad spoke through a gate that was closed")
        XCTAssertGreaterThan(viewModel.sideEffects.suppressedCount, 0)
    }

    /// And with the gate open the same key is audible, so the test above is not passing because the key
    /// does nothing.
    func testTheSameKeyIsAudibleWithTheGateOpen() {
        let spy = FeedbackSpy()
        let viewModel = MapViewModel(spawner: AircraftSpawner(), feedback: spy,
                                     reports: SilentReports())

        CommandKeyboardHandler(radar: viewModel).perform("C/M*", value: 260)
        XCTAssertGreaterThan(spy.total, 0)
    }

    // MARK: - The rule, enforced by scanning source

    /// Simulation code must not reach for the feedback singleton.
    ///
    /// A grep, because nothing else can catch this: a bypass compiles, runs, and behaves perfectly in a
    /// live exercise. The failure surfaces only when a replay makes a noise it should not, months later,
    /// with no stack trace pointing anywhere useful.
    func testSimulationCodeDoesNotReachForTheFeedbackSingleton() throws {
        // SpeechViewModel is the push-to-talk button's own view model, and its only calls are the mic
        // start/stop tones. Those are UI reacting to a button press, not the simulation causing anything —
        // replay never presses the mic. Excluded by name with the reason, rather than by dropping
        // ViewModels from the scan, which would also stop covering MapViewModel and the keypad.
        let presentationOnly = ["SpeechViewModel.swift"]

        let offenders = try Self.sourceFiles(under: ["Commands", "ViewModels", "Simulation"])
            .filter { url in
                guard !presentationOnly.contains(url.lastPathComponent),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains("CommandFeedbackManager.shared.")
            }
            .map { $0.lastPathComponent }

        XCTAssertTrue(offenders.isEmpty, """
            These files speak through the feedback singleton instead of the side-effect gate: \
            \(offenders.joined(separator: ", ")).

            A replay cannot suppress a call that bypasses the gate. Take a `CommandFeedback` by injection \
            — see SideEffects.swift — rather than reaching for the shared manager.
            """)
    }

    /// Audio has exactly one caller. `FeedbackSound` is the device synthesiser; anything talking to it
    /// directly is outside the boundary by construction.
    func testOnlyTheFeedbackManagerTouchesAudio() throws {
        let offenders = try Self.sourceFiles(under: ["Commands", "ViewModels", "Simulation", "Views"])
            .filter { url in
                guard url.lastPathComponent != "FeedbackSound.swift",
                      url.lastPathComponent != "CommandFeedbackManager.swift",
                      let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains("FeedbackSound.")
            }
            .map { $0.lastPathComponent }

        XCTAssertTrue(offenders.isEmpty, """
            These files call the synthesiser directly: \(offenders.joined(separator: ", ")). \
            Audio is a side effect and must cross the gate, or a replay will speak when it should not.
            """)
    }

    // MARK: - Helpers

    private final class SilentReports: DeferredReportAnnouncing {
        func register(_ command: RecognizedCommand, aircraftCallsign: String?) {}
        func advance(aircraft: [Aircraft], allCallsigns: Set<String>,
                     fixes: [ATCSimKit.Fix], runways: [Runway]) {}
    }

    /// Swift files under the named app subdirectories.
    ///
    /// Located from `#filePath` rather than the bundle, because a test bundle contains compiled code and
    /// not sources — and this test is about sources.
    private static func sourceFiles(under directories: [String]) throws -> [URL] {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // VectraProTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("VectraPro")

        var found: [URL] = []
        for directory in directories {
            let url = appRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: url,
                                                             includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                found.append(file)
            }
        }
        XCTAssertFalse(found.isEmpty, "the scan found no sources — the path is wrong, not the code")
        return found
    }
}
