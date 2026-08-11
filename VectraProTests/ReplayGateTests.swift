//
//  ReplayGateTests.swift
//  VectraProTests
//
//  **The acceptance gate for the whole architecture.**
//
//  Record a session through the real pipeline — gateway, recorder, framed log on disk — then read it back
//  from those bytes and re-run the simulation from its manifest seed and its recorded commands. The
//  fingerprints must match, tick for tick.
//
//  If this passes, the recording contains enough to reproduce a run, which is the one premise the replay
//  engine rests on. If it fails, no amount of engine would help: the fix would be in the event model, and
//  finding that out after building the engine would mean rebuilding it. That is why this test exists before
//  any of it.
//
//  Nothing is stubbed except audio. The events come from disk, decoded through the envelope and the migrator,
//  and are fed back through `CommandController.perform` — the same entry point the microphone uses.
//

import XCTest
import ATCParserKit
import ATCReplayKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class ReplayGateTests: XCTestCase {

    private final class SilentFeedback: CommandFeedback {
        func readback(_ spoken: String) {}
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

    private let seed: UInt64 = 0x5EED_1234
    private let owner = OwnerID.device(UUID())

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Gate-\(UUID().uuidString)")
        coordinator = SessionCoordinator(root: root,
                                         catalogue: InMemorySessionCatalogue(),
                                         environment: .current())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSimulation() -> MapViewModel {
        MapViewModel(spawner: AircraftSpawner(), feedback: SilentFeedback(), reports: SilentReports())
    }

    /// What a trainee does, as keypresses. Deliberately keypad rather than voice: a keypress carries only a
    /// code and values, which is exactly what a recording holds — so this exercises the same information
    /// replay will have.
    private static let script: [(tick: Int, key: String, value: Int)] = [
        (tick:  30, key: "C/M*", value: 260),
        (tick:  90, key: "TRH",  value: 250),
        (tick: 150, key: "SPD*", value: 300),
        (tick: 240, key: "D/M*", value: 120),
        (tick: 330, key: "TLH",  value: 90),
        (tick: 420, key: "SPD*", value: 220),
    ]

    // MARK: - The gate

    func testARecordedSessionReplaysToTheSameFingerprint() throws {
        // ── Record ────────────────────────────────────────────────────────────────
        let live = makeSimulation()
        live.reset(seed: seed)
        live.stopSimulation()

        let recorder = try XCTUnwrap(
            coordinator.startRecording(exercisePayload: Data(#"{"exerciseName":"Gate"}"#.utf8),
                                       exerciseID: "gate-1",
                                       exerciseName: "Gate",
                                       seed: seed,
                                       owner: owner),
            "recording did not start")
        live.inputs.recorder = recorder

        var liveFingerprints: [Int: UInt64] = [:]
        for tick in 1...600 {
            for entry in Self.script where entry.tick == tick {
                // Targeted by id order so both runs address the same aircraft without needing to know what
                // the seed produced.
                if let target = live.aircraft.min(by: { $0.id.uuidString < $1.id.uuidString }) {
                    live.selectAircraft(target.id)
                    CommandKeyboardHandler(radar: live).perform(entry.key, value: entry.value)
                }
            }
            live.advanceStep()
            if tick % 60 == 0 { liveFingerprints[tick] = live.stateHash.value }
        }

        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)
        coordinator.stopRecording(tickCount: 600)

        // ── Replay, through the engine ────────────────────────────────────────────
        //
        // Driven by `ReplayEngine` rather than by a loop written here. The gate used to carry its own driver,
        // which meant it was validating test code: the engine could have been wrong in exactly the way the
        // driver was right. Now the thing that ships is the thing under test.
        let replayed = makeSimulation()
        let engine = ReplayEngine(radar: replayed, recording: coordinator)
        let loaded = try engine.load(sessionID)

        XCTAssertEqual(loaded.manifest.seed, seed, "the seed did not survive the recording")
        XCTAssertTrue(loaded.manifest.payloadIsIntact)
        XCTAssertTrue(loaded.isReproducibleHere)
        XCTAssertEqual(loaded.inputsByTick.values.map(\.count).reduce(0, +), Self.script.count,
                       "every instruction should be recorded exactly once")

        var replayFingerprints: [Int: UInt64] = [:]
        while engine.currentTick < 600, engine.stepForward() {
            if engine.currentTick % 60 == 0 { replayFingerprints[engine.currentTick] = replayed.stateHash.value }
        }

        // ── Compare ───────────────────────────────────────────────────────────────
        XCTAssertEqual(liveFingerprints.count, 10)
        for tick in liveFingerprints.keys.sorted() {
            XCTAssertEqual(replayFingerprints[tick], liveFingerprints[tick],
                           """
                           diverged at tick \(tick).
                           recorded: \(loaded.inputsByTick.sorted { $0.key < $1.key }.map { "\($0.key)" })
                           live aircraft:   \(live.listAircraft.map(\.callsign).sorted())
                           replay aircraft: \(replayed.listAircraft.map(\.callsign).sorted())
                           """)
        }
    }

    /// Replaying the recorded commands *and* the seed is what reproduces the run. The seed alone does not —
    /// otherwise the gate would be passing for the wrong reason.
    func testTheRecordedCommandsAreNecessaryNotJustTheSeed() throws {
        let live = makeSimulation()
        live.reset(seed: seed)
        live.stopSimulation()
        let recorder = try XCTUnwrap(
            coordinator.startRecording(exercisePayload: Data("{}".utf8), exerciseID: nil,
                                       exerciseName: nil, seed: seed, owner: owner))
        live.inputs.recorder = recorder

        for tick in 1...300 {
            if tick == 30, let target = live.aircraft.min(by: { $0.id.uuidString < $1.id.uuidString }) {
                live.selectAircraft(target.id)
                CommandKeyboardHandler(radar: live).perform("C/M*", value: 260)
            }
            live.advanceStep()
        }
        coordinator.stopRecording(tickCount: 300)

        // Same seed, no commands.
        let seedOnly = makeSimulation()
        seedOnly.reset(seed: seed)
        seedOnly.stopSimulation()
        for _ in 1...300 { seedOnly.advanceStep() }

        XCTAssertNotEqual(seedOnly.stateHash.value, live.stateHash.value,
                          "the commands made no difference — the gate proves nothing")
    }

    /// The recording is byte-verifiable: its seal matches the manifest and the log as stored.
    func testTheRecordedSessionVerifiesAgainstItsSeal() throws {
        let live = makeSimulation()
        live.reset(seed: seed)
        live.stopSimulation()

        // An assessment, because that is the class whose seal has to hold up.
        let recorder = try XCTUnwrap(
            coordinator.startRecording(exercisePayload: Data("{}".utf8), exerciseID: nil,
                                       exerciseName: nil, seed: seed, owner: .user("trainee-1"),
                                       origin: .assignment(UUID(), assignedBy: "instructor-1")))
        live.inputs.recorder = recorder

        live.selectAircraft(try XCTUnwrap(live.aircraft.first).id)
        CommandKeyboardHandler(radar: live).perform("C/M*", value: 260)
        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)
        coordinator.stopRecording(tickCount: 1)

        let summary = try XCTUnwrap(try coordinator.sessions.catalogue.summary(id: sessionID))
        guard case .sealed(let digest) = summary.state else {
            return XCTFail("an assessment should have sealed; state was \(summary.state)")
        }

        let manifest = try Data(contentsOf: coordinator.sessions.manifestURL(for: sessionID))
        let log = try Data(contentsOf: coordinator.sessions.eventLogURL(for: sessionID))
        XCTAssertTrue(SessionSeal.verify(digest, manifest: manifest, log: log))
    }

}

