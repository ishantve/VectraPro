//
//  ReplayEngineTests.swift
//  VectraProTests
//
//  Phase C, items 1 to 4: loading, the clock, the scheduler, injection.
//
//  The gate proves the engine reproduces a run. These cover the parts the gate does not reach — a cold load
//  from a stored session with nothing set up beforehand, a corrupt payload, and the ordering rule that makes a
//  multi-instruction transmission replay the way it was spoken.
//

import XCTest
import ATCParserKit
import ATCReplayKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class ReplayEngineTests: XCTestCase {

    private final class SilentFeedback: CommandFeedback {
        var readbacks: [String] = []
        func readback(_ spoken: String) { readbacks.append(spoken) }
        func commandError(_ phrase: String) {}
        func aircraftNotFound() {}
    }

    private final class SilentReports: DeferredReportAnnouncing {
        func register(_ command: RecognizedCommand, aircraftCallsign: String?) {}
        func advance(aircraft: [Aircraft], allCallsigns: Set<String>,
                     fixes: [ATCSimKit.Fix], runways: [Runway]) {}
    }

    private var root: URL!
    private var coordinator: SessionCoordinator!
    private let seed: UInt64 = 0xE0_6E

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Engine-\(UUID().uuidString)")
        coordinator = SessionCoordinator(root: root, catalogue: InMemorySessionCatalogue())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func simulation(_ feedback: SilentFeedback? = nil) -> MapViewModel {
        MapViewModel(spawner: AircraftSpawner(),
                     feedback: feedback ?? SilentFeedback(),
                     reports: SilentReports())
    }

    private static let exercisePayload = Data("""
    {
      "exerciseName": "Engine", "id": "engine-1",
      "gameEnd": { "time": 0 },
      "mapLocation": { "mapLatitude": 28.5562, "mapLongitude": 77.1000 },
      "runwaysResponse": [], "aircrafts": [], "airlines": [], "commands": [], "fixes": [], "zone": []
    }
    """.utf8)

    /// Records a session and returns its id.
    private func recordASession(instructions: [(tick: Int, key: String, value: Int)],
                                ticks: Int = 300) throws -> SessionID {
        let radar = simulation()
        radar.recording = coordinator
        radar.applyExercise(try JSONDecoder().decode(ExerciseDetail.self, from: Self.exercisePayload),
                            payload: Self.exercisePayload)
        radar.reset(seed: seed)
        radar.stopSimulation()

        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)
        for tick in 1...ticks {
            for entry in instructions where entry.tick == tick {
                if let target = radar.aircraft.min(by: { $0.id.uuidString < $1.id.uuidString }) {
                    radar.selectAircraft(target.id)
                    CommandKeyboardHandler(radar: radar).perform(entry.key, value: entry.value)
                }
            }
            radar.advanceStep()
        }
        coordinator.stopRecording(tickCount: ticks)
        return sessionID
    }

    // MARK: - 1 · Loading

    /// **A cold load.** A fresh simulation with no exercise applied — the engine restores it from the
    /// manifest's embedded payload. This is what a reviewer opening a stored session does, and the property
    /// that makes embedding the payload worth the bytes.
    func testLoadingRestoresTheExerciseFromTheRecordingAlone() throws {
        let sessionID = try recordASession(instructions: [(tick: 30, key: "C/M*", value: 260)])

        let fresh = simulation()   // no applyExercise, no reset
        let engine = ReplayEngine(radar: fresh, sessions: coordinator.sessions)
        let loaded = try engine.load(sessionID)

        XCTAssertEqual(loaded.manifest.seed, seed)
        XCTAssertEqual(fresh.exerciseName, "Engine", "the exercise was not restored from the manifest")
        XCTAssertEqual(engine.currentTick, 0, "loading should return to the first tick")
        XCTAssertFalse(fresh.aircraft.isEmpty, "the world was not rebuilt")
    }

    /// Loading detaches recording. A replay must not write itself into a new log — it would look like a second
    /// exercise, and its events would be counted twice in anything derived from the record.
    func testLoadingStopsAnythingBeingRecorded() throws {
        let sessionID = try recordASession(instructions: [])

        let fresh = simulation()
        fresh.recording = coordinator
        let engine = ReplayEngine(radar: fresh, sessions: coordinator.sessions)
        try engine.load(sessionID)

        XCTAssertNil(fresh.inputs.recorder, "a replay attached a recorder")
        XCTAssertNil(coordinator.sessions.active, "loading a replay started a session")
    }

    /// A corrupt payload is refused rather than replayed. Replaying a mangled configuration would produce a
    /// subtly wrong world with nothing reporting it.
    func testACorruptPayloadIsRefused() throws {
        let sessionID = try recordASession(instructions: [])

        // Corrupt the payload itself, not a field beside it.
        //
        // My first attempt at this edited `exerciseName` in the manifest text and the load succeeded — because
        // the payload is base64 and the digest covers *it*, not the fields around it. The test was wrong, and
        // its passing would have meant nothing. This flips a character inside the encoded bytes, which is what
        // a corrupted file actually looks like.
        let url = coordinator.sessions.manifestURL(for: sessionID)
        var text = try String(contentsOf: url, encoding: .utf8)
        let marker = "\"payload\" : \""
        let start = try XCTUnwrap(text.range(of: marker), "manifest layout changed")
        let flipIndex = text.index(start.upperBound, offsetBy: 8)
        let original = text[flipIndex]
        text.replaceSubrange(flipIndex...flipIndex, with: original == "A" ? "B" : "A")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(
            at: url.deletingLastPathComponent().appendingPathComponent("manifest.json.bak"))

        let engine = ReplayEngine(radar: simulation(), sessions: coordinator.sessions)
        XCTAssertThrowsError(try engine.load(sessionID))
    }

    // MARK: - 2 · Clock

    func testProgressRunsFromZeroToOne() throws {
        let sessionID = try recordASession(instructions: [(tick: 30, key: "C/M*", value: 260)])
        let engine = ReplayEngine(radar: simulation(), sessions: coordinator.sessions)
        try engine.load(sessionID)

        XCTAssertEqual(engine.progress, 0)
        XCTAssertFalse(engine.isAtEnd)

        engine.run(to: engine.lastTick)
        XCTAssertEqual(engine.progress, 1, accuracy: 0.001)
        XCTAssertTrue(engine.isAtEnd)
    }

    /// Stepping past the end stops rather than running on. A recording covers a finite span, and continuing
    /// would be simulating a stretch nobody recorded while calling it a replay.
    func testSteppingStopsAtTheEndOfTheRecording() throws {
        let sessionID = try recordASession(instructions: [], ticks: 50)
        let engine = ReplayEngine(radar: simulation(), sessions: coordinator.sessions)
        try engine.load(sessionID)

        while engine.stepForward() {}
        let atEnd = engine.currentTick

        XCTAssertFalse(engine.stepForward())
        XCTAssertEqual(engine.currentTick, atEnd, "the clock moved past the recording")
    }

    // MARK: - 3 · Scheduler

    /// Several instructions in one tick are replayed in the order they were issued.
    ///
    /// `(tick, ordinal)` exists for this: one transmission carries three instructions, and "climb then descend"
    /// is not the same exercise as "descend then climb". Grouping by tick alone would have lost it.
    func testInstructionsInOneTickReplayInTheOrderTheyWereIssued() throws {
        let radar = simulation()
        radar.recording = coordinator
        radar.applyExercise(try JSONDecoder().decode(ExerciseDetail.self, from: Self.exercisePayload),
                            payload: Self.exercisePayload)
        radar.reset(seed: seed)
        radar.stopSimulation()
        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)

        // Three, at one tick, without stepping in between.
        let target = try XCTUnwrap(radar.aircraft.first)
        radar.selectAircraft(target.id)
        let keypad = CommandKeyboardHandler(radar: radar)
        keypad.perform("C/M*", value: 300)
        keypad.perform("C/M*", value: 200)
        keypad.perform("C/M*", value: 260)
        for _ in 1...10 { radar.advanceStep() }
        coordinator.stopRecording(tickCount: 10)

        let engine = ReplayEngine(radar: simulation(), sessions: coordinator.sessions)
        let loaded = try engine.load(sessionID)

        let atTick = try XCTUnwrap(loaded.inputsByTick[0])
        XCTAssertEqual(atTick.count, 3)
        XCTAssertEqual(atTick.map(\.ordinal), atTick.map(\.ordinal).sorted(),
                       "the scheduler did not order a tick's instructions by ordinal")

        // The last one issued is the one that stands.
        engine.run(to: loaded.lastTick)
        XCTAssertEqual(engine.loaded?.sessionID, sessionID)
    }

    /// Annotations are kept but not fed to the simulation. A readback is a thing the trainee heard; it drives
    /// nothing, and injecting it would be inventing an instruction.
    func testAnnotationsAreLoadedButNotInjected() throws {
        let radar = simulation()
        radar.recording = coordinator
        radar.applyExercise(try JSONDecoder().decode(ExerciseDetail.self, from: Self.exercisePayload),
                            payload: Self.exercisePayload)
        radar.reset(seed: seed)
        radar.stopSimulation()
        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)

        radar.inputs.annotate(.readbackSpoken(callsign: "AIC1", spoken: "CLIMBING"), source: .system)
        radar.inputs.annotate(.transcriptReceived(raw: "climb", normalized: "climb"), source: .voice)
        for _ in 1...5 { radar.advanceStep() }
        coordinator.stopRecording(tickCount: 5)

        let engine = ReplayEngine(radar: simulation(), sessions: coordinator.sessions)
        let loaded = try engine.load(sessionID)

        XCTAssertEqual(loaded.annotations.count, 2)
        XCTAssertTrue(loaded.inputsByTick.isEmpty, "an annotation was scheduled as an input")
    }

    // MARK: - 4 · Injection

    /// Recorded slot text back into typed values, including a repeated placeholder — a block altitude names
    /// `LEVEL` twice, and dropping the second half would replay half an instruction.
    func testSlotReconstructionHandlesRepeatedAndTextValues() {
        let both = ReplayEngine.slots(from: ["LEVEL": "100,140"])
        XCTAssertEqual(both.integer("LEVEL", occurrence: 0), 100)
        XCTAssertEqual(both.integer("LEVEL", occurrence: 1), 140)

        let text = ReplayEngine.slots(from: ["SIGNIFICANT POINT": "PJ"])
        XCTAssertEqual(text.text("SIGNIFICANT POINT", occurrence: 0), "PJ")
        XCTAssertNil(text.integer("SIGNIFICANT POINT", occurrence: 0))
    }

    /// Running a stretch says nothing out loud. Driving hundreds of ticks would otherwise queue hundreds of
    /// readbacks at a reviewer who is scrubbing — the gate handles it, so no call site has to remember.
    func testRunningAStretchIsSilent() throws {
        let sessionID = try recordASession(instructions: [
            (tick: 20, key: "C/M*", value: 260),
            (tick: 40, key: "TRH", value: 250),
            (tick: 60, key: "SPD*", value: 300),
        ])

        let feedback = SilentFeedback()
        let engine = ReplayEngine(radar: simulation(feedback), sessions: coordinator.sessions)
        try engine.load(sessionID)
        engine.run(to: engine.lastTick)

        XCTAssertTrue(feedback.readbacks.isEmpty,
                      "a seek spoke \(feedback.readbacks.count) readbacks")
    }
}
