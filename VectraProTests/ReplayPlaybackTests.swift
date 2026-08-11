//
//  ReplayPlaybackTests.swift
//  VectraProTests
//
//  The last engine acceptance criterion: scheduling, not just execution.
//
//  Every other replay test drives the engine synchronously through `run(to:)` or `stepForward()`, which proves the
//  simulation is right and says nothing about the timer. These let the timer actually fire, so what is under test
//  is play advancing on its own, pause stopping it, resume picking it up, and speed changing the interval without
//  changing where the replay ends up.
//
//  ── They take real time on purpose ─────────────────────────────────────────
//  A test that waits is a test that can be flaky, so the waits are as short as the fastest speed allows and every
//  assertion is about a *direction* rather than an exact count — "it advanced", "it did not advance" — because how
//  many times a timer fires in 300 ms is a property of the machine, not of the engine. Asserting an exact tick
//  count here would be asserting the CI runner's mood.
//

import XCTest
import ATCParserKit
import ATCReplayKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class ReplayPlaybackTests: XCTestCase {

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
    private let seed: UInt64 = 0x91A4_B0

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Playback-\(UUID().uuidString)")
        coordinator = SessionCoordinator(root: root, catalogue: InMemorySessionCatalogue())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func simulation() -> MapViewModel {
        MapViewModel(spawner: AircraftSpawner(), feedback: SilentFeedback(), reports: SilentReports())
    }

    private static let payload = Data("""
    {
      "exerciseName": "Playback", "id": "playback-1", "gameEnd": { "time": 0 },
      "mapLocation": { "mapLatitude": 28.5562, "mapLongitude": 77.1000 },
      "runwaysResponse": [], "aircrafts": [], "airlines": [], "commands": [], "fixes": [], "zone": []
    }
    """.utf8)

    /// Records a session and returns an engine loaded on it.
    private func loadedEngine(ticks: Int = 200,
                              instructions: [(tick: Int, key: String, value: Int)] = []) throws
        -> (engine: ReplayEngine, radar: MapViewModel, sessionID: SessionID) {
        let recording = simulation()
        recording.recording = coordinator
        recording.applyExercise(try JSONDecoder().decode(ExerciseDetail.self, from: Self.payload),
                                payload: Self.payload)
        recording.reset(seed: seed)
        recording.stopSimulation()
        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)

        for tick in 1...ticks {
            for entry in instructions where entry.tick == tick {
                if let target = recording.aircraft.min(by: { $0.id.uuidString < $1.id.uuidString }) {
                    recording.selectAircraft(target.id)
                    CommandKeyboardHandler(radar: recording).perform(entry.key, value: entry.value)
                }
            }
            recording.advanceStep()
        }
        coordinator.stopRecording(tickCount: ticks)

        let radar = simulation()
        let engine = ReplayEngine(radar: radar, recording: coordinator)
        try engine.load(sessionID)
        return (engine, radar, sessionID)
    }

    /// Spins the run loop for `seconds` so timers fire. `Thread.sleep` would block it and nothing would happen —
    /// which would make every test here pass for the wrong reason.
    private func letTimersFire(for seconds: TimeInterval) {
        let deadline = expectation(description: "run loop spun for \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { deadline.fulfill() }
        wait(for: [deadline], timeout: seconds + 5)
    }

    // MARK: - Play

    func testPlayAdvancesOnItsOwn() throws {
        let (engine, _, _) = try loadedEngine()
        engine.setSpeed(30)                     // ~33 ms a tick

        XCTAssertEqual(engine.clock.position, 0)
        try engine.play()
        XCTAssertTrue(engine.clock.isRunning)

        letTimersFire(for: 0.4)

        XCTAssertGreaterThan(engine.clock.position, 0, "play did not advance the replay")
        engine.tearDown()
    }

    // MARK: - Pause

    /// Pause stops progression immediately: the position after pausing must not move again, however long we wait.
    func testPauseStopsProgressionImmediately() throws {
        let (engine, _, _) = try loadedEngine()
        engine.setSpeed(30)
        try engine.play()
        letTimersFire(for: 0.3)

        try engine.pause()
        let atPause = engine.clock.position
        XCTAssertGreaterThan(atPause, 0, "nothing had advanced, so pausing proves nothing")
        XCTAssertFalse(engine.clock.isRunning)

        letTimersFire(for: 0.4)
        XCTAssertEqual(engine.clock.position, atPause, "the replay advanced after pausing")
    }

    // MARK: - Resume

    func testResumeContinuesFromWhereItPaused() throws {
        let (engine, _, _) = try loadedEngine()
        engine.setSpeed(30)
        try engine.play()
        letTimersFire(for: 0.3)
        try engine.pause()
        let atPause = engine.clock.position

        try engine.play()
        letTimersFire(for: 0.3)

        XCTAssertGreaterThan(engine.clock.position, atPause, "resume did not continue")
        engine.tearDown()
    }

    // MARK: - Speed

    /// Speed changes the interval between steps, and that is all it changes.
    func testSpeedChangesTheIntervalOnly() throws {
        let (engine, _, _) = try loadedEngine()

        for speed in ReplayClock.speedOptions {
            engine.setSpeed(speed)
            XCTAssertEqual(engine.clock.tickInterval,
                           SimulationClock.tickInterval / speed, accuracy: 0.0001,
                           "the interval does not match \(speed)×")
        }

        // Sub-1× is slower than real time, which is what replay wants and live has no use for.
        engine.setSpeed(0.25)
        XCTAssertEqual(engine.clock.tickInterval, 4.0, accuracy: 0.0001)
        engine.setSpeed(30)
        XCTAssertEqual(engine.clock.tickInterval, 1.0 / 30, accuracy: 0.0001)
    }

    /// **The acceptance criterion.** Two timer-driven playbacks of the same span at different speeds must reach the
    /// same fingerprint. Driven by the timer, not by `run(to:)`, so this is about scheduling rather than execution.
    func testFingerprintsAreIdenticalAcrossPlaybackSpeeds() throws {
        let instructions = [(tick: 10, key: "C/M*", value: 260), (tick: 40, key: "TRH", value: 250)]

        func playTo(_ target: Int, at speed: Double) throws -> UInt64 {
            let (engine, radar, _) = try loadedEngine(ticks: 120, instructions: instructions)
            engine.setSpeed(speed)
            try engine.play()

            // Waits until the position is reached rather than for a fixed time, so a slow machine takes longer
            // instead of producing a different answer.
            let reached = expectation(description: "reached \(target) at \(speed)×")
            let poll = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    if engine.clock.position >= target || !engine.clock.isRunning {
                        timer.invalidate()
                        reached.fulfill()
                    }
                }
            }
            wait(for: [reached], timeout: 30)
            poll.invalidate()
            engine.tearDown()

            XCTAssertGreaterThanOrEqual(engine.clock.position, target,
                                        "playback at \(speed)× stopped short")
            // Settled to exactly the target, so the two comparisons are of the same tick — a timer may overshoot
            // by one fire and that is scheduling, not divergence.
            try engine.seek(to: target)
            return radar.stateHash.value
        }

        let fast = try playTo(60, at: 30)
        let slower = try playTo(60, at: 4)
        XCTAssertEqual(fast, slower, "playback speed changed the simulation")
    }

    // MARK: - Reaching the end

    /// Playing to the end leaves the transport in the right terminal state, without anything having to notice.
    func testReachingTheEndPausesAtTheEnd() throws {
        let (engine, _, _) = try loadedEngine(ticks: 20)
        engine.setSpeed(30)
        try engine.play()

        let ended = expectation(description: "reached the end")
        let poll = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            MainActor.assumeIsolated {
                if engine.clock.isAtEnd { timer.invalidate(); ended.fulfill() }
            }
        }
        wait(for: [ended], timeout: 30)
        poll.invalidate()

        XCTAssertTrue(engine.clock.isAtEnd)
        XCTAssertEqual(engine.clock.mode, .paused, "the end left the transport running")
        XCTAssertFalse(engine.clock.isRunning)
        XCTAssertFalse(engine.clock.canPlay, "play was offered at the end of the recording")
        XCTAssertEqual(engine.clock.progress, 1, accuracy: 0.001)

        // And it stays there.
        letTimersFire(for: 0.2)
        XCTAssertEqual(engine.clock.position, engine.clock.bounds.upperBound)
    }

    /// A watched replay speaks; a seek does not. Both go through the side-effect gate, so this checks the mode the
    /// engine puts it in rather than counting utterances.
    func testAWatchedReplayIsAudibleAndDoesNotReportOutward() throws {
        let (engine, radar, _) = try loadedEngine()
        try engine.play()
        XCTAssertEqual(radar.sideEffects.mode, .replaying,
                       "a watched replay should be audible")
        XCTAssertFalse(radar.sideEffects.mode.allowsReporting,
                       "a replay must not report outward — it is not a second exercise")

        try engine.pause()
        XCTAssertEqual(radar.sideEffects.mode, .live)
    }
}
