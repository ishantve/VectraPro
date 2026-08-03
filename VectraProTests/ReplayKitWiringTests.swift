//
//  ReplayKitWiringTests.swift
//  VectraProTests
//
//  Proves ATCReplayKit is reachable from the app and its test target, and that a session can be
//  recorded to the app's own container.
//
//  Phase A is otherwise invisible: nothing in the app calls it yet, and a package that builds in
//  isolation but is not actually linked would look identical until Phase B tried to use it.
//

import XCTest
import ATCReplayKit
import ATCReplayStore
@testable import VectraPro

final class ReplayKitWiringTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Wiring-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The whole Phase A stack, on the device's own storage: catalogue, manifest, event log.
    func testASessionCanBeRecordedInTheAppEnvironment() throws {
        let catalogue = try SQLiteSessionCatalogue(url: root.appendingPathComponent("catalogue.sqlite"))
        let manager = SessionManager(
            root: root,
            catalogue: catalogue,
            environment: RecordingEnvironment(buildVersion: Bundle.main.buildVersionForRecording,
                                              platform: RecordingEnvironment.currentPlatform))

        // The exercise payload as the app would embed it: the bytes the backend served.
        let payload = Data(#"{"exerciseName":"Delhi","runwaysResponse":[]}"#.utf8)
        let session = try manager.start(origin: .selfDirected,
                                        seed: 0xA11CE5,
                                        owner: .device(UUID()),
                                        exercise: EmbeddedExercise(payload: payload,
                                                                   exerciseName: "Delhi"))

        let store = EventStore(url: manager.eventLogURL(for: session.id), sessionClass: .training)
        try store.openForAppending()
        try store.append(Event(position: EventPosition(tick: 12, ordinal: 1),
                               payload: .commandIssued(code: "101", callsign: "AIC123",
                                                       slots: ["LEVEL": "260"])))
        try store.close()

        let finished = try manager.end(tickCount: 12)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(try manager.events(for: session.id).count, 1)
        XCTAssertEqual(try manager.manifest(for: session.id).exercise.payload, payload)
        XCTAssertEqual(try catalogue.allSessions().count, 1)
    }

    /// The environment the app reports must be usable — a blank build version or architecture would
    /// make every replay look unreproducible.
    func testTheAppReportsAUsableRecordingEnvironment() {
        let environment = RecordingEnvironment(buildVersion: Bundle.main.buildVersionForRecording,
                                              platform: RecordingEnvironment.currentPlatform)
        XCTAssertFalse(environment.buildVersion.isEmpty)
        XCTAssertFalse(environment.platform.isEmpty)
        XCTAssertNotEqual(environment.architecture, "unknown")
        XCTAssertTrue(environment.canReproduce(environment))
    }
}
