//
//  SessionCoordinatorDeleteTests.swift
//  VectraProTests
//
//  Deleting a recording removes both its on-disk files and its catalogue row, through the existing
//  SessionManager.delete path; an actively-recording session refuses to delete.
//

import XCTest
import ATCReplayKit
@testable import VectraPro

@MainActor
final class SessionCoordinatorDeleteTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Delete-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func coordinator() -> SessionCoordinator {
        SessionCoordinator(root: root,
                           environment: RecordingEnvironment(buildVersion: "1.0.0", architecture: "arm64",
                                                             platform: "test"))
    }

    private func startFinished(_ c: SessionCoordinator, name: String = "T") throws -> SessionID {
        let s = try c.sessions.start(origin: .selfDirected, seed: 1, owner: .user("t"),
                                     exercise: EmbeddedExercise(payload: Data("{}".utf8), exerciseName: name))
        _ = try c.sessions.end(tickCount: 0)
        return s.id
    }

    func testDeleteRemovesCatalogueRowAndOnDiskFiles() throws {
        let c = coordinator()
        let id = try startFinished(c)
        let dir = c.sessions.directory(for: id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "session dir should exist before delete")
        XCTAssertNotNil(try c.sessions.catalogue.summary(id: id), "catalogue row should exist before delete")

        try c.delete(id)

        XCTAssertNil(try c.sessions.catalogue.summary(id: id), "catalogue row should be gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "on-disk files should be gone")
        XCTAssertTrue(try c.sessions.catalogue.allSessions().isEmpty)
    }

    func testDeleteLeavesOtherRecordingsUntouched() throws {
        let c = coordinator()
        let keep = try startFinished(c, name: "Keep")
        let drop = try startFinished(c, name: "Drop")

        try c.delete(drop)

        XCTAssertNil(try c.sessions.catalogue.summary(id: drop))
        XCTAssertNotNil(try c.sessions.catalogue.summary(id: keep), "unrelated recording must survive")
        XCTAssertEqual(try c.sessions.catalogue.allSessions().count, 1)
    }

    func testDeletingAnActivelyRecordingSessionThrowsAndKeepsIt() throws {
        let c = coordinator()
        // Started but not ended → active/recording.
        let s = try c.sessions.start(origin: .selfDirected, seed: 1, owner: .user("t"),
                                     exercise: EmbeddedExercise(payload: Data("{}".utf8), exerciseName: "Live"))

        XCTAssertThrowsError(try c.delete(s.id), "an actively-recording session must not delete")
        XCTAssertNotNil(try c.sessions.catalogue.summary(id: s.id), "the refused delete must leave it in place")
    }
}
