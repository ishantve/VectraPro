//
//  SessionManagerTests.swift
//  ATCReplayKitTests
//
//  Lifecycle, recovery, retention, and forking.
//
//  These use a real temporary directory rather than a stub filesystem, because the behaviours worth
//  testing here are about files: a manifest that must exist the instant recording starts, a log
//  truncated by a killed process, a directory removed by retention.
//

import XCTest
@testable import ATCReplayKit

final class SessionManagerTests: XCTestCase {

    private var root: URL!
    private var catalogue: InMemorySessionCatalogue!
    private var manager: SessionManager!

    private let alice = OwnerID.user("alice")
    private let anonymous = OwnerID.device(UUID())
    private let environment = RecordingEnvironment(buildVersion: "1.2.3", platform: "iOS 26.3")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Sessions-\(UUID().uuidString)")
        catalogue = InMemorySessionCatalogue()
        manager = SessionManager(root: root, catalogue: catalogue, environment: environment)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func exercise(_ name: String = "Delhi approach") -> EmbeddedExercise {
        EmbeddedExercise(payload: Data(#"{"runways":[],"fixes":[]}"#.utf8),
                         exerciseID: "ex-1", exerciseName: name)
    }

    @discardableResult
    private func start(_ origin: SessionOrigin = .selfDirected,
                       owner: OwnerID? = nil,
                       seed: UInt64 = 0xABCD,
                       now: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> Session {
        try manager.start(origin: origin, seed: seed, owner: owner ?? alice,
                          exercise: exercise(), now: now)
    }

    // MARK: - Starting

    /// The manifest exists before `start` returns. A process that dies a second later must still leave
    /// a session anyone can identify — a directory with no manifest is an orphan nobody can interpret,
    /// because the seed is the root of the whole reconstruction.
    func testTheManifestIsOnDiskBeforeStartReturns() throws {
        let session = try start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.manifestURL(for: session.id).path))

        let manifest = try manager.manifest(for: session.id)
        XCTAssertEqual(manifest.seed, 0xABCD)
        XCTAssertEqual(manifest.ownerID, alice)
        XCTAssertEqual(manifest.environment.buildVersion, "1.2.3")
    }

    /// It is written twice on purpose. Losing a manifest is the only unrecoverable failure in the
    /// design, so a few hundred duplicated bytes is not a trade worth thinking about.
    func testTheManifestSurvivesLosingItsPrimaryCopy() throws {
        let session = try start()
        try FileManager.default.removeItem(at: manager.manifestURL(for: session.id))

        let recovered = try manager.manifest(for: session.id)
        XCTAssertEqual(recovered.seed, 0xABCD)
    }

