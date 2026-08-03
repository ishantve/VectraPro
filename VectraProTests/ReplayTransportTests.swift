//
//  ReplayTransportTests.swift
//  VectraProTests
//
//  The boundary a replay UI talks to, and the property that matters about it: **it holds no replay state.**
//
//  The state is computed from the clock on every read, so a UI cannot get out of step with the engine — and the
//  pair (`ReplayTransportState`, `ReplayCommand`) is `Codable`, so the same boundary crosses a React Native bridge
//  or a C interface without anything being added. Both are asserted here rather than assumed, because "the UI owns
//  nothing" is easy to say and easy to break with one cached property.
//

import XCTest
import ATCParserKit
import ATCReplayKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class ReplayTransportTests: XCTestCase {

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

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Transport-\(UUID().uuidString)")
        coordinator = SessionCoordinator(root: root, catalogue: InMemorySessionCatalogue())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let payload = Data("""
    {
      "exerciseName": "Transport", "id": "t-1", "gameEnd": { "time": 0 },
      "mapLocation": { "mapLatitude": 28.5562, "mapLongitude": 77.1000 },
      "runwaysResponse": [], "aircrafts": [], "airlines": [], "commands": [], "fixes": [], "zone": []
    }
    """.utf8)

    private func simulation() -> MapViewModel {
        MapViewModel(spawner: AircraftSpawner(), feedback: SilentFeedback(), reports: SilentReports())
    }

    private func loaded(ticks: Int = 300) throws
        -> (transport: ReplayTransport, engine: ReplayEngine, radar: MapViewModel, sessionID: SessionID) {
        let recording = simulation()
        recording.recording = coordinator
        recording.applyExercise(try JSONDecoder().decode(ExerciseDetail.self, from: Self.payload),
                                payload: Self.payload)
        recording.reset(seed: 0x7A5B)
        recording.stopSimulation()
        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)

        for tick in 1...ticks {
            if tick == 30, let target = recording.aircraft.first {
                recording.selectAircraft(target.id)
                CommandKeyboardHandler(radar: recording).perform("C/M*", value: 260)
            }
            recording.advanceStep()
        }
        coordinator.stopRecording(tickCount: ticks)

        let radar = simulation()
        let engine = ReplayEngine(radar: radar, recording: coordinator)
        try engine.load(sessionID)
        return (ReplayTransport(engine: engine), engine, radar, sessionID)
    }

    // MARK: - It holds nothing

    /// **The property the UI's correctness depends on.** State is computed, so it cannot lag the engine — a cached
    /// `isPlaying` would be a fourth copy of a fact that already has one authority.
    func testStateAlwaysReflectsTheEngineWithoutBeingTold() throws {
        let (transport, engine, _, _) = try loaded()

        XCTAssertEqual(transport.state.position, 0)
        _ = engine.stepForward()
        XCTAssertEqual(transport.state.position, engine.clock.position,
                       "the transport reported a stale position")

        try engine.seek(to: 200)
        XCTAssertEqual(transport.state.position, 200)

        engine.setSpeed(4)
        XCTAssertEqual(transport.state.speed, 4)

        try engine.play()
        XCTAssertEqual(transport.state.mode, "playing")
        try engine.pause()
        XCTAssertEqual(transport.state.mode, "paused")
        engine.tearDown()
    }

    /// An unloaded transport reports nothing available, so a UI does not have to guess.
    func testAnUnloadedTransportOffersNothing() {
        let transport = ReplayTransport(
            engine: ReplayEngine(radar: simulation(), recording: coordinator))

        let state = transport.state
        XCTAssertFalse(state.isLoaded)
        XCTAssertFalse(state.canPlay)
        XCTAssertFalse(state.canPause)
        XCTAssertFalse(state.canSeek)
        XCTAssertEqual(state.duration, 0)
        XCTAssertEqual(state.progress, 0)
    }

    // MARK: - Commands

    /// Every command routes to the engine and nothing else is needed to drive a replay.
    func testEveryCommandDrivesTheEngine() throws {
        let (transport, engine, _, _) = try loaded()

        XCTAssertTrue(transport.perform(.play))
        XCTAssertTrue(engine.clock.isRunning)

        XCTAssertTrue(transport.perform(.pause))
        XCTAssertFalse(engine.clock.isRunning)

        XCTAssertTrue(transport.perform(.setSpeed(10)))
        XCTAssertEqual(engine.clock.speed, 10)

        XCTAssertTrue(transport.perform(.seek(tick: 150)))
        XCTAssertEqual(engine.clock.position, 150)

        XCTAssertTrue(transport.perform(.stepForward))
        XCTAssertEqual(engine.clock.position, 151)

        XCTAssertTrue(transport.perform(.restart))
        XCTAssertEqual(engine.clock.position, 0)
    }

    /// A refused move is reported, not thrown. A button action is not a place to handle an error, and a refused
    /// transport move is worth showing rather than failing on.
    func testARefusedCommandIsReportedRatherThanThrown() throws {
        let (transport, _, _, _) = try loaded()

        XCTAssertTrue(transport.perform(.play))
        XCTAssertFalse(transport.perform(.play), "playing twice should be refused")
        XCTAssertNotNil(transport.lastError)
        XCTAssertTrue(transport.lastError?.contains("playing") ?? false,
                      "the error should name the state: \(transport.lastError ?? "nil")")

        // And a subsequent success clears it, so a UI does not show a stale complaint.
        XCTAssertTrue(transport.perform(.pause))
        XCTAssertNil(transport.lastError)
    }

    /// Continuing through the transport forks, exactly as through the engine.
    func testContinuingThroughTheTransportForks() throws {
        let (transport, _, radar, sessionID) = try loaded()
        transport.perform(.seek(tick: 120))

        XCTAssertTrue(transport.perform(.continueLive(label: "what if")))
        radar.stopSimulation()

        let children = try coordinator.sessions.catalogue.children(of: sessionID)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(children.first?.forkTick, 120)
        XCTAssertFalse(transport.state.isLoaded, "the transport still offered a replay after continuing")
    }

    /// A scrubber works in 0…1 and should not have to know about ticks.
    func testSeekingByProgress() throws {
        let (transport, engine, _, _) = try loaded()
        let duration = transport.state.duration

        transport.seek(toProgress: 0.5)
        XCTAssertEqual(engine.clock.position, duration / 2, accuracy: 1)

        transport.seek(toProgress: 1.5)   // clamped
        XCTAssertEqual(engine.clock.position, duration)

        transport.seek(toProgress: -1)
        XCTAssertEqual(engine.clock.position, 0)
    }

    // MARK: - Platform independence

    /// The boundary crosses a bridge as JSON with nothing added — which is what lets UIKit, React Native and Unity
    /// consume this engine without architectural changes. Asserted rather than claimed.
    func testTheBoundaryIsCodableBothWays() throws {
        let (transport, engine, _, _) = try loaded()
        try engine.seek(to: 90)
        engine.setSpeed(0.5)

        let encoded = try JSONEncoder().encode(transport.state)
        let decoded = try JSONDecoder().decode(ReplayTransportState.self, from: encoded)
        XCTAssertEqual(decoded, transport.state)

        for command: ReplayCommand in [.play, .pause, .restart, .stepForward,
                                       .seek(tick: 42), .setSpeed(0.25),
                                       .continueLive(label: "branch")] {
            let bytes = try JSONEncoder().encode(command)
            XCTAssertEqual(try JSONDecoder().decode(ReplayCommand.self, from: bytes), command)
        }
    }

    /// Mode crosses as a string, so a consumer that cannot see Swift types can still switch on it — and an unknown
    /// mode from a newer build renders as unknown rather than failing to decode.
    func testModeCrossesAsAString() throws {
        let (transport, engine, _, _) = try loaded()
        XCTAssertEqual(transport.state.mode, "stopped")
        try engine.play()
        XCTAssertEqual(transport.state.mode, "playing")
        engine.tearDown()

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(transport.state)) as? [String: Any])
        XCTAssertTrue(object["mode"] is String)
    }

    /// The speeds come from the engine, so a picker cannot offer one `setSpeed` would clamp.
    func testAvailableSpeedsComeFromTheEngine() throws {
        let (transport, _, _, _) = try loaded()
        XCTAssertEqual(transport.state.availableSpeeds, ReplayClock.speedOptions)
        for speed in transport.state.availableSpeeds {
            transport.perform(.setSpeed(speed))
            XCTAssertEqual(transport.state.speed, speed, "the engine clamped an offered speed")
        }
    }

    /// The view is a presentation layer with nothing behind it: a source scan, because "owns no state" is a claim a
    /// stray `@State` would quietly break.
    func testTheTransportBarKeepsNoReplayState() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VectraPro/Views/Components/ReplayTransportBar.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        // `isDragging`/`draggedProgress` are about the finger, not the replay — while a drag is in progress the
        // thumb must follow it rather than snapping back to the engine's position.
        let allowed = ["isDragging", "draggedProgress"]
        for line in source.components(separatedBy: .newlines) {
            // Comments explaining the rule mention `@State` by name, which is the point of them. The wall-clock
            // scan already learned this; I did not carry the lesson over first time.
            let code = line.trimmingCharacters(in: .whitespaces)
            guard !code.hasPrefix("//"), code.contains("@State") else { continue }
            XCTAssertTrue(allowed.contains(where: code.contains),
                          "the transport bar keeps replay state: \(code)")
        }
        XCTAssertFalse(source.contains("import ATCSimKit"),
                       "the view reaches into the simulation instead of the transport")
    }
}
