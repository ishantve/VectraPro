//
//  SessionCatalogueTests.swift
//  ATCReplayKitTests
//
//  One suite, run against **both** catalogue implementations.
//
//  There are two — an in-memory stand-in for tests and SQLite for the app — and two implementations of
//  the same interface diverge unless something holds them together. The queries and their *ordering*
//  are the contract, so the contract is written once and both are made to satisfy it. A subclass per
//  implementation is the cheapest way to do that in XCTest.
//

import XCTest
import ATCReplayKit
import ReplayPersistence

/// The contract. Subclasses supply the implementation.
class SessionCatalogueContractTests: XCTestCase {

    /// Nil in the abstract base, so it skips rather than running against nothing.
    var catalogue: SessionCatalogue!

    override func setUpWithError() throws {
        try XCTSkipIf(type(of: self) == SessionCatalogueContractTests.self,
                      "abstract contract — run by the subclasses")
    }

    // MARK: Fixtures

    private let alice = OwnerID.user("alice")
    private let bob = OwnerID.user("bob")

    private func summary(_ id: SessionID = UUID(),
                         owner: OwnerID? = nil,
                         sessionClass: SessionClass = .training,
                         state: SessionState = .recording,
                         parent: SessionID? = nil,
                         forkTick: Int? = nil,
                         seed: UInt64 = 42,
                         ticks: Int = 0,
                         createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                         origin: SessionSummary.StorageOrigin = .local) -> SessionSummary {
        SessionSummary(id: id,
                       ownerID: owner ?? alice,
                       sessionClass: sessionClass,
                       state: state,
                       label: "exercise",
                       parentID: parent,
                       forkTick: forkTick,
                       seed: seed,
                       tickCount: ticks,
                       createdAt: createdAt,
                       exerciseName: "Delhi approach",
                       exerciseDigest: "abc123",
                       assignmentID: nil,
                       manifestVersion: 1,
                       buildVersion: "1.0.0",
                       architecture: "arm64",
                       origin: origin)
    }

    // MARK: Round trip

    func testARowComesBackAsItWentIn() throws {
        let original = summary(seed: 0xDEAD_BEEF_CAFE_F00D, ticks: 1_234)
        try catalogue.upsert(original)
        XCTAssertEqual(try catalogue.summary(id: original.id), original)
    }

    /// A seed is unsigned 64-bit and SQLite integers are signed, so half the seed space would come
    /// back negative if it were stored as an integer. A seed that comes back wrong is a session that
    /// can never be replayed.
    func testASeedInTheTopHalfOfTheRangeSurvives() throws {
        let extreme = summary(seed: UInt64.max)
        try catalogue.upsert(extreme)
        XCTAssertEqual(try catalogue.summary(id: extreme.id)?.seed, UInt64.max)
    }

    /// Every state, including the two that carry data.
    func testEveryStateRoundTrips() throws {
        let child = UUID()
        let states: [SessionState] = [
            .recording, .completed, .interrupted,
            .sealed(digest: "d1e2f3"),
            .superseded(by: child, at: 900),
        ]
        for state in states {
            let row = summary(state: state)
            try catalogue.upsert(row)
            XCTAssertEqual(try catalogue.summary(id: row.id)?.state, state)
        }
    }

    func testBothOwnerKindsRoundTrip() throws {
        let device = OwnerID.device(UUID())
        for owner in [alice, device] {
            let row = summary(owner: owner)
            try catalogue.upsert(row)
            XCTAssertEqual(try catalogue.summary(id: row.id)?.ownerID, owner)
        }
    }

    func testAnUnknownIdIsNil() throws {
        XCTAssertNil(try catalogue.summary(id: UUID()))
    }

    // MARK: Updating