// MARK: - The app path is the gate's path

extension ReplayGateTests {

    /// **The integration the gate was validating on the app's behalf.**
    ///
    /// The gate above drives `SessionCoordinator` directly. This one attaches it to the view model the way
    /// launch does, and then only calls `reset` — the thing the app calls — and asserts a session started,
    /// recorded, and sealed itself. If these two ever diverge, the gate would be proving something about a
    /// path the app does not take.
    func testTheAppPathStartsAndEndsItsOwnSession() throws {
        let radar = makeSimulation()
        radar.recording = coordinator
        radar.applyExercise(Self.minimalExercise(), payload: Data(#"{"served":"bytes"}"#.utf8))

        // Only `reset` — no coordinator call. This is what the app does.
        radar.reset(seed: seed)
        radar.stopSimulation()

        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id,
                                      "reset() did not start a session")
        XCTAssertNotNil(radar.inputs.recorder, "no recorder was attached to the gateway")

        radar.selectAircraft(try XCTUnwrap(radar.aircraft.first).id)
        CommandKeyboardHandler(radar: radar).perform("C/M*", value: 260)
        for _ in 1...20 { radar.advanceStep() }

        // Leaving the exercise ends the session — it did not run to its duration.
        radar.clearOnExit()

        XCTAssertNil(coordinator.sessions.active, "the session stayed open after leaving")
        XCTAssertNil(radar.inputs.recorder)

        let manifest = try coordinator.sessions.manifest(for: sessionID)
        XCTAssertEqual(manifest.seed, seed)
        XCTAssertEqual(manifest.exercise.payload, Data(#"{"served":"bytes"}"#.utf8),
                       "the exercise was not embedded as the bytes that were served")

        let recorded = try coordinator.sessions.events(for: sessionID)
        // Post-R-Dist: simulation-affecting is decided by the codec from the event's tag, not a payload flag.
        let codec = ATCEventCodec()
        XCTAssertEqual(recorded.filter { codec.affectsSimulation(tag: $0.tag) }.count, 1)
        XCTAssertEqual(recorded.first?.source, .keypad)
    }

    /// An exercise that runs to its duration seals itself, without anything else being called.
    func testAnExerciseThatRunsToItsEndCompletesItsSession() throws {
        let radar = makeSimulation()
        radar.recording = coordinator
        radar.applyExercise(Self.minimalExercise(durationMinutes: 1), payload: Data("{}".utf8))
        radar.reset(seed: seed)
        radar.stopSimulation()

        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)
        for _ in 1...61 { radar.advanceStep() }   // one simulated minute, plus one

        XCTAssertTrue(radar.isExerciseFinished)
        XCTAssertNil(coordinator.sessions.active, "the finished exercise left its session open")

        let summary = try XCTUnwrap(try coordinator.sessions.catalogue.summary(id: sessionID))
        XCTAssertEqual(summary.state, .completed, "training completes rather than sealing")
        XCTAssertTrue(summary.isScoreable(on: .current()))
    }

    /// With no coordinator attached — the state before launch wires it, and the state in every other test —
    /// nothing records and the simulation is unchanged. The property `InputGatewayTests` pins, asserted here
    /// through the app's own entry point.
    func testWithoutACoordinatorNothingRecords() throws {
        let radar = makeSimulation()
        radar.applyExercise(Self.minimalExercise(), payload: Data("{}".utf8))
        radar.reset(seed: seed)
        radar.stopSimulation()

        XCTAssertNil(radar.inputs.recorder)
        radar.selectAircraft(try XCTUnwrap(radar.aircraft.first).id)
        CommandKeyboardHandler(radar: radar).perform("C/M*", value: 260)

        XCTAssertEqual(radar.aircraft.first?.targetAltitudeFeet, 26_000,
                       "the instruction did not take effect without a recorder")
    }

    /// The smallest exercise that produces a flyable world: one runway, no fixes, no zones.
    private static func minimalExercise(durationMinutes: Int = 0) -> ExerciseDetail {
        let json = """
        {
          "exerciseName": "Gate",
          "id": "gate-1",
          "gameEnd": { "time": \(durationMinutes) },
          "mapLocation": { "mapLatitude": 28.5562, "mapLongitude": 77.1000 },
          "runwaysResponse": [],
          "aircrafts": [], "airlines": [], "commands": [], "fixes": [], "zone": []
        }
        """
        return try! JSONDecoder().decode(ExerciseDetail.self, from: Data(json.utf8))
    }
}