    /// The exercise configuration is embedded, not referenced. A replay that re-fetched its
    /// configuration would be replaying a different world if the backend had since changed a fix.
    func testTheExercisePayloadIsStoredVerbatimAndVerifiable() throws {
        let session = try start()
        let manifest = try manager.manifest(for: session.id)

        XCTAssertEqual(manifest.exercise.payload, Data(#"{"runways":[],"fixes":[]}"#.utf8))
        XCTAssertTrue(manifest.payloadIsIntact)
    }

    func testStartingAppearsInTheOwnersList() throws {
        let session = try start()
        XCTAssertEqual(try catalogue.sessions(ownedBy: alice).map(\.id), [session.id])
    }

    func testOnlyOneSessionRecordsAtATime() throws {
        let first = try start()
        XCTAssertThrowsError(try start()) { error in
            XCTAssertEqual(error as? SessionManagerError, .alreadyRecording(first.id))
        }
    }

    /// An assessment needs somebody for the result to be about. A device identity is nobody.
    func testAnAssessmentRequiresAnAuthenticatedOwner() throws {
        let assignment = SessionOrigin.assignment(UUID(), assignedBy: "instructor-1")

        XCTAssertThrowsError(try start(assignment, owner: anonymous)) { error in
            XCTAssertEqual(error as? SessionManagerError, .assessmentRequiresAuthenticatedOwner)
        }
        // …and the same origin is fine for a signed-in trainee.
        XCTAssertNoThrow(try start(assignment, owner: alice))
    }

    /// Practising before signing in must still work, and be stored the same way.
    func testAnUnauthenticatedTraineeCanRecordTraining() throws {
        let session = try start(.selfDirected, owner: anonymous)
        XCTAssertEqual(session.sessionClass, .training)
        XCTAssertEqual(try catalogue.sessions(ownedBy: anonymous).count, 1)
    }

    // MARK: - Ending

    func testTrainingCompletes() throws {
        try start()
        let finished = try manager.end(tickCount: 2_400)

        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(try catalogue.summary(id: finished.id)?.tickCount, 2_400)
        XCTAssertNil(manager.active)
    }

    func testAnAssessmentSealsOnCompletion() throws {
        try start(.assignment(UUID(), assignedBy: "i1"))
        let finished = try manager.end(tickCount: 1_800, digest: "seal-abc")

        XCTAssertEqual(finished.state, .sealed(digest: "seal-abc"))
        XCTAssertTrue(finished.isScoreable)
    }

    /// An assessment that cannot be sealed must not be able to look complete.
    func testAnAssessmentCannotEndWithoutASeal() throws {
        try start(.assignment(UUID(), assignedBy: "i1"))
        XCTAssertThrowsError(try manager.end(tickCount: 100))
        XCTAssertNotNil(manager.active, "the session must stay open rather than half-ending")
    }

    func testEndingWithoutStartingIsRefused() throws {
        XCTAssertThrowsError(try manager.end(tickCount: 0)) { error in
            XCTAssertEqual(error as? SessionManagerError, .notRecording)
        }
    }

    func testAbandoningLeavesItInterrupted() throws {
        try start()
        let abandoned = try manager.abandon(tickCount: 42)
        XCTAssertEqual(abandoned.state, .interrupted)
        XCTAssertNil(manager.active)
    }

    // MARK: - Crash recovery

    /// The launch sweep: a session left `.recording` by a dead process is truncated to its last valid
    /// frame and marked interrupted.
    func testRecoveryTruncatesAndMarksAnInterruptedSession() throws {
        let session = try start()

        let store = EventStore(url: manager.eventLogURL(for: session.id), sessionClass: .training)
        try store.openForAppending()
        for tick in 1...5 {
            try store.append(Event(position: EventPosition(tick: tick, ordinal: UInt32(tick)),
                                   payload: .timelineAction(.paused)))
        }
        try store.close()

        // The process dies mid-write.
        let url = manager.eventLogURL(for: session.id)
        let data = try Data(contentsOf: url)
        try data.prefix(data.count - 15).write(to: url)

        // A fresh manager, as at the next launch.
        let next = SessionManager(root: root, catalogue: catalogue, environment: environment)
        let reports = try next.recoverInterrupted()

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.sessionID, session.id)
        XCTAssertGreaterThan(reports.first?.discardedBytes ?? 0, 0)
        XCTAssertEqual(reports.first?.recoveredEvents, 4)
        XCTAssertEqual(try catalogue.summary(id: session.id)?.state, .interrupted)
    }

    /// An interrupted **assessment** is flagged as incomplete, because it is not a valid assessment —
    /// still replayable and worth learning from, not worth grading.
    func testAnInterruptedAssessmentIsReportedAsIncomplete() throws {
        let session = try start(.assignment(UUID(), assignedBy: "i1"))

        let next = SessionManager(root: root, catalogue: catalogue, environment: environment)
        let reports = try next.recoverInterrupted()

        XCTAssertEqual(reports.first?.sessionClass, .assessment)
        XCTAssertTrue(reports.first?.isIncompleteAssessment ?? false)
        XCTAssertFalse(try XCTUnwrap(catalogue.summary(id: session.id)).isScoreable(on: environment))
    }

    func testRecoveryLeavesFinishedSessionsAlone() throws {
        try start()
        let finished = try manager.end(tickCount: 10)

        XCTAssertTrue(try manager.recoverInterrupted().isEmpty)
        XCTAssertEqual(try catalogue.summary(id: finished.id)?.state, .completed)
    }

    /// Recovery must not touch the session this process is recording right now — which happens when a
    /// previous crash is swept while a new exercise is already under way.
    func testRecoverySkipsTheActiveSession() throws {
        let session = try start()
        XCTAssertTrue(try manager.recoverInterrupted().isEmpty)
        XCTAssertEqual(manager.active?.id, session.id)
    }

    // MARK: - Retention

    /// Unlimited by default: nothing is removed until a policy says so.
    func testNothingIsEvictableByDefault() throws {
        for _ in 0..<5 {
            try start()
            _ = try manager.end(tickCount: 1)
        }
        XCTAssertTrue(try manager.evictable().isEmpty)
    }

    func testACountLimitEvictsTheOldest() throws {
        var ids: [SessionID] = []
        for day in 0..<5 {
            let session = try start(now: Date(timeIntervalSince1970: Double(day) * 86_400))
            _ = try manager.end(tickCount: 1)
            ids.append(session.id)
        }
        manager.retention = RetentionPolicy(maximumSessions: 3)

        let doomed = try manager.evictable().map(\.id)
        XCTAssertEqual(doomed, [ids[0], ids[1]], "the two oldest should go, in order")

        XCTAssertEqual(Set(try manager.applyRetention()), Set(doomed))
        XCTAssertEqual(try catalogue.allSessions().count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.directory(for: ids[0]).path))
    }

