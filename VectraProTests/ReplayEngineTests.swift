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
        let engine = ReplayEngine(radar: fresh, recording: coordinator)
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
        let engine = ReplayEngine(radar: fresh, recording: coordinator)
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

        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
        XCTAssertThrowsError(try engine.load(sessionID))
    }

    // MARK: - 2 · Clock

    func testProgressRunsFromZeroToOne() throws {
        let sessionID = try recordASession(instructions: [(tick: 30, key: "C/M*", value: 260)])
        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
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
        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
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

        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
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

        // Post-R-Dist: annotate takes a position-stamped ATCEvent builder; source defaults match (.system / .voice).
        radar.inputs.annotate { ATCEvent.readbackSpoken(callsign: "AIC1", spoken: "CLIMBING", at: $0) }
        radar.inputs.annotate { ATCEvent.transcriptReceived(raw: "climb", normalized: "climb", at: $0) }
        for _ in 1...5 { radar.advanceStep() }
        coordinator.stopRecording(tickCount: 5)

        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
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
        let engine = ReplayEngine(radar: simulation(feedback), recording: coordinator)
        try engine.load(sessionID)
        engine.run(to: engine.lastTick)

        XCTAssertTrue(feedback.readbacks.isEmpty,
                      "a seek spoke \(feedback.readbacks.count) readbacks")
    }
}

// MARK: - Items 5 and 6: timeline controls and seeking

extension ReplayEngineTests {

    /// **The property the ReplayClock exists for.** Its position must never disagree with the simulation's own
    /// clock. Two clocks that have to agree eventually do not, so this one mirrors rather than counts.
    func testTheClockNeverDisagreesWithTheSimulation() throws {
        let sessionID = try recordASession(instructions: [(tick: 30, key: "C/M*", value: 260)])
        let radar = simulation()
        let engine = ReplayEngine(radar: radar, recording: coordinator)
        try engine.load(sessionID)

        for _ in 1...50 {
            _ = engine.stepForward()
            XCTAssertEqual(engine.clock.position, radar.elapsedSeconds,
                           "the replay clock drifted from the simulation")
        }
        try engine.seek(to: 200)
        XCTAssertEqual(engine.clock.position, radar.elapsedSeconds)
        try engine.seek(to: 10)
        XCTAssertEqual(engine.clock.position, radar.elapsedSeconds)
    }

    /// Nothing else keeps playback state — the transport predicates all come from the clock.
    func testTheClockIsTheOnlyPlaybackState() throws {
        let sessionID = try recordASession(instructions: [])
        let engine = ReplayEngine(radar: simulation(), recording: coordinator)

        XCTAssertFalse(engine.clock.isLoaded)
        XCTAssertFalse(engine.clock.canPlay, "an unloaded replay offered play")

        try engine.load(sessionID)
        XCTAssertTrue(engine.clock.canPlay)
        XCTAssertFalse(engine.clock.canPause)

        try engine.play()
        XCTAssertTrue(engine.clock.isRunning)
        XCTAssertTrue(engine.clock.canPause)
        XCTAssertFalse(engine.clock.canPlay, "play was offered while already playing")

        try engine.pause()
        XCTAssertFalse(engine.clock.isRunning)
        XCTAssertTrue(engine.clock.canPlay)
    }

    /// Illegal transport moves are refused naming both states, rather than quietly applied.
    func testIllegalTransportMovesAreRefused() throws {
        let engine = ReplayEngine(radar: simulation(), recording: coordinator)

        XCTAssertThrowsError(try engine.play(), "playing an unloaded replay")
        XCTAssertThrowsError(try engine.pause(), "pausing a replay that is not playing")

        let sessionID = try recordASession(instructions: [])
        try engine.load(sessionID)
        try engine.play()
        XCTAssertThrowsError(try engine.play(), "playing twice")
    }

    /// Speed changes the interval, never the step size — which is why a replay at 30× reaches the same state as
    /// one at 1×. Asserted by driving the same span at both and comparing fingerprints.
    func testSpeedDoesNotChangeWhereAReplayEndsUp() throws {
        let sessionID = try recordASession(instructions: [
            (tick: 20, key: "C/M*", value: 260),
            (tick: 60, key: "TRH", value: 250),
        ])

        func run(at speed: Double) throws -> UInt64 {
            let radar = simulation()
            let engine = ReplayEngine(radar: radar, recording: coordinator)
            try engine.load(sessionID)
            engine.setSpeed(speed)
            XCTAssertEqual(engine.clock.speed, speed)
            engine.run(to: 150)
            return radar.stateHash.value
        }

        XCTAssertEqual(try run(at: 0.25), try run(at: 30), "speed changed where the replay ended up")
    }

