//
//  SessionTests.swift
//  ATCReplayKitTests
//
//  Most of these pin one decision: **a session's class comes from its origin, never from a choice.**
//
//  If a trainee could declare a session an assessment, they could also decline to share a bad one,
//  and an instructor's list would be a self-selected portfolio rather than a record. So an assessment
//  comes from an instructor's assignment, and everything else is training — including a fork of an
//  assessment, so that exploring "what if I had turned him earlier" can never produce a second thing
//  that looks like the assessment.
//

import XCTest
@testable import ReplayCore

final class SessionTests: XCTestCase {

    private func session(_ origin: SessionOrigin, seed: UInt64 = 42) -> Session {
        Session(origin: origin, seed: seed, ownerID: "trainee-1")
    }

    // MARK: - Class comes from origin

    /// The property the whole assessment design rests on.
    func testClassIsDerivedFromOriginForEveryOrigin() {
        let cases: [(SessionOrigin, SessionClass)] = [
            (.selfDirected, .training),
            (.assignment(UUID(), assignedBy: "instructor-1"), .assessment),
            (.fork(from: UUID(), at: 900), .training),
        ]
        for (origin, expected) in cases {
            XCTAssertEqual(origin.sessionClass, expected)
            XCTAssertEqual(session(origin).sessionClass, expected,
                           "the stored class disagreed with the origin")
        }
    }

    /// A trainee starting a session on their own can never produce an assessment.
    func testSelfDirectedIsAlwaysTraining() {
        XCTAssertEqual(session(.selfDirected).sessionClass, .training)
        XCTAssertNil(session(.selfDirected).assignmentID)
        XCTAssertFalse(session(.selfDirected).isImplicitlyShared)
    }

    /// An assignment is what makes a session an assessment — and what makes its share implicit, so
    /// there was never a withhold decision to make.
    func testAnAssignedSessionIsAnAssessmentAndSharedWithoutAsking() {
        let assignment = UUID()
        let assessed = session(.assignment(assignment, assignedBy: "instructor-1"))

        XCTAssertEqual(assessed.sessionClass, .assessment)
        XCTAssertEqual(assessed.assignmentID, assignment)
        XCTAssertTrue(assessed.isImplicitlyShared)
    }

    /// **Forking an assessment produces training.** A trainee replaying their assessment and pressing
    /// continue is genuinely useful; it must not be able to make a second assessment.
    func testForkingAnAssessmentProducesATrainingSession() {
        let assessed = session(.assignment(UUID(), assignedBy: "instructor-1"))
        let explored = assessed.forking(at: 900)

        XCTAssertEqual(explored.sessionClass, .training)
        XCTAssertNil(explored.assignmentID)
        XCTAssertFalse(explored.isImplicitlyShared)
        XCTAssertEqual(explored.parentID, assessed.id)
        XCTAssertEqual(explored.forkTick, 900)
    }

    // MARK: - Class drives policy

    /// The policies are read off the class rather than decided at each call site, so there is one
    /// place to look and one place to change.
    func testTheClassCarriesItsPolicies() {
        XCTAssertTrue(SessionClass.assessment.flushesEveryEvent)
        XCTAssertTrue(SessionClass.assessment.isSealedOnCompletion)
        XCTAssertTrue(SessionClass.assessment.recordedScoreIsAuthoritative)

        XCTAssertFalse(SessionClass.training.flushesEveryEvent)
        XCTAssertFalse(SessionClass.training.isSealedOnCompletion)
        XCTAssertFalse(SessionClass.training.recordedScoreIsAuthoritative)
    }

    // MARK: - Lineage

    /// A branch inherits the seed, so its traffic continues the same world rather than starting a
    /// different one at the fork point.
    func testAForkInheritsTheSeedAndTheOwner() {
        let parent = session(.selfDirected, seed: 0xABCD)
        let child = parent.forking(at: 120)

        XCTAssertEqual(child.seed, 0xABCD)
        XCTAssertEqual(child.ownerID, parent.ownerID)
        XCTAssertEqual(child.tickCount, 120, "a fork starts where it diverged, not at zero")
    }