    func testAnAgeLimitEvictsOldSessions() throws {
        let old = try start(now: Date(timeIntervalSince1970: 0))
        _ = try manager.end(tickCount: 1)
        let fresh = try start(now: Date(timeIntervalSince1970: 1_000_000))
        _ = try manager.end(tickCount: 1)

        manager.retention = RetentionPolicy(maximumAge: 86_400)
        let doomed = try manager.evictable(now: Date(timeIntervalSince1970: 1_000_000)).map(\.id)

        XCTAssertEqual(doomed, [old.id])
        XCTAssertFalse(doomed.contains(fresh.id))
    }

    /// **Assessments are not swept by housekeeping.** Deleting a record about a person is an
    /// administrative act with its own audit trail, not something that happens because a device filled
    /// up.
    func testAssessmentsAreNotEvictedByDefault() throws {
        try start(.assignment(UUID(), assignedBy: "i1"), now: Date(timeIntervalSince1970: 0))
        _ = try manager.end(tickCount: 1, digest: "seal")

        manager.retention = RetentionPolicy(maximumSessions: 0, maximumAge: 1)
        XCTAssertTrue(try manager.evictable(now: Date(timeIntervalSince1970: 1_000_000)).isEmpty)

        // …unless a policy explicitly opts in.
        manager.retention = RetentionPolicy(maximumSessions: 0, evictsAssessments: true)
        XCTAssertEqual(try manager.evictable().count, 1)
    }

    /// A session still being written must never be evicted — the recorder would be writing into a
    /// directory that no longer exists.
    func testARecordingSessionIsNeverEvictable() throws {
        try start()
        manager.retention = RetentionPolicy(maximumSessions: 0, maximumAge: 0)
        XCTAssertTrue(try manager.evictable().isEmpty)
    }

    func testDeletingTheActiveSessionIsRefused() throws {
        let session = try start()
        XCTAssertThrowsError(try manager.delete(session.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.directory(for: session.id).path))
    }

    /// `evictable` never deletes; `applyRetention` does. So a UI can show what a policy would remove
    /// before it removes it.
    func testEvictableDoesNotDelete() throws {
        let session = try start()
        _ = try manager.end(tickCount: 1)
        manager.retention = RetentionPolicy(maximumSessions: 0)

        _ = try manager.evictable()
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.directory(for: session.id).path))
    }
}

// MARK: - Branching

final class BranchManagerTests: XCTestCase {

    private var root: URL!
    private var catalogue: InMemorySessionCatalogue!
    private var sessions: SessionManager!
    private var branches: BranchManager!

    private let alice = OwnerID.user("alice")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Branches-\(UUID().uuidString)")
        catalogue = InMemorySessionCatalogue()
        sessions = SessionManager(root: root, catalogue: catalogue,
                                 environment: RecordingEnvironment(buildVersion: "1",
                                                                   platform: "iOS 26.3"))
        branches = BranchManager(sessions: sessions)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func exercise() -> EmbeddedExercise {
        EmbeddedExercise(payload: Data("{}".utf8), exerciseName: "Delhi")
    }

    @discardableResult
    private func recordedSession(_ origin: SessionOrigin = .selfDirected,
                                 seed: UInt64 = 0xF00D,
                                 ticks: Int = 2_400) throws -> Session {
        let session = try sessions.start(origin: origin, seed: seed, owner: alice,
                                        exercise: exercise())
        return try sessions.end(tickCount: ticks,
                                digest: origin.sessionClass == .assessment ? "seal" : nil)
    }

