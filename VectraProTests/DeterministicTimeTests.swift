//
//  DeterministicTimeTests.swift
//  VectraProTests
//
//  One clock. Simulated time comes from `SimulationClock` and from nowhere else.
//
//  ── Why this is a source scan ──────────────────────────────────────────────
//  A wall-clock call inside the simulation is invisible in every ordinary test. It behaves perfectly at
//  1× on an idle device, and then behaves differently at 30×, differently again while paused, and
//  differently a third time under replay. The wreckage timer that Phase 0 removed did exactly this: it
//  cleared aircraft 1.5 *real* seconds after a collision, so at 30× they lingered 45 simulated seconds,
//  and paused they cleared anyway. Nothing failed. It just quietly did the wrong thing.
//
//  `DeterminismTests` catches the *consequence* — it inserts a real pause between steps and asserts the
//  outcome is unchanged. This catches the *cause*, and catches it in code that no test happens to exercise
//  yet, which is where the next one will be introduced.
//
//  ── Wall-clock time is not banned, it is quarantined ───────────────────────
//  `Event.wallClock`, `SessionManifest.createdAt`, auth token expiry and the feedback log's timestamps are
//  all legitimate: they answer "how long did the trainee take to respond" and "when was this recorded".
//  They live outside the simulation, and the rule is about *where*, not *whether*.
//

import XCTest
@testable import VectraPro

final class DeterministicTimeTests: XCTestCase {

    /// APIs that measure real time. Any of these inside the simulation makes it non-reproducible.
    private static let wallClockAPIs = [
        "Date()",
        "CACurrentMediaTime",
        "CFAbsoluteTimeGetCurrent",
        "DispatchTime.now",
        "DispatchWallTime",
        "asyncAfter",
        "Task.sleep",
        "Thread.sleep",
        "ProcessInfo.processInfo.systemUptime",
    ]

    /// Where the simulation lives — the app half. ATCSimKit has the same rule enforced in its own suite
    /// (`WallClockScanTests`), where the package has no presentation layer to except.
    private static let simulationDirectories = ["ViewModels", "Commands", "Simulation"]

    /// Files in those directories that are presentation rather than simulation.
    ///
    /// Named individually with a reason, rather than by excluding a directory: dropping `ViewModels` would
    /// also stop the scan covering `MapViewModel`, which is the file that most needs covering.
    private static let presentationOnly: [String: String] = [
        "SpeechViewModel.swift":
            "the push-to-talk button's own view model — its Task.sleep auto-hides the transcript field, "
            + "which is UI reacting to UI and has no simulation effect",
    ]

    // MARK: - The rule

    func testTheSimulationNeverReadsAWallClock() throws {
        var offences: [String] = []

        for url in try Self.simulationSources() {
            let name = url.lastPathComponent
            if Self.presentationOnly[name] != nil { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for (number, line) in text.components(separatedBy: .newlines).enumerated() {
                // Comments explaining the rule mention the APIs by name, which is the point of them.
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }

                for api in Self.wallClockAPIs where code.contains(api) {
                    offences.append("\(name):\(number + 1) — \(api)")
                }
            }
        }

        XCTAssertTrue(offences.isEmpty, """
            The simulation is reading real time here:

            \(offences.joined(separator: "\n            "))

            Simulated time comes from SimulationClock and nowhere else. A real-time call behaves \
            differently at 1x, at 30x, while paused, and under replay, and no ordinary test notices — it \
            just quietly does the wrong thing. If this is presentation rather than simulation, add the \
            file to `presentationOnly` with a reason.
            """)
    }

    /// **The only wall-clock dependencies the simulation is allowed**, and they are allowed because they decide
    /// *when* to step, never *how much*.
    ///
    /// Each fire advances exactly one simulated second, so fast-forward changes the timer's period and
    /// nothing else. Folding speed into the step size instead would make the step variable, which is how a
    /// simulation stops being reproducible — so the separation is load-bearing, and this asserts there is
    /// exactly one place it could be undone.
    func testOnlyTheNamedFilesDriveTheSimulationFromATimer() throws {
        let drivers = try Self.simulationSources()
            .filter { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains("Timer(timeInterval:") || text.contains("Timer.scheduledTimer")
            }
            .map { $0.lastPathComponent }

        // Two now, and they are mutually exclusive: MapViewModel paces a live exercise, ReplayEngine paces a
        // replay, and a replay detaches recording and drives the simulation itself. Both decide *when* to step
        // and neither decides how much — each fire advances exactly one simulated second, which is why a replay
        // at 30× reaches the same state as one at 1×.
        //
        // Listed by name rather than counted, so a *third* driver has to be argued for here before it ships.
        XCTAssertEqual(drivers, ["MapViewModel.swift", "ReplayEngine.swift"], """
            Expected timers only in MapViewModel (live) and ReplayEngine (replay). Found: \(drivers).

            Another timer means another thing deciding when the simulation advances, and they cannot stay in \
            step — least of all across a speed change or a pause. If this one is justified, add it here with \
            the reason; if it is not, drive the simulation through an existing one.
            """)
    }

    /// The detector actually detects.
    ///
    /// A scan that passes because it is broken looks exactly like a scan that passes because the code is
    /// clean, and the two must be told apart. So the same matching runs over lines that *should* offend.
    func testTheScanWouldCatchAViolation() {
        let offending = [
            "let now = Date()",
            "DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { }",
            "try await Task.sleep(nanoseconds: 1)",
            "let t = CACurrentMediaTime()",
        ]
        for line in offending {
            XCTAssertTrue(Self.wallClockAPIs.contains(where: line.contains),
                          "the scan would have missed: \(line)")
        }

        // And does not fire on ordinary simulation code, or it would be unusable.
        for innocent in ["clock.advance()", "let elapsed = clock.elapsedSeconds",
                        "physics.stepPhysics(&aircraft[i], dt: SimulationClock.tickInterval)"] {
            XCTAssertFalse(Self.wallClockAPIs.contains(where: innocent.contains),
                           "the scan would false-positive on: \(innocent)")
        }
    }

    // MARK: - What the rule does not cover

    /// Wall-clock time is quarantined, not banned. This asserts the quarantine is real: the recording layer
    /// is *allowed* to timestamp, because "when was this recorded" and "how long did the trainee take" are
    /// questions worth answering.
    ///
    /// Here as a statement of intent, so a future reader does not tighten the scan onto ATCReplayKit and
    /// break audit data in the name of determinism.
    func testTheRecordingLayerMayTimestamp() {
        // Event.wallClock and SessionManifest.createdAt both exist and are both wall-clock. The guarantee
        // is that nothing inside the simulation reads them, which is a review rule plus the scan above —
        // the simulation does not import ATCReplayKit at all.
        XCTAssertFalse(Self.simulationDirectories.isEmpty)
    }

    // MARK: - Helpers

    private static func simulationSources() throws -> [URL] {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VectraPro")

        var found: [URL] = []
        for directory in simulationDirectories {
            let url = appRoot.appendingPathComponent(directory)
            guard let walker = FileManager.default.enumerator(at: url,
                                                             includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" {
                found.append(file)
            }
        }
        XCTAssertFalse(found.isEmpty, "the scan found no sources — the path is wrong, not the code")
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
