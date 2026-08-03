//
//  RecordingMetricsTests.swift
//  VectraProTests
//
//  Measurements for the Phase B review. Not assertions about design — numbers, taken from a real recording
//  through the real pipeline, so the review reports what recording actually costs rather than what I estimated
//  it would.
//
//  The thresholds are deliberately loose. These exist to produce figures and to catch an order-of-magnitude
//  regression; a tight bound on a device-dependent measurement would fail for reasons that are not bugs.
//

import XCTest
import ATCParserKit
import ATCReplayKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class RecordingMetricsTests: XCTestCase {

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

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Metrics-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Metrics go to a file as well as the console.
    ///
    /// `print` from a test does not reliably survive into the result bundle, and a measurement nobody can read
    /// is not a measurement.
    private func report(_ text: String) {
        print(text)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vectrapro-metrics.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func simulation() -> MapViewModel {
        MapViewModel(spawner: AircraftSpawner(), feedback: SilentFeedback(), reports: SilentReports())
    }

    /// A forty-minute exercise, recorded, with an instruction every twenty simulated seconds — busier than a
    /// real one, so the figures are an upper bound rather than a flattering case.
    func testMeasureAFortyMinuteRecording() throws {
        let coordinator = SessionCoordinator(root: root, catalogue: InMemorySessionCatalogue())
        let radar = simulation()
        radar.recording = coordinator
        radar.reset(seed: 0xF0_0D)
        radar.stopSimulation()

        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)
        let recorder = try XCTUnwrap(radar.inputs.recorder)

        let keys = ["C/M*", "D/M*", "TRH", "TLH", "SPD*"]
        let values = [260, 120, 250, 90, 300]

        let started = Date()
        for tick in 1...2_400 {
            if tick % 20 == 0,
               let target = radar.aircraft.min(by: { $0.id.uuidString < $1.id.uuidString }) {
                radar.selectAircraft(target.id)
                let index = (tick / 20) % keys.count
                CommandKeyboardHandler(radar: radar).perform(keys[index], value: values[index])
            }
            radar.advanceStep()
        }
        let wallSeconds = Date().timeIntervalSince(started)

        let events = recorder.acceptedCount
        let seal = recorder.seal
        coordinator.stopRecording(tickCount: 2_400)

        let logBytes = (try? Data(contentsOf: coordinator.sessions.eventLogURL(for: sessionID)).count) ?? 0
        let manifestBytes = (try? Data(contentsOf: coordinator.sessions.manifestURL(for: sessionID)).count) ?? 0

        report("""
        ── METRICS · 40 simulated minutes, 2,400 ticks ──────────────────────────
        events recorded      \(events)
        event log            \(logBytes) bytes  (\(events == 0 ? 0 : logBytes / events) per event)
        manifest             \(manifestBytes) bytes
        total on disk        \(logBytes + manifestBytes) bytes
        wall time            \(String(format: "%.3f", wallSeconds)) s for 2,400 recorded ticks
        per tick             \(String(format: "%.1f", wallSeconds / 2_400 * 1_000_000)) µs
        seal                 \(seal.prefix(16))…
        degraded             \(recorder.isDegraded)
        ────────────────────────────────────────────────────────────────────────
        """)

        XCTAssertGreaterThan(events, 0, "nothing was recorded")
        XCTAssertFalse(recorder.isDegraded)
        XCTAssertLessThan(logBytes, 1_000_000, "a 40-minute session should be well under a megabyte")
    }

    /// Recording's cost, as the difference between the same run with and without a recorder. Two runs rather
    /// than one, because the absolute number is dominated by the simulation and the interesting figure is the
    /// delta.
    func testMeasureRecordingOverhead() throws {
        func run(recording: Bool) throws -> TimeInterval {
            let radar = simulation()
            if recording {
                let directory = root.appendingPathComponent(UUID().uuidString)
                radar.recording = SessionCoordinator(root: directory,
                                                     catalogue: InMemorySessionCatalogue())
            }
            radar.reset(seed: 0xBEEF)
            radar.stopSimulation()

            let started = Date()
            for tick in 1...2_400 {
                if tick % 20 == 0, let target = radar.aircraft.first {
                    radar.selectAircraft(target.id)
                    CommandKeyboardHandler(radar: radar).perform("C/M*", value: 260)
                }
                radar.advanceStep()
            }
            let elapsed = Date().timeIntervalSince(started)
            radar.clearOnExit()
            return elapsed
        }

        // Warmed first: the first run of anything in a fresh process pays for lazy setup, and attributing that
        // to recording would overstate it several times over.
        _ = try run(recording: false)

        let without = try run(recording: false)
        let with = try run(recording: true)

        report("""
        ── METRICS · recording overhead ────────────────────────────────────────
        without recording    \(String(format: "%.3f", without)) s
        with recording       \(String(format: "%.3f", with)) s
        difference           \(String(format: "%+.3f", with - without)) s \
        (\(String(format: "%+.1f", (with - without) / without * 100))%)
        ────────────────────────────────────────────────────────────────────────
        """)

        XCTAssertLessThan(with, without * 4 + 0.5, "recording cost more than expected")
    }

    /// Seal cost on its own: incremental updates over a session's worth of frames, versus one pass at the end.
    func testMeasureSealCost() throws {
        let manifest = Data(repeating: 0x7B, count: 2_000)
        let frame = Data(repeating: 0x41, count: 160)

        var builder = SessionSealBuilder(manifest: manifest)
        let incrementalStart = Date()
        for _ in 0..<2_000 { builder.add(frame: frame) }
        _ = builder.seal()
        let incremental = Date().timeIntervalSince(incrementalStart)

        var log = Data()
        for _ in 0..<2_000 { log.append(frame) }
        let onePassStart = Date()
        _ = SessionSeal.compute(manifest: manifest, log: log)
        let onePass = Date().timeIntervalSince(onePassStart)

        report("""
        ── METRICS · seal ──────────────────────────────────────────────────────
        2,000 frames, 160 bytes each  (\(log.count) bytes)
        incremental, per event   \(String(format: "%.2f", incremental / 2_000 * 1_000_000)) µs
        incremental, total       \(String(format: "%.4f", incremental)) s
        one pass at the end      \(String(format: "%.4f", onePass)) s
        ────────────────────────────────────────────────────────────────────────
        """)

        XCTAssertLessThan(incremental, 0.5, "sealing per event should be negligible")
    }
}