    /// A branch inherits the world: same seed, same exercise, same owner. Its traffic continues rather
    /// than starting over.
    func testAForkInheritsTheSeedExerciseAndOwner() throws {
        let parent = try recordedSession(seed: 0xBEEF)
        let child = try branches.fork(parent.id, at: 900)

        XCTAssertEqual(child.seed, 0xBEEF)
        XCTAssertEqual(child.forkTick, 900)
        XCTAssertEqual(child.parentID, parent.id)

        let childManifest = try sessions.manifest(for: child.id)
        XCTAssertEqual(childManifest.exercise.digest, try sessions.manifest(for: parent.id).exercise.digest)
        XCTAssertEqual(childManifest.ownerID, alice)
    }

    /// **Forking an assessment yields training.** The exploration must never be able to pass for the
    /// assessment.
    func testForkingAnAssessmentYieldsTraining() throws {
        let assessed = try recordedSession(.assignment(UUID(), assignedBy: "i1"))
        let explored = try branches.fork(assessed.id, at: 600)

        XCTAssertEqual(explored.sessionClass, .training)
        XCTAssertNil(try sessions.manifest(for: explored.id).assignmentID)
    }

    /// The parent is marked superseded — **not truncated.** Comparing the first run against the second
    /// is the whole value of branching.
    func testTheParentIsSupersededButItsEventsAreKept() throws {
        let parent = try recordedSession(ticks: 2_400)

        let store = EventStore(url: sessions.eventLogURL(for: parent.id), sessionClass: .training)
        try store.openForAppending()
        for tick in [100, 900, 1_500] {
            try store.append(Event(position: EventPosition(tick: tick, ordinal: UInt32(tick)),
                                   payload: .timelineAction(.paused)))
        }
        try store.close()

        let child = try branches.fork(parent.id, at: 900)

        XCTAssertEqual(try catalogue.summary(id: parent.id)?.state,
                       .superseded(by: child.id, at: 900))
        XCTAssertEqual(try sessions.events(for: parent.id).map(\.tick), [100, 900, 1_500],
                       "the parent's future was deleted")
    }

    func testForkingBeyondTheParentIsRefused() throws {
        let parent = try recordedSession(ticks: 600)

        XCTAssertThrowsError(try branches.fork(parent.id, at: 900)) { error in
            XCTAssertEqual(error as? BranchError,
                           .forkTickBeyondParent(tick: 900, parentTicks: 600))
        }
        XCTAssertEqual(try catalogue.summary(id: parent.id)?.state, .completed,
                       "a refused fork must leave the parent untouched")
    }

    func testForkingAnUnknownParentIsRefused() throws {
        let absent = UUID()
        XCTAssertThrowsError(try branches.fork(absent, at: 10)) { error in
            XCTAssertEqual(error as? BranchError, .parentNotFound(absent))
        }
    }

    func testANegativeForkTickIsRefused() throws {
        let parent = try recordedSession()
        XCTAssertThrowsError(try branches.fork(parent.id, at: -1))
    }

    // MARK: Lineage

    func testDescendantsWalkTheWholeTree() throws {
        let root = try recordedSession()
        let a = try branches.fork(root.id, at: 300)
        _ = try sessions.end(tickCount: 1_000)
        let b = try branches.fork(a.id, at: 500)
        _ = try sessions.end(tickCount: 800)

        let found = try branches.descendants(of: root.id).map(\.id)
        XCTAssertEqual(Set(found), Set([a.id, b.id]))
        XCTAssertTrue(try branches.descendants(of: b.id).isEmpty)
    }

    func testLineageRunsFromTheRootDown() throws {
        let root = try recordedSession()
        let a = try branches.fork(root.id, at: 300)
        _ = try sessions.end(tickCount: 1_000)
        let b = try branches.fork(a.id, at: 500)

        XCTAssertEqual(try branches.lineage(of: b.id).map(\.id), [root.id, a.id, b.id])
        XCTAssertEqual(try branches.lineage(of: root.id).map(\.id), [root.id])
    }

    /// Two forks from one parent, which is the ordinary case when a trainee explores twice.
    func testAParentCanHaveSeveralChildren() throws {
        let parent = try recordedSession()
        let first = try branches.fork(parent.id, at: 300)
        _ = try sessions.end(tickCount: 400)
        let second = try branches.fork(parent.id, at: 900)

        XCTAssertEqual(Set(try catalogue.children(of: parent.id).map(\.id)),
                       Set([first.id, second.id]))
    }
}
