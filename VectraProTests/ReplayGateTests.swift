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

        // ── Read the recording back, from disk ────────────────────────────────────
        let manifest = try coordinator.sessions.manifest(for: sessionID)
        let recorded = try coordinator.sessions.events(for: sessionID)

        XCTAssertEqual(manifest.seed, seed, "the seed did not survive the recording")
        XCTAssertTrue(manifest.payloadIsIntact)
        XCTAssertFalse(recorded.isEmpty, "nothing was recorded — the gate would pass vacuously")

        let commands = recorded.filter { $0.payload.affectsSimulation }
        XCTAssertEqual(commands.count, Self.script.count,
                       "every instruction should be recorded exactly once")

        // ── Replay: seed + recorded commands, nothing else ────────────────────────
        let replayed = makeSimulation()
        replayed.reset(seed: manifest.seed)
        replayed.stopSimulation()
        replayed.sideEffects.mode = .suppressed

        var byTick: [Int: [Event]] = [:]
        for event in commands { byTick[event.tick, default: []].append(event) }

        var replayFingerprints: [Int: UInt64] = [:]
        for tick in 1...600 {
            // Keyed on the clock's *current* reading, not the loop counter. An event recorded at tick N was
            // issued while the clock read N — before the step that takes it to N+1 — so replay must inject it
            // at the same point. Driving off the loop counter applied everything one tick late, which is the
            // divergence this gate first reported: the recording was correct and the driver was not.
            let due = byTick[replayed.elapsedSeconds] ?? []
            for event in due.sorted(by: { $0.ordinal < $1.ordinal }) {
                guard case .commandIssued(let code, let callsign, let slots) = event.payload else { continue }
                try Self.apply(code: code, callsign: callsign, slots: slots, to: replayed)
            }
            replayed.advanceStep()
            if tick % 60 == 0 { replayFingerprints[tick] = replayed.stateHash.value }
        }

        // ── Compare ───────────────────────────────────────────────────────────────
        // Diagnostic: which aircraft each side acted on, and what the recording actually holds.
        for event in commands.prefix(2) {
            print("GATE recorded: \(event.payload)")
        }
        print("GATE live aircraft: \(live.listAircraft.map(\.callsign).sorted())")
        print("GATE replay aircraft: \(replayed.listAircraft.map(\.callsign).sorted())")
        print("GATE live tick60=\(liveFingerprints[60] ?? 0) replay tick60=\(replayFingerprints[60] ?? 0)")

        XCTAssertEqual(liveFingerprints.count, 10)
        for tick in liveFingerprints.keys.sorted() {
            XCTAssertEqual(replayFingerprints[tick], liveFingerprints[tick],
                           """
                           diverged at tick \(tick).
                           recorded: \(commands.map { "\($0.tick):\($0.payload)" })
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

    // MARK: - Feeding a recorded command back in

    /// Recorded slots are text; the simulation wants typed values. Reconstructing `StaticCommandSlots` from
    /// them is the whole of what replay has to do — which is the point of recording phraseology rather than
    /// effects, and of the keypad having proved a code plus values is enough.
    private static func apply(code: String,
                              callsign: String,
                              slots: [String: String],
                              to viewModel: MapViewModel) throws {
        var integers: [String: [Int]] = [:]
        var texts: [String: [String]] = [:]
        for (name, value) in slots {
            let parts = value.split(separator: ",").map(String.init)
            let numbers = parts.compactMap(Int.init)
            if numbers.count == parts.count {
                integers[name] = numbers
            } else {
                texts[name] = parts
            }
        }

        // The instruction named an aircraft, so select it — the recording holds the resolved callsign, which
        // is why replay does not have to guess who was on frequency.
        if !callsign.isEmpty,
           let target = viewModel.listAircraft.first(where: {
               $0.callsign.caseInsensitiveCompare(callsign) == .orderedSame
           }) {
            viewModel.selectAircraft(target.id)
        }

        let result = viewModel.commands.perform(
            code: code, callsign: callsign.isEmpty ? nil : callsign,
            slots: StaticCommandSlots(integers: integers, texts: texts),
            source: .replay, category: "replay")

        if !result.effects.isEmpty {
            viewModel.apply(result.effects, readback: "REPLAY")
        }
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
        XCTAssertEqual(recorded.filter { $0.payload.affectsSimulation }.count, 1)
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