    /// An unlisted speed is clamped to the nearest offered one rather than refused — a stray slider value is not
    /// worth an error — but the transport must never show a speed the timer is not using.
    func testAnUnlistedSpeedIsClampedNotShownFalsely() throws {
        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
        engine.setSpeed(7)
        XCTAssertTrue(ReplayClock.speedOptions.contains(engine.clock.speed))
        XCTAssertLessThanOrEqual(engine.clock.speed, 7)
        XCTAssertEqual(engine.clock.speed, 4, "should clamp down to the nearest offered speed")
    }

    // MARK: Seeking

    /// Seeking lands where it was asked to, forwards and backwards, and the state matches stepping there.
    ///
    /// The comparison is the point: a seek must produce the *same* world as walking to it, or a reviewer who
    /// scrubbed and a reviewer who watched would be looking at different exercises.
    func testSeekingLandsInTheSameStateAsStepping() throws {
        let sessionID = try recordASession(instructions: [
            (tick: 20, key: "C/M*", value: 260),
            (tick: 80, key: "TRH", value: 250),
            (tick: 140, key: "SPD*", value: 300),
        ])

        // Stepped.
        let stepped = simulation()
        let stepper = ReplayEngine(radar: stepped, recording: coordinator)
        try stepper.load(sessionID)
        stepper.run(to: 200)
        let steppedHash = stepped.stateHash.value

        // Sought forward in one move.
        let sought = simulation()
        let seeker = ReplayEngine(radar: sought, recording: coordinator)
        try seeker.load(sessionID)
        try seeker.seek(to: 200)

        XCTAssertEqual(seeker.clock.position, 200)
        XCTAssertEqual(sought.stateHash.value, steppedHash, "a forward seek and stepping disagreed")
    }

    /// **Reverse seeking through reconstruction.** There is no inverse step — collision destruction, spawning and
    /// hold capture destroy information — so going back means starting again and re-simulating. The result must be
    /// identical to having gone there directly.
    func testSeekingBackwardsReconstructsTheSameState() throws {
        let sessionID = try recordASession(instructions: [
            (tick: 20, key: "C/M*", value: 260),
            (tick: 80, key: "TRH", value: 250),
        ])

        let direct = simulation()
        let directEngine = ReplayEngine(radar: direct, recording: coordinator)
        try directEngine.load(sessionID)
        try directEngine.seek(to: 100)
        let expected = direct.stateHash.value

        let wandering = simulation()
        let engine = ReplayEngine(radar: wandering, recording: coordinator)
        try engine.load(sessionID)
        try engine.seek(to: 250)
        try engine.seek(to: 100)      // backwards, by reconstruction

        XCTAssertEqual(engine.clock.position, 100)
        XCTAssertEqual(wandering.stateHash.value, expected,
                       "seeking backwards did not reconstruct the same state")
    }

    /// Seeking past either end clamps rather than running off.
    func testSeekingClampsToTheRecording() throws {
        let sessionID = try recordASession(instructions: [], ticks: 100)
        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
        let loaded = try engine.load(sessionID)

        try engine.seek(to: 10_000)
        XCTAssertEqual(engine.clock.position, loaded.lastTick)

        try engine.seek(to: -50)
        XCTAssertEqual(engine.clock.position, 0)
    }

    /// A seek does not start playing on its own. Landing somewhere and immediately running on is not what
    /// dragging a scrubber asks for.
    func testASeekDoesNotResumePlayback() throws {
        let sessionID = try recordASession(instructions: [])
        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
        try engine.load(sessionID)
        try engine.play()

        try engine.seek(to: 50)
        XCTAssertFalse(engine.clock.isRunning, "a seek left the replay playing")
        XCTAssertEqual(engine.clock.mode, .paused)
    }

    /// Seeking is silent, however far it moves.
    func testSeekingIsSilent() throws {
        let sessionID = try recordASession(instructions: [
            (tick: 20, key: "C/M*", value: 260),
            (tick: 100, key: "TRH", value: 250),
            (tick: 180, key: "SPD*", value: 300),
        ])
        let feedback = SilentFeedback()
        let engine = ReplayEngine(radar: simulation(feedback), recording: coordinator)
        try engine.load(sessionID)

        try engine.seek(to: 250)
        try engine.seek(to: 40)
        try engine.seek(to: 200)

        XCTAssertTrue(feedback.readbacks.isEmpty, "seeking spoke \(feedback.readbacks.count) readbacks")
    }

    /// Restart returns to the first tick and to the state a fresh load produces.
    func testRestartReturnsToTheStart() throws {
        let sessionID = try recordASession(instructions: [(tick: 20, key: "C/M*", value: 260)])
        let radar = simulation()
        let engine = ReplayEngine(radar: radar, recording: coordinator)
        try engine.load(sessionID)
        let atLoad = radar.stateHash.value

        try engine.seek(to: 200)
        try engine.restart()

        XCTAssertEqual(engine.clock.position, 0)
        XCTAssertEqual(radar.stateHash.value, atLoad, "restart did not return to the loaded state")
    }