    func testUpsertUpdatesTheMutableFields() throws {
        var row = summary(state: .recording, ticks: 0)
        try catalogue.upsert(row)

        row = SessionSummary(id: row.id, ownerID: row.ownerID, sessionClass: row.sessionClass,
                             state: .completed, label: "renamed",
                             parentID: nil, forkTick: nil, seed: row.seed, tickCount: 2_400,
                             createdAt: row.createdAt, exerciseName: row.exerciseName,
                             exerciseDigest: row.exerciseDigest, assignmentID: nil,
                             manifestVersion: 1, buildVersion: "1.0.0", architecture: "arm64")
        try catalogue.upsert(row)

        let stored = try catalogue.summary(id: row.id)
        XCTAssertEqual(stored?.state, .completed)
        XCTAssertEqual(stored?.tickCount, 2_400)
        XCTAssertEqual(stored?.label, "renamed")
        XCTAssertEqual(try catalogue.allSessions().count, 1, "upsert inserted instead of updating")
    }

    /// The facts about a recording are fixed when it starts. An update must not be able to rewrite
    /// them, or a later write could quietly change which world a session was recorded in.
    func testAnUpdateCannotRewriteTheRecordingsFacts() throws {
        let row = summary(seed: 111, createdAt: Date(timeIntervalSince1970: 1_000))
        try catalogue.upsert(row)

        let tampered = SessionSummary(id: row.id, ownerID: row.ownerID,
                                      sessionClass: row.sessionClass, state: .completed,
                                      label: row.label, parentID: nil, forkTick: nil,
                                      seed: 999,
                                      tickCount: 10,
                                      createdAt: Date(timeIntervalSince1970: 9_999),
                                      exerciseName: "different",
                                      exerciseDigest: "zzz",
                                      assignmentID: nil, manifestVersion: 1,
                                      buildVersion: "9.9.9", architecture: "x86_64")
        try catalogue.upsert(tampered)

        let stored = try catalogue.summary(id: row.id)
        XCTAssertEqual(stored?.seed, 111, "the seed was rewritten")
        XCTAssertEqual(stored?.createdAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(stored?.exerciseDigest, "abc123")
        XCTAssertEqual(stored?.exerciseName, "Delhi approach")
        XCTAssertEqual(stored?.architecture, "arm64")
        XCTAssertEqual(stored?.buildVersion, "1.0.0")
        XCTAssertEqual(stored?.sessionClass, .training, "the class was rewritten")
        XCTAssertEqual(stored?.ownerID, alice, "the owner was rewritten — ownership never transfers")

        // …while the fields that legitimately change did.
        XCTAssertEqual(stored?.state, .completed)
        XCTAssertEqual(stored?.tickCount, 10)
    }

    // MARK: Lists

    func testOwnSessionsAreFilteredByOwnerAndNewestFirst() throws {
        let old = summary(owner: alice, createdAt: Date(timeIntervalSince1970: 1_000))
        let new = summary(owner: alice, createdAt: Date(timeIntervalSince1970: 2_000))
        let others = summary(owner: bob)
        for row in [old, new, others] { try catalogue.upsert(row) }

        XCTAssertEqual(try catalogue.sessions(ownedBy: alice).map(\.id), [new.id, old.id])
        XCTAssertEqual(try catalogue.sessions(ownedBy: bob).map(\.id), [others.id])
    }

    /// A trainee's own list must not include sessions that arrived from someone else, even if the
    /// owner matches — an instructor holding a copy of Alice's session should not see it under "mine".
    func testReceivedSessionsAreNotInTheOwnersOwnList() throws {
        let mine = summary(owner: alice, origin: .local)
        let theirs = summary(owner: alice, origin: .received)
        for row in [mine, theirs] { try catalogue.upsert(row) }

        XCTAssertEqual(try catalogue.sessions(ownedBy: alice).map(\.id), [mine.id])
        XCTAssertEqual(try catalogue.receivedSessions().map(\.id), [theirs.id])
    }

    /// Two sessions can share a timestamp — a fork is created in the same instant its parent is
    /// superseded — so the order must still be stable, or the same list comes back differently each
    /// call and a UI reorders under the user's finger.
    func testOrderingIsStableWhenTimestampsTie() throws {
        let shared = Date(timeIntervalSince1970: 5_000)
        let rows = (0..<5).map { _ in summary(createdAt: shared) }
        for row in rows { try catalogue.upsert(row) }

        let first = try catalogue.allSessions().map(\.id)
        let second = try catalogue.allSessions().map(\.id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 5)
    }

    // MARK: Lineage

    func testChildrenAreFoundByParent() throws {
        let parent = summary()
        let childA = summary(parent: parent.id, forkTick: 300,
                             createdAt: Date(timeIntervalSince1970: 1_100))
        let childB = summary(parent: parent.id, forkTick: 900,
                             createdAt: Date(timeIntervalSince1970: 1_200))
        let unrelated = summary()
        for row in [parent, childA, childB, unrelated] { try catalogue.upsert(row) }

        XCTAssertEqual(try catalogue.children(of: parent.id).map(\.id), [childB.id, childA.id])
        XCTAssertTrue(try catalogue.children(of: unrelated.id).isEmpty)
    }

    func testForkTickSurvives() throws {
        let child = summary(parent: UUID(), forkTick: 1_500)
        try catalogue.upsert(child)
        XCTAssertEqual(try catalogue.summary(id: child.id)?.forkTick, 1_500)
    }

    // MARK: Removal

    func testRemovingASession() throws {
        let row = summary()
        try catalogue.upsert(row)
        try catalogue.remove(id: row.id)
        XCTAssertNil(try catalogue.summary(id: row.id))
        XCTAssertTrue(try catalogue.allSessions().isEmpty)
    }

    func testRemovingSomethingAbsentIsNotAnError() throws {
        XCTAssertNoThrow(try catalogue.remove(id: UUID()))
    }
}

// MARK: - Implementations

final class InMemorySessionCatalogueTests: SessionCatalogueContractTests {
    override func setUpWithError() throws {
        catalogue = InMemorySessionCatalogue()
    }
}

final class SQLiteSessionCatalogueTests: SessionCatalogueContractTests {
    override func setUpWithError() throws {
        catalogue = try SQLiteSessionCatalogue(inMemory: true)
    }
}

// MARK: - SQLite specifics

final class SQLitePersistenceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Catalogue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The point of the file-backed version: the list survives the app being closed.
    func testRowsSurviveReopening() throws {
        let url = directory.appendingPathComponent("catalogue.sqlite")
        let id = UUID()

        do {
            let catalogue = try SQLiteSessionCatalogue(url: url)
            try catalogue.upsert(SessionSummary(
                id: id, ownerID: .user("alice"), sessionClass: .assessment,
                state: .sealed(digest: "seal-1"), label: "check ride",
                parentID: nil, forkTick: nil, seed: UInt64.max, tickCount: 2_400,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                exerciseName: "Delhi", exerciseDigest: "abc", assignmentID: UUID(),
                manifestVersion: 1, buildVersion: "1.0.0", architecture: "arm64"))
        }

        let reopened = try SQLiteSessionCatalogue(url: url)
        let stored = try reopened.summary(id: id)
        XCTAssertEqual(stored?.state, .sealed(digest: "seal-1"))
        XCTAssertEqual(stored?.seed, UInt64.max)
        XCTAssertEqual(stored?.sessionClass, .assessment)
        XCTAssertNotNil(stored?.assignmentID)
    }

    /// Opening the same path twice must not wipe it — `CREATE TABLE IF NOT EXISTS` is doing real work.
    func testOpeningAnExistingCatalogueDoesNotResetIt() throws {
        let url = directory.appendingPathComponent("catalogue.sqlite")
        let first = try SQLiteSessionCatalogue(url: url)
        try first.upsert(SessionSummary(
            id: UUID(), ownerID: .device(UUID()), sessionClass: .training, state: .completed,
            label: "", parentID: nil, forkTick: nil, seed: 1, tickCount: 0, createdAt: Date(),
            exerciseName: nil, exerciseDigest: "d", assignmentID: nil,
            manifestVersion: 1, buildVersion: "1", architecture: "arm64"))

        let second = try SQLiteSessionCatalogue(url: url)
        XCTAssertEqual(try second.allSessions().count, 1)
    }
}
