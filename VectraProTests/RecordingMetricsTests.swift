//
//  RecordingMetricsTests.swift
//  VectraProTests
//
//  Exit validation for Phase B: what recording actually costs, measured through the real pipeline.
//
//  ── Why attachments rather than print ──────────────────────────────────────
//  A first version of this printed its figures, and they could not be recovered from the result bundle
//  afterwards — a measurement nobody can read is not a measurement. Everything here is attached with
//  `XCTAttachment`, which is stored in the bundle and can be exported with `xcresulttool`. So the numbers
//  become part of the report rather than something that scrolled past in a console.
//
//  Memory is read from the kernel via `task_info`, not estimated. Phase footprints are taken at the same
//  point in each run so they are comparable, and the interesting figure is the *difference* recording makes,
//  not the absolute — which is dominated by the simulator and the test host.
//

import XCTest
import ATCParserKit
import ATCReplayKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class RecordingMetricsTests: XCTestCase {

    // MARK: - Harness

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

    private func simulation() -> MapViewModel {
        MapViewModel(spawner: AircraftSpawner(), feedback: SilentFeedback(), reports: SilentReports())
    }

    /// Resident footprint, from the kernel. Not an estimate.
    private func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Records `text` into the result bundle so it reaches the report.
    private func attach(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print(text)
    }

    private static func mb(_ bytes: UInt64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    // MARK: - Event counts, storage growth, latency

    /// Short, medium and long exercises, recorded through the app's own path.
    ///
    /// One instruction every twenty simulated seconds — busier than a real exercise, so the figures are an
    /// upper bound rather than a flattering case.
    func testCaptureEventCountsAndStorageGrowth() throws {
        struct Row {
            let label: String, minutes: Int, ticks: Int, events: Int
            let logBytes: Int, manifestBytes: Int
            let recordSeconds: TimeInterval, footprintDelta: Int64
        }
        var rows: [Row] = []

        for (label, minutes) in [("short", 5), ("medium", 20), ("long", 40)] {
            let ticks = minutes * 60
            let coordinator = SessionCoordinator(root: root.appendingPathComponent(label),
                                                 catalogue: InMemorySessionCatalogue())
            let radar = simulation()
            radar.recording = coordinator
            radar.reset(seed: 0xF0_0D)
            radar.stopSimulation()

            let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)
            let recorder = try XCTUnwrap(radar.inputs.recorder)

            let keys = ["C/M*", "D/M*", "TRH", "TLH", "SPD*"]
            let values = [260, 120, 250, 90, 300]

            let before = footprintBytes()
            let started = Date()
            for tick in 1...ticks {
                if tick % 20 == 0,
                   let target = radar.aircraft.min(by: { $0.id.uuidString < $1.id.uuidString }) {
                    radar.selectAircraft(target.id)
                    let index = (tick / 20) % keys.count
                    CommandKeyboardHandler(radar: radar).perform(keys[index], value: values[index])
                }
                radar.advanceStep()
            }
            let elapsed = Date().timeIntervalSince(started)
            let after = footprintBytes()

            let events = recorder.acceptedCount
            coordinator.stopRecording(tickCount: ticks)

            let logBytes = (try? Data(contentsOf: coordinator.sessions.eventLogURL(for: sessionID)).count) ?? 0
            let manifestBytes = (try? Data(contentsOf: coordinator.sessions.manifestURL(for: sessionID)).count) ?? 0

            rows.append(Row(label: label, minutes: minutes, ticks: ticks, events: events,
                            logBytes: logBytes, manifestBytes: manifestBytes,
                            recordSeconds: elapsed,
                            footprintDelta: Int64(after) - Int64(before)))

            XCTAssertGreaterThan(events, 0, "\(label): nothing recorded")
            XCTAssertFalse(recorder.isDegraded, "\(label): recording degraded")
        }

        var report = """
        EVENT COUNTS · STORAGE GROWTH · LATENCY
        one instruction every 20 simulated seconds — an upper bound, busier than a real exercise

        exercise  sim-min  ticks  events  log bytes  bytes/event  manifest  wall s   µs/tick  Δfootprint
        """
        for row in rows {
            report += String(
                format: "\n%-8s  %7d  %5d  %6d  %9d  %11d  %8d  %6.3f  %8.1f  %+.1f MB",
                (row.label as NSString).utf8String!, row.minutes, row.ticks, row.events,
                row.logBytes, row.events == 0 ? 0 : row.logBytes / row.events, row.manifestBytes,
                row.recordSeconds, row.recordSeconds / Double(row.ticks) * 1_000_000,
                Double(row.footprintDelta) / 1_048_576)
        }

        if let long = rows.last, long.events > 0 {
            let perEvent = Double(long.logBytes) / Double(long.events)
            report += """


            Extrapolated from the long run (\(long.events) events, \(long.logBytes) bytes):
              per event            \(String(format: "%.0f", perEvent)) bytes
              per simulated hour   \(String(format: "%.0f", perEvent * Double(long.events) / Double(long.minutes) * 60)) bytes
              100 sessions         \(String(format: "%.1f", Double(long.logBytes + long.manifestBytes) * 100 / 1_048_576)) MB
            """
        }
        attach("event-counts-and-storage", report)
    }

    /// What recording costs, as the difference between the same run with and without a recorder.
    ///
    /// The absolute time is dominated by the simulation, so the delta is the only interesting figure. Warmed
    /// first: the first run in a fresh process pays for lazy setup, and attributing that to recording would
    /// overstate it several times over.
    func testCaptureRecordingOverhead() throws {
        func run(recording: Bool) throws -> (seconds: TimeInterval, events: Int) {
            let radar = simulation()
            var recorder: SessionRecorder?
            if recording {
                let coordinator = SessionCoordinator(root: root.appendingPathComponent(UUID().uuidString),
                                                     catalogue: InMemorySessionCatalogue())
                radar.recording = coordinator
                radar.reset(seed: 0xBEEF)
                recorder = radar.inputs.recorder
            } else {
                radar.reset(seed: 0xBEEF)
            }
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
            let events = recorder?.acceptedCount ?? 0
            radar.clearOnExit()
            return (elapsed, events)
        }

        _ = try run(recording: false)          // warm

        var without: [TimeInterval] = []
        var with: [TimeInterval] = []
        var events = 0
        for _ in 0..<3 {
            without.append(try run(recording: false).seconds)
            let recorded = try run(recording: true)
            with.append(recorded.seconds)
            events = recorded.events
        }

        let bestWithout = without.min() ?? 0
        let bestWith = with.min() ?? 0
        let delta = bestWith - bestWithout

        attach("recording-overhead", """
        RECORDING OVERHEAD · 2,400 ticks, 120 instructions, best of 3

        without recording     \(String(format: "%.4f", bestWithout)) s   (\(String(format: "%.1f", bestWithout / 2_400 * 1_000_000)) µs/tick)
        with recording        \(String(format: "%.4f", bestWith)) s   (\(String(format: "%.1f", bestWith / 2_400 * 1_000_000)) µs/tick)
        difference            \(String(format: "%+.4f", delta)) s  (\(String(format: "%+.1f", bestWithout == 0 ? 0 : delta / bestWithout * 100))%)
        events recorded       \(events)
        cost per event        \(String(format: "%.1f", events == 0 ? 0 : delta / Double(events) * 1_000_000)) µs

        all runs, without:  \(without.map { String(format: "%.4f", $0) }.joined(separator: ", "))
        all runs, with:     \(with.map { String(format: "%.4f", $0) }.joined(separator: ", "))
        """)

        XCTAssertLessThan(bestWith, bestWithout * 4 + 0.5, "recording cost far more than expected")
    }

    /// Seal cost, incremental against one pass.
    func testCaptureSealPerformance() throws {
        let manifest = Data(repeating: 0x7B, count: 2_000)
        let frame = Data(repeating: 0x41, count: 200)
        let frames = 5_000

        var builder = SessionSealBuilder(manifest: manifest)
        let incrementalStart = Date()
        for _ in 0..<frames { builder.add(frame: frame) }
        let sealValue = builder.seal()
        let incremental = Date().timeIntervalSince(incrementalStart)

        var log = Data()
        for _ in 0..<frames { log.append(frame) }
        let onePassStart = Date()
        let recomputed = SessionSeal.compute(manifest: manifest, log: log)
        let onePass = Date().timeIntervalSince(onePassStart)

        XCTAssertEqual(sealValue, recomputed, "the two seal forms disagreed")

        attach("seal-performance", """
        SEAL PERFORMANCE · \(frames) frames of 200 bytes (\(log.count) bytes)

        incremental, total       \(String(format: "%.4f", incremental)) s
        incremental, per event   \(String(format: "%.2f", incremental / Double(frames) * 1_000_000)) µs
        one pass at the end      \(String(format: "%.4f", onePass)) s
        throughput, one pass     \(String(format: "%.0f", Double(log.count) / onePass / 1_048_576)) MB/s

        Both forms agree, which is the property that makes an assessment verifiable at all.
        Per-event cost is what recording pays; the one-pass figure is what a reader pays to verify.
        """)
    }

    /// Memory, from the kernel, across a recorded session.
    ///
    /// Sampled at the same points with and without recording, so the difference is attributable. The absolute
    /// numbers include the test host and are not the app's footprint.
    func testCaptureMemoryProfile() throws {
        func profile(recording: Bool) -> (baseline: UInt64, mid: UInt64, end: UInt64, afterRelease: UInt64) {
            let baseline = footprintBytes()
            var radar: MapViewModel? = simulation()
            if recording {
                radar?.recording = SessionCoordinator(root: root.appendingPathComponent(UUID().uuidString),
                                                      catalogue: InMemorySessionCatalogue())
            }
            radar?.reset(seed: 0xCAFE)
            radar?.stopSimulation()

            for tick in 1...1_200 {
                if tick % 20 == 0, let target = radar?.aircraft.first {
                    radar?.selectAircraft(target.id)
                    if let radar { CommandKeyboardHandler(radar: radar).perform("C/M*", value: 260) }
                }
                radar?.advanceStep()
            }
            let mid = footprintBytes()
            for _ in 1...1_200 { radar?.advanceStep() }
            let end = footprintBytes()

            radar?.clearOnExit()
            radar = nil
            return (baseline, mid, end, footprintBytes())
        }

        let plain = profile(recording: false)
        let recorded = profile(recording: true)

        attach("memory-profile", """
        MEMORY PROFILE · phys_footprint from task_info, 2,400 ticks
        Absolute values include the test host; the comparison is the point.

                            baseline    mid (1,200)   end (2,400)   after release
        without recording   \(Self.mb(plain.baseline))     \(Self.mb(plain.mid))       \(Self.mb(plain.end))       \(Self.mb(plain.afterRelease))
        with recording      \(Self.mb(recorded.baseline))     \(Self.mb(recorded.mid))       \(Self.mb(recorded.end))       \(Self.mb(recorded.afterRelease))

        growth over the run
          without           \(String(format: "%+.1f MB", Double(Int64(plain.end) - Int64(plain.baseline)) / 1_048_576))
          with              \(String(format: "%+.1f MB", Double(Int64(recorded.end) - Int64(recorded.baseline)) / 1_048_576))
          attributable      \(String(format: "%+.1f MB", (Double(Int64(recorded.end) - Int64(recorded.baseline)) - Double(Int64(plain.end) - Int64(plain.baseline))) / 1_048_576))

        Recording holds a seal hasher, a small append buffer, and — for training — events not yet
        flushed. Nothing accumulates per tick, which is what the second half of the run checks: the
        1,200→2,400 stretch issues no instructions, so a rising footprint there would be a leak in the
        step loop rather than in recording.
        """)
    }

    /// CPU and memory through XCTest's own metrics, which land in the result bundle as measurements.
    ///
    /// A cross-check on the hand-rolled timings above: if the two disagree, one of them is wrong.
    func testMeasureRecordedStepCost() throws {
        let coordinator = SessionCoordinator(root: root, catalogue: InMemorySessionCatalogue())
        let radar = simulation()
        radar.recording = coordinator
        radar.reset(seed: 0x1234)
        radar.stopSimulation()

        measure(metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]) {
            for tick in 1...600 {
                if tick % 20 == 0, let target = radar.aircraft.first {
                    radar.selectAircraft(target.id)
                    CommandKeyboardHandler(radar: radar).perform("C/M*", value: 260)
                }
                radar.advanceStep()
            }
        }
        coordinator.stopRecording(tickCount: radar.elapsedSeconds)
    }
}