    func testARootHasNoParent() {
        XCTAssertTrue(session(.selfDirected).isRoot)
        XCTAssertFalse(session(.fork(from: UUID(), at: 10)).isRoot)
    }

    /// Superseding marks a session as no longer the active line. It does **not** delete the events
    /// after the fork: comparing what the trainee did the first time against the second is the whole
    /// value of branching.
    func testSupersedingRecordsTheForkWithoutEndingTheSession() throws {
        let parent = try session(.selfDirected).finished()
        let child = parent.forking(at: 600)
        let superseded = try parent.superseded(by: child.id, at: 600)

        XCTAssertEqual(superseded.state, .superseded(by: child.id, at: 600))
        XCTAssertEqual(superseded.id, parent.id, "superseding must not change identity")
    }

    // MARK: - Finishing

    func testTrainingCompletesWithoutASeal() throws {
        XCTAssertEqual(try session(.selfDirected).finished().state, .completed)
    }

    /// An assessment must be sealed to finish. Refusing the transition is how the type prevents an
    /// unsealed assessment ever looking complete.
    func testAnAssessmentCannotCompleteWithoutASeal() throws {
        let assessed = session(.assignment(UUID(), assignedBy: "i1"))
        XCTAssertThrowsError(try assessed.finished()) { error in
            XCTAssertEqual(error as? SessionStateError, .sealRequired)
        }
        XCTAssertEqual(try assessed.finished(digest: "abc123").state, .sealed(digest: "abc123"))
    }

    /// Finishing twice is a plausible thing for a UI to do, and should be a no-op rather than a crash.
    /// Throws naming both states rather than trapping or silently no-op'ing — a UI can plausibly try twice,
    /// and a skipped transition is the failure the machine exists to prevent.
    func testFinishingAnAlreadyFinishedSessionThrowsNamingBothStates() throws {
        let finished = try session(.selfDirected).finished()
        XCTAssertThrowsError(try finished.finished()) { error in
            XCTAssertEqual(error as? SessionStateError,
                           .illegalTransition(from: "completed", to: "stopping"))
        }
    }

    func testAnInterruptedSessionCanOnlyComeFromRecording() throws {
        XCTAssertEqual(session(.selfDirected).interrupted().state, .interrupted)

        let completed = try session(.selfDirected).finished()
        XCTAssertEqual(completed.interrupted().state, .completed,
                       "a finished session must not be reopened as interrupted")
    }

    // MARK: - Scoreability

    /// **An unsealed assessment is not a valid assessment.** It stays replayable and worth learning
    /// from; it is not worth grading, and saying so honestly matters more than salvaging the result.
    func testAnInterruptedAssessmentIsNotScoreable() {
        let crashed = session(.assignment(UUID(), assignedBy: "i1")).interrupted()
        XCTAssertEqual(crashed.state, .interrupted)
        XCTAssertFalse(crashed.isScoreable)
    }

    func testASealedAssessmentIsScoreable() throws {
        let sealed = try session(.assignment(UUID(), assignedBy: "i1")).finished(digest: "abc")
        XCTAssertTrue(sealed.isScoreable)
    }

    /// A session still being recorded has no result yet.
    func testARecordingSessionIsNotScoreable() {
        XCTAssertFalse(session(.selfDirected).isScoreable)
        XCTAssertFalse(session(.assignment(UUID(), assignedBy: "i1")).isScoreable)
    }

    func testASupersededSessionIsNotScoreable() throws {
        let finished = try session(.selfDirected).finished()
        XCTAssertFalse(try finished.superseded(by: UUID(), at: 10).isScoreable)
    }

    func testACompletedTrainingSessionIsScoreable() throws {
        XCTAssertTrue(try session(.selfDirected).finished().isScoreable)
    }
}