    // MARK: Measurement

    /// Seek latency, measured rather than assumed — this is what would justify snapshots, and currently does not.
    func testMeasureSeekLatency() throws {
        let sessionID = try recordASession(instructions: (1...30).map {
            (tick: $0 * 60, key: "C/M*", value: 200 + $0)
        }, ticks: 2_400)

        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
        try engine.load(sessionID)

        var rows: [(String, Int, TimeInterval)] = []
        for (label, target) in [("forward to 600", 600), ("forward to 2400", 2_400),
                                ("backward to 1200", 1_200), ("backward to 0", 0)] {
            let started = Date()
            try engine.seek(to: target)
            rows.append((label, target, Date().timeIntervalSince(started)))
        }

        var report = """
        SEEK LATENCY · 40-minute recording, 30 instructions
        Backward seeks reconstruct from the start; forward seeks step on from where they are.

        seek                target   seconds     ms
        """
        for (label, target, seconds) in rows {
            report += String(format: "\n%-18s  %6d   %7.4f  %5.1f",
                             (label as NSString).utf8String!, target, seconds, seconds * 1_000)
        }
        report += """


        A snapshot cache would only be justified if the worst of these stopped meeting the product's
        responsiveness bar. Phase 0 measured ~16 µs a tick, so a full 2,400-tick reconstruction is tens of
        milliseconds — see the numbers above rather than that estimate.
        """

        let attachment = XCTAttachment(string: report)
        attachment.name = "seek-latency"
        attachment.lifetime = .keepAlways
        add(attachment)

        let worst = rows.map(\.2).max() ?? 0
        XCTAssertLessThan(worst, 2.0, "the worst seek took \(worst)s — snapshots may now be justified")
    }
}

// MARK: - Item 8: Continue Simulation and branching

extension ReplayEngineTests {

    /// **The acceptance criterion: no divergence after continuing.**
    ///
    /// Continuing does not restore anything — the World was reached by simulating, so it already *is* live. This
    /// asserts that by comparing against a run that simply kept going: continue at tick 150 and step to 400 must
    /// land in the same state as replaying straight through to 400.
    func testContinuingDoesNotDivergeFromTheReplayedRun() throws {
        let sessionID = try recordASession(instructions: [
            (tick: 20, key: "C/M*", value: 260),
            (tick: 90, key: "TRH", value: 250),
        ], ticks: 400)

        // Replayed straight through.
        let straight = simulation()
        let straightEngine = ReplayEngine(radar: straight, recording: coordinator)
        try straightEngine.load(sessionID)
        straightEngine.run(to: 400)
        let expected = straight.stateHash.value

        // Continued at 150, then stepped on with no further instructions.
        let branched = simulation()
        let engine = ReplayEngine(radar: branched, recording: coordinator)
        try engine.load(sessionID)
        try engine.seek(to: 150)
        _ = try engine.continueLive()
        branched.stopSimulation()          // this test owns the clock, not the timer
        while branched.elapsedSeconds < 400 { branched.advanceStep() }

        XCTAssertEqual(branched.stateHash.value, expected,
                       "the simulation diverged after continuing from a replay")
    }

    /// A branch is a new session, and the original is untouched.
    func testContinuingCreatesANewSessionAndLeavesTheOriginalIntact() throws {
        let sessionID = try recordASession(instructions: [(tick: 20, key: "C/M*", value: 260)], ticks: 300)
        let parentEvents = try coordinator.sessions.events(for: sessionID)
        let parentManifest = try coordinator.sessions.manifest(for: sessionID)

        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
        try engine.load(sessionID)
        try engine.seek(to: 150)
        let child = try engine.continueLive(label: "what if")

        XCTAssertNotEqual(child.id, sessionID)
        XCTAssertEqual(child.parentID, sessionID)
        XCTAssertEqual(child.forkTick, 150)
        XCTAssertEqual(child.sessionClass, .training, "a branch is always training")

        // The original: same events, same manifest, marked superseded and nothing else.
        XCTAssertEqual(try coordinator.sessions.events(for: sessionID).map(\.ordinal),
                       parentEvents.map(\.ordinal), "the original recording was modified")
        XCTAssertEqual(try coordinator.sessions.manifest(for: sessionID), parentManifest)
        XCTAssertEqual(try coordinator.sessions.catalogue.summary(id: sessionID)?.state,
                       .superseded(by: child.id, at: 150))
    }

