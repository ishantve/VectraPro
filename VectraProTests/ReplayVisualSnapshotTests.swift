//
//  ReplayVisualSnapshotTests.swift
//  VectraProTests
//
//  Renders the replay surfaces to images so a human can look at them.
//
//  ── Why this exists ────────────────────────────────────────────────────────
//  Every other test in this project asserts something. This one asserts almost nothing on purpose: its output is
//  the attachments, and the check is a person reading them. Layout, contrast, truncation and whether a badge is
//  legible are not properties a test can state — but they are properties that survive being looked at.
//
//  What it cannot verify, and no still image can: scrolling behaviour, gesture feel, and animation. Those need a
//  running app in a hand, and this harness is not a substitute for that — it is what can be checked before it.
//
//  Rendered with `ImageRenderer` at real device widths rather than screenshotted from a booted simulator, because
//  the replay screens sit behind a login and an exercise download; a snapshot harness reaches them with no backend.
//

import XCTest
import SwiftUI
import ATCParserKit
import ATCReplayKit
import ATCSimKit
@testable import VectraPro

@MainActor
final class ReplayVisualSnapshotTests: XCTestCase {

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

    /// iPad landscape and iPhone landscape — the two shapes this app is actually flown in.
    private static let widths: [(name: String, width: CGFloat)] = [
        ("ipad-1194", 1194), ("iphone-852", 852)
    ]

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Snap-\(UUID().uuidString)")
        coordinator = SessionCoordinator(root: root, catalogue: InMemorySessionCatalogue())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Browser

    /// The recording browser, including the cases that are easy to get wrong: a two-deep branch, an assessment
    /// badge beside a long label, and a session that cannot be scored.
    func testBrowserRows() throws {
        let parent = SessionID()
        let child = SessionID()

        let rows: [(SessionSummary, Int)] = [
            (summary(label: "ILS 28 — heavy arrivals", ticks: 1_847), 0),
            (summary(label: "ILS 28 — heavy arrivals", ticks: 1_204, parent: parent, forkTick: 640,
                     id: child, label2: "Continued"), 1),
            (summary(label: "Continued", ticks: 300, parent: child, forkTick: 120), 2),
            (summary(label: "Assessment — Radar Vectoring Stage 2 Final Check", ticks: 2_730,
                     sessionClass: .assessment), 0),
            (summary(label: "Interrupted run", ticks: 96, state: .interrupted), 0),
            (summary(label: "", ticks: 12), 0)
        ]

        for (name, width) in Self.widths {
            let view = VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { entry in
                    SessionRow(summary: entry.element.0, depth: entry.element.1,
                               environment: .current())
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                    Divider()
                }
            }
            .frame(width: width)
            .background(Color(white: 0.98))

            try attach(view, named: "browser-\(name)")
        }
    }

    // MARK: - Transport bar

    /// The transport in the states a reviewer passes through: freshly loaded, part-way and paused, and finished.
    ///
    /// Driven by a real engine over a real recording — a fabricated state would render a bar that cannot happen.
    func testTransportBarStates() throws {
        let sessionID = try recordASession(ticks: 300)

        for (name, width) in Self.widths {
            for (label, position) in [("start", 0), ("midway", 150), ("end", 300)] {
                let radar = simulation()
                let engine = ReplayEngine(radar: radar, recording: coordinator)
                _ = try engine.load(sessionID)
                if position > 0 { try engine.run(to: position) }

                let transport = ReplayTransport(engine: engine)
                let bar = ReplayTransportBar(clock: engine.clock, transport: transport)
                    .padding(.horizontal, 24)
                    .frame(width: width)
                    // The bar is designed to sit over a radar; rendering it on white would flatter it.
                    .padding(.vertical, 26)
                    .background(Color(white: 0.16))

                try attach(bar, named: "transport-\(label)-\(name)")
            }
        }
    }

    // MARK: - Helpers

    private func simulation() -> MapViewModel {
        MapViewModel(spawner: AircraftSpawner(), feedback: SilentFeedback(), reports: SilentReports())
    }

    private static let exercisePayload = Data("""
    {
      "exerciseName": "Snapshot", "id": "snap-1",
      "gameEnd": { "time": 0 },
      "mapLocation": { "mapLatitude": 28.5562, "mapLongitude": 77.1000 },
      "runwaysResponse": [], "aircrafts": [], "airlines": [], "commands": [], "fixes": [], "zone": []
    }
    """.utf8)

    private func recordASession(ticks: Int) throws -> SessionID {
        let radar = simulation()
        radar.recording = coordinator
        radar.applyExercise(try JSONDecoder().decode(ExerciseDetail.self, from: Self.exercisePayload),
                            payload: Self.exercisePayload)
        radar.reset(seed: 0x5A_11)
        radar.stopSimulation()

        let sessionID = try XCTUnwrap(coordinator.sessions.active?.id)
        for tick in 1...ticks {
            if tick == 40, let target = radar.aircraft.min(by: { $0.id.uuidString < $1.id.uuidString }) {
                radar.selectAircraft(target.id)
                CommandKeyboardHandler(radar: radar).perform("C/M*", value: 260)
            }
            radar.advanceStep()
        }
        coordinator.stopRecording(tickCount: ticks)
        return sessionID
    }

    private func summary(label: String,
                        ticks: Int,
                        parent: SessionID? = nil,
                        forkTick: Int? = nil,
                        id: SessionID = SessionID(),
                        label2: String? = nil,
                        sessionClass: SessionClass = .training,
                        state: SessionState = .completed) -> SessionSummary {
        SessionSummary(id: id,
                       ownerID: .user("trainee-1"),
                       sessionClass: sessionClass,
                       state: state,
                       label: label2 ?? label,
                       parentID: parent,
                       forkTick: forkTick,
                       seed: 0x5A_11,
                       tickCount: ticks,
                       createdAt: Date(timeIntervalSince1970: 1_770_000_000),
                       exerciseName: label.isEmpty ? nil : label,
                       exerciseDigest: "sha256:0",
                       assignmentID: nil,
                       manifestVersion: 1,
                       buildVersion: "1.0",
                       architecture: RecordingEnvironment.currentArchitecture)
    }

    /// Renders and attaches. `.keepAlways` so the image survives a passing test — the whole point is to look at it.
    private func attach<V: View>(_ view: V, named name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "\(name) rendered nothing")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Also a file on disk. An attachment is the tidy answer; a PNG is the one that can actually be opened,
        // and exporting attachments out of a result bundle proved unreliable here. An image nobody can open
        // verifies nothing.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("replay-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try image.pngData()?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
