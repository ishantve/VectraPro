//
//  InputGatewayTests.swift
//  VectraProTests
//
//  The five invariants, each as a test. The one that matters most is the last: a recorded exercise and an
//  unrecorded one must be the same exercise, and nothing else in the suite would notice if they stopped
//  being.
//

import XCTest
import ATCParserKit
import ATCReplayKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class InputGatewayTests: XCTestCase {

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

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Gateway-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeSimulation() -> MapViewModel {
        MapViewModel(spawner: AircraftSpawner(), feedback: SilentFeedback(), reports: SilentReports())
    }

    private func attachRecorder(to viewModel: MapViewModel,
                                sessionClass: SessionClass = .training) throws -> SessionRecorder {
        let recorder = SessionRecorder(
            sessionID: UUID(), sessionClass: sessionClass,
            manifestBytes: Data(#"{"seed":1}"#.utf8),
            store: EventStore(url: directory.appendingPathComponent("events.log"),
                              sessionClass: sessionClass, coding: ATCEventCodec()))
        viewModel.inputs.resume(after: try recorder.open())
        viewModel.inputs.recorder = recorder
        return recorder
    }

    private func log(_ sessionClass: SessionClass = .training) throws -> [Event] {
        try EventStore(url: directory.appendingPathComponent("events.log"),
                       sessionClass: sessionClass, coding: ATCEventCodec()).readAll()
    }

    // MARK: - Stamping

    /// `(tick, ordinal)`: ordinals advance by one, and several inputs in one tick share it.
    func testOrdinalsAdvanceAndATickCanBeShared() {
        let gateway = InputGateway(currentTick: { 42 })
        let positions = (0..<3).map { _ in
            gateway.submit(SimulationInput(code: "101", callsign: "AIC1",
                                          slots: [:], source: .voice)).position
        }
        XCTAssertEqual(positions.map(\.ordinal), [1, 2, 3])
        XCTAssertEqual(Set(positions.map(\.tick)), [42])
    }

    /// **Required after a crash.** Event ids are derived from `(session, ordinal)`, so a counter restarting
    /// at 1 would mint ids that already exist and silently point two events at the same name.
    func testResumingContinuesTheOrdinalSequence() {
        let gateway = InputGateway(currentTick: { 0 })
        gateway.resume(after: EventPosition(tick: 900, ordinal: 137))

        let receipt = gateway.submit(SimulationInput(code: "101", callsign: "A", slots: [:],
                                                    source: .voice))
        XCTAssertEqual(receipt.position.ordinal, 138)
    }

    /// The ordinal advances whether or not anything is recording, so starting a recording partway through
    /// cannot reuse an ordinal — and the counter behaves identically either way.
    func testOrdinalsAdvanceEvenWithNoRecorder() {
        let gateway = InputGateway(currentTick: { 0 })
        _ = gateway.submit(SimulationInput(code: "101", callsign: "A", slots: [:], source: .voice))
        let second = gateway.submit(SimulationInput(code: "102", callsign: "A", slots: [:],
                                                   source: .voice))

        XCTAssertEqual(second.position.ordinal, 2)
        XCTAssertFalse(second.wasRecorded)
    }

    // MARK: - Recording observes

    /// Phraseology is what is recorded — a code and its slot values, not the `AircraftCommand`s they map to.
    func testACommandIsRecordedAsPhraseologyNotAsEffects() throws {
        let viewModel = makeSimulation()
        viewModel.reset(seed: 0xC0DE)
        viewModel.stopSimulation()
        let recorder = try attachRecorder(to: viewModel)

        let target = try XCTUnwrap(viewModel.aircraft.first)
        viewModel.selectAircraft(target.id)
        CommandKeyboardHandler(radar: viewModel).perform("C/M*", value: 260)
        recorder.flush()

        let events = try log()
        XCTAssertEqual(events.count, 1)
        // Post-R-Dist: payloads are opaque to ReplayCore; the ATC adapter decodes the typed payload back.
        guard case .commandIssued(let code, _, let slots) = ATCEvent.payload(of: events[0]) else {
            return XCTFail("expected commandIssued")
        }
        XCTAssertEqual(code, "101", "the phraseology code, not a mapped command")
        XCTAssertEqual(slots["LEVEL"], "260")
        XCTAssertEqual(events[0].source, .keypad)
    }

    /// Source attribution follows the path the instruction came in on.
    func testVoiceAndKeypadAreAttributedDifferently() throws {
        let viewModel = makeSimulation()
        viewModel.reset(seed: 0xC0DE)
        viewModel.stopSimulation()
        let recorder = try attachRecorder(to: viewModel)

        let target = try XCTUnwrap(viewModel.aircraft.first)
        viewModel.selectAircraft(target.id)
        CommandKeyboardHandler(radar: viewModel).perform("C/M*", value: 260)
        viewModel.handleVoiceCommand("\(target.callsign) descend to flight level one two zero")
        recorder.flush()

        let sources = try log().map(\.source)
        XCTAssertTrue(sources.contains(.keypad))
        XCTAssertTrue(sources.contains(.voice), "got \(sources)")
    }

    /// The recording layer stamps real time; the gateway and the simulation do not. `DeterministicTimeTests`
    /// enforces the other half of that by banning real time from the command path.
    func testTheRecorderStampsAuditTime() throws {
        let viewModel = makeSimulation()
        viewModel.reset(seed: 1)
        viewModel.stopSimulation()
        let recorder = try attachRecorder(to: viewModel)
        recorder.now = { Date(timeIntervalSince1970: 1_700_000_000) }

        viewModel.selectAircraft(try XCTUnwrap(viewModel.aircraft.first).id)
        CommandKeyboardHandler(radar: viewModel).perform("C/M*", value: 260)
        recorder.flush()

        XCTAssertEqual(try log().first?.wallClock?.timeIntervalSince1970, 1_700_000_000)
    }

    // MARK: - Recording never alters

    /// **The invariant nothing else would catch.** The same seed and the same instructions must reach the
    /// same state whether or not a recorder was attached.
    func testRecordingDoesNotChangeTheSimulation() throws {
        func run(recording: Bool) throws -> UInt64 {
            let viewModel = makeSimulation()
            viewModel.reset(seed: 0xA11CE5)
            viewModel.stopSimulation()

            var recorder: SessionRecorder?
            if recording {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("events.log"))
                recorder = try attachRecorder(to: viewModel)
            }

            for tick in 1...600 {
                if tick == 30, let target = viewModel.aircraft.first {
                    viewModel.selectAircraft(target.id)
                    CommandKeyboardHandler(radar: viewModel).perform("C/M*", value: 260)
                }
                if tick == 120, let target = viewModel.aircraft.first {
                    viewModel.selectAircraft(target.id)
                    CommandKeyboardHandler(radar: viewModel).perform("TRH", value: 250)
                }
                viewModel.advanceStep()
            }
            recorder?.flush()
            return viewModel.stateHash.value
        }

        XCTAssertEqual(try run(recording: true), try run(recording: false),
                       "attaching a recorder changed the simulation")
    }

    /// A recorder that cannot write must not stop the exercise. An earlier draft of the design refused the
    /// input; a trainee should not lose an instruction because a disk filled up.
    func testAFailingRecorderDoesNotStopTheSimulation() throws {
        let viewModel = makeSimulation()
        viewModel.reset(seed: 0xBEEF)
        viewModel.stopSimulation()

        // Never opened, so every write fails.
        let recorder = SessionRecorder(
            sessionID: UUID(), sessionClass: .assessment,
            manifestBytes: Data("{}".utf8),
            store: EventStore(url: directory.appendingPathComponent("nowhere/events.log"),
                              sessionClass: .assessment, coding: ATCEventCodec()))
        viewModel.inputs.recorder = recorder

        let target = try XCTUnwrap(viewModel.aircraft.first)
        viewModel.selectAircraft(target.id)
        CommandKeyboardHandler(radar: viewModel).perform("C/M*", value: 260)

        XCTAssertEqual(viewModel.aircraft.first { $0.id == target.id }?.targetAltitudeFeet, 26_000,
                       "the instruction was lost because recording failed")
        XCTAssertTrue(recorder.isDegraded)
        XCTAssertNil(recorder.finish(), "a degraded assessment must not be sealable")
    }

    // MARK: - Annotations

    /// Recorded, never dispatched: a readback is a thing the trainee heard and it drives nothing.
    func testAnAnnotationIsRecordedWithoutAffectingTheSimulation() throws {
        let viewModel = makeSimulation()
        viewModel.reset(seed: 7)
        viewModel.stopSimulation()
        let recorder = try attachRecorder(to: viewModel)

        let before = viewModel.stateHash.value
        viewModel.inputs.annotate { ATCEvent.readbackSpoken(callsign: "AIC1", spoken: "CLIMBING", at: $0) }
        recorder.flush()

        XCTAssertEqual(viewModel.stateHash.value, before)
        XCTAssertEqual(try log().count, 1)
        XCTAssertEqual(try log().first?.source, .system)
    }
}