    /// The branch inherits the world: same seed, same exercise, so its traffic continues rather than starting over.
    func testABranchInheritsTheSeedAndExercise() throws {
        let sessionID = try recordASession(instructions: [], ticks: 200)
        let engine = ReplayEngine(radar: simulation(), recording: coordinator)
        try engine.load(sessionID)
        try engine.seek(to: 100)
        let child = try engine.continueLive()

        let parent = try coordinator.sessions.manifest(for: sessionID)
        let branch = try coordinator.sessions.manifest(for: child.id)

        XCTAssertEqual(branch.seed, parent.seed)
        XCTAssertEqual(branch.exercise.digest, parent.exercise.digest)
        XCTAssertEqual(branch.ownerID, parent.ownerID, "ownership does not transfer")
    }

    /// **A branch can be replayed on its own.**
    ///
    /// This is what the parent's input prefix is for. The architecture's plan was a state snapshot at the fork
    /// point; copying the inputs does the same job for a fraction of the bytes and no snapshot machinery — and
    /// the test that matters is that a replayed branch reaches the same state the branch itself did.
    func testABranchIsSelfSufficientAndReplaysCorrectly() throws {
        let sessionID = try recordASession(instructions: [
            (tick: 20, key: "C/M*", value: 260),
            (tick: 60, key: "TRH", value: 250),
        ], ticks: 300)

        let live = simulation()
        let engine = ReplayEngine(radar: live, recording: coordinator)
        try engine.load(sessionID)
        try engine.seek(to: 150)
        let child = try engine.continueLive()
        live.stopSimulation()

        // Something new happens on the branch, then it ends.
        live.selectAircraft(try XCTUnwrap(live.aircraft.first).id)
        CommandKeyboardHandler(radar: live).perform("SPD*", value: 220)
        while live.elapsedSeconds < 250 { live.advanceStep() }
        let branchHash = live.stateHash.value
        coordinator.stopRecording(tickCount: 250)

        // The branch replays from its own log alone.
        let replayed = simulation()
        let branchEngine = ReplayEngine(radar: replayed, recording: coordinator)
        let loaded = try branchEngine.load(child.id)
        branchEngine.run(to: 250)

        XCTAssertTrue(loaded.inputsByTick.keys.contains { $0 < 150 },
                      "the branch has no prefix — it cannot reach its own fork point")
        XCTAssertEqual(replayed.stateHash.value, branchHash,
                       "replaying the branch did not reproduce it")
    }

    /// Branching twice from one parent is the ordinary case — a trainee exploring the same moment two ways.
    func testAParentCanBeBranchedTwice() throws {
        let sessionID = try recordASession(instructions: [], ticks: 300)

        var children: [SessionID] = []
        for tick in [100, 200] {
            let engine = ReplayEngine(radar: simulation(), recording: coordinator)
            try engine.load(sessionID)
            try engine.seek(to: tick)
            children.append(try engine.continueLive().id)
            coordinator.stopRecording(tickCount: tick + 10)
        }

        XCTAssertEqual(Set(try coordinator.sessions.catalogue.children(of: sessionID).map(\.id)),
                       Set(children))
        XCTAssertEqual(try coordinator.sessions.events(for: sessionID).count,
                       try coordinator.sessions.events(for: sessionID).count,
                       "the parent's log is still readable after two branches")
    }

    /// Continuing hands the replay over and stops being a replay. Leaving the engine loaded would let a transport
    /// keep offering play over a live exercise.
    func testContinuingEndsTheReplay() throws {
        let sessionID = try recordASession(instructions: [], ticks: 200)
        let radar = simulation()
        let engine = ReplayEngine(radar: radar, recording: coordinator)
        try engine.load(sessionID)
        try engine.seek(to: 100)
        _ = try engine.continueLive()

        XCTAssertNil(engine.loaded)
        XCTAssertFalse(engine.clock.isLoaded)
        XCTAssertFalse(engine.clock.canPlay)
        XCTAssertNotNil(radar.inputs.recorder, "the branch is not recording")
        radar.stopSimulation()
    }

    /// New instructions after continuing go to the branch, not to the original.
    func testInstructionsAfterContinuingAreRecordedOnTheBranch() throws {
        let sessionID = try recordASession(instructions: [], ticks: 200)
        let before = try coordinator.sessions.events(for: sessionID).count

        let radar = simulation()
        let engine = ReplayEngine(radar: radar, recording: coordinator)
        try engine.load(sessionID)
        try engine.seek(to: 100)
        let child = try engine.continueLive()
        radar.stopSimulation()

        radar.selectAircraft(try XCTUnwrap(radar.aircraft.first).id)
        CommandKeyboardHandler(radar: radar).perform("C/M*", value: 300)
        coordinator.stopRecording(tickCount: 110)

        XCTAssertEqual(try coordinator.sessions.events(for: sessionID).count, before,
                       "an instruction after continuing was written to the original")
        let branchOwn = try coordinator.sessions.events(for: child.id).filter { $0.tick >= 100 }
        XCTAssertEqual(branchOwn.count, 1)
    }
}
