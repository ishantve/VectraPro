//
//  GridBotReferenceTest.swift
//  GridBotAdapterTests
//
//  The Reference Adapter Test (§8 of the boundary doc). A second, unrelated simulation driven end to end —
//  record → replay → seal → deterministic fingerprint — through ReplayCore's PUBLIC API only.
//
//  Note the imports: `ReplayCore` (not `@testable`) and `GridBotAdapter`. Nothing here reaches a core
//  internal. If it had to, the finding would be that ReplayCore is not yet usable by a second simulation.
//

import XCTest
import ReplayCore
import GridBotAdapter

final class GridBotReferenceTest: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GridBot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // A scripted session that exercises every tag, including two annotations a replay must skip.
    private func script() -> [Event] {
        func p(_ i: Int) -> EventPosition { EventPosition(tick: i, ordinal: UInt32(i)) }
        return [
            GridBotEvent.annotated(note: "mission start", at: p(0)),   // skipped by routing
            GridBotEvent.moved(steps: 3, at: p(1)),                    // (0,3) N
            GridBotEvent.turned(.right, at: p(2)),                     // heading E
            GridBotEvent.moved(steps: 2, at: p(3)),                    // (2,3)
            GridBotEvent.pickedUp(weight: 5, at: p(4)),                // cargo 5
            GridBotEvent.timeline(.paused, at: p(5)),                  // skipped by routing
            GridBotEvent.turned(.left, at: p(6)),                      // heading N
            GridBotEvent.moved(steps: 1, at: p(7)),                    // (2,4)
            GridBotEvent.pickedUp(at: p(8)),                           // cargo 6 (default weight 1)
        ]
    }

    private func store() -> EventStore {
        EventStore(url: directory.appendingPathComponent("events.log"),
                   sessionClass: .training, coding: GridBotCodec())
    }

    private func record(_ events: [Event], to store: EventStore) throws {
        try store.openForAppending()
        for event in events { try store.append(event) }
        try store.close()
    }

    /// Apply a session to a fresh world, routing by tag exactly as a replay does.
    private func world(replaying events: [Event]) -> GridWorld {
        let codec = GridBotCodec()
        var world = GridWorld()
        for event in events where codec.affectsSimulation(tag: event.tag) {
            if let payload = GridBotEvent.payload(of: event) { world.apply(payload) }
        }
        return world
    }

    // MARK: - Record → replay → fingerprint

    /// The core claim: a recording made by GridBot, read back through ReplayCore and re-applied, reconstructs
    /// the same world — bit for bit in the fingerprint.
    func testReplayReconstructsTheSameWorld() throws {
        let events = script()

        let recordWorld = world(replaying: events)             // apply live
        try record(events, to: store())
        let readBack = try store().readAll()
        let replayWorld = world(replaying: readBack)            // apply after a round trip

        XCTAssertEqual(readBack, events, "events did not survive the store round trip")
        XCTAssertEqual(replayWorld, recordWorld)
        XCTAssertEqual(replayWorld.fingerprint, recordWorld.fingerprint)

        // And it actually did something — not the empty-world fingerprint.
        XCTAssertEqual(replayWorld.x, 2)
        XCTAssertEqual(replayWorld.y, 4)
        XCTAssertEqual(replayWorld.heading, .north)
        XCTAssertEqual(replayWorld.cargoWeight, 6)
        XCTAssertEqual(replayWorld.moveCount, 3)
        XCTAssertNotEqual(replayWorld.fingerprint, GridWorld().fingerprint)
    }

    /// Routing by tag skips annotations and timeline actions — the same guarantee `affectsSimulation` gives ATC.
    func testAnnotationsAndTimelineDoNotAffectTheWorld() throws {
        let onlyAnnotations: [Event] = [
            GridBotEvent.annotated(note: "a", at: .init(tick: 0, ordinal: 0)),
            GridBotEvent.timeline(.speedChanged(to: 2), at: .init(tick: 1, ordinal: 1)),
        ]
        XCTAssertEqual(world(replaying: onlyAnnotations), GridWorld())
    }

    // MARK: - Seal

    /// The incremental seal written while recording matches a one-pass recompute on read, and a tampered log
    /// fails — the same property that makes an ATC assessment verifiable, proven for a different domain.
    func testSealMatchesAndDetectsTampering() throws {
        let manifest = Data(#"{"grid":"unbounded","seed":7}"#.utf8)
        let url = directory.appendingPathComponent("events.log")
        let recorder = SessionRecorder(
            sessionID: UUID(), sessionClass: .assessment, manifestBytes: manifest,
            store: EventStore(url: url, sessionClass: .assessment, coding: GridBotCodec()))
        recorder.now = { Date(timeIntervalSince1970: 1_700_000_000) }

        try recorder.open()
        for event in script() { recorder.record(event) }
        let sealed = try XCTUnwrap(recorder.finish())

        let log = try Data(contentsOf: url)
        XCTAssertEqual(sealed, SessionSeal.compute(manifest: manifest, log: log))
        XCTAssertTrue(SessionSeal.verify(sealed, manifest: manifest, log: log))

        var tampered = log
        tampered[tampered.count - 3] ^= 0x01
        XCTAssertFalse(SessionSeal.verify(sealed, manifest: manifest, log: tampered))
    }

    // MARK: - Golden corpus (byte-for-byte determinism of the on-disk format)

    /// The GridBot log is a committed artifact: the same script produces the same bytes today, and a
    /// decode → re-encode is byte-identical. If ReplayCore's framing changed under GridBot, this fails.
    func testLogIsByteForByteDeterministic() throws {
        func recordScript(to url: URL) throws -> Data {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let s = EventStore(url: url, sessionClass: .training, coding: GridBotCodec())
            try s.openForAppending()
            for event in script() { try s.append(event) }
            try s.close()
            return try Data(contentsOf: url)
        }

        let a = try recordScript(to: directory.appendingPathComponent("a/events.log"))
        let b = try recordScript(to: directory.appendingPathComponent("b/events.log"))
        XCTAssertEqual(a, b, "two identical scripts produced different bytes")

        // decode → re-encode must reproduce the same bytes exactly.
        let readBack = try EventStore(url: directory.appendingPathComponent("a/events.log"),
                                      sessionClass: .training, coding: GridBotCodec()).readAll()
        let urlC = directory.appendingPathComponent("c/events.log")
        try FileManager.default.createDirectory(at: urlC.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let sc = EventStore(url: urlC, sessionClass: .training, coding: GridBotCodec())
        try sc.openForAppending()
        for event in readBack { try sc.append(event) }
        try sc.close()
        XCTAssertEqual(try Data(contentsOf: urlC), a, "decode → re-encode was not byte-identical")

        // Committed golden. Filled in from the first green run; empty means "not captured yet".
        if !Self.goldenBase64.isEmpty {
            XCTAssertEqual(a, Data(base64Encoded: Self.goldenBase64), "log drifted from the committed golden")
        } else {
            print("GRIDBOT_GOLDEN_BASE64=\(a.base64EncodedString())")
        }
    }

    /// The committed golden log, base64. Captured from the first green run of the test above.
    static let goldenBase64 = "MUNUQXwAAAAlLTy5eyJldmVudFR5cGUiOjQsImV2ZW50VmVyc2lvbiI6MSwib3JkaW5hbCI6MCwicGF5bG9hZCI6eyJub3RlIjoibWlzc2lvbiBzdGFydCJ9LCJzY2hlbWFWZXJzaW9uIjoxLCJzb3VyY2UiOiJzeXN0ZW0iLCJ0aWNrIjowfTFDVEFvAAAAerxdnHsiZXZlbnRUeXBlIjoxLCJldmVudFZlcnNpb24iOjEsIm9yZGluYWwiOjEsInBheWxvYWQiOnsic3RlcHMiOjN9LCJzY2hlbWFWZXJzaW9uIjoxLCJzb3VyY2UiOiJzeXN0ZW0iLCJ0aWNrIjoxfTFDVEF5AAAA58ZUhnsiZXZlbnRUeXBlIjoyLCJldmVudFZlcnNpb24iOjEsIm9yZGluYWwiOjIsInBheWxvYWQiOnsiZGlyZWN0aW9uIjoicmlnaHQifSwic2NoZW1hVmVyc2lvbiI6MSwic291cmNlIjoic3lzdGVtIiwidGljayI6Mn0xQ1RBbwAAAJ3MoeJ7ImV2ZW50VHlwZSI6MSwiZXZlbnRWZXJzaW9uIjoxLCJvcmRpbmFsIjozLCJwYXlsb2FkIjp7InN0ZXBzIjoyfSwic2NoZW1hVmVyc2lvbiI6MSwic291cmNlIjoic3lzdGVtIiwidGljayI6M30xQ1RBcAAAAJ+gn1p7ImV2ZW50VHlwZSI6MywiZXZlbnRWZXJzaW9uIjoyLCJvcmRpbmFsIjo0LCJwYXlsb2FkIjp7IndlaWdodCI6NX0sInNjaGVtYVZlcnNpb24iOjEsInNvdXJjZSI6InN5c3RlbSIsInRpY2siOjR9MUNUQXwAAABWez6reyJldmVudFR5cGUiOjUsImV2ZW50VmVyc2lvbiI6MSwib3JkaW5hbCI6NSwicGF5bG9hZCI6eyJhY3Rpb24iOnsicGF1c2VkIjp7fX19LCJzY2hlbWFWZXJzaW9uIjoxLCJzb3VyY2UiOiJzeXN0ZW0iLCJ0aWNrIjo1fTFDVEF4AAAA2MOk0HsiZXZlbnRUeXBlIjoyLCJldmVudFZlcnNpb24iOjEsIm9yZGluYWwiOjYsInBheWxvYWQiOnsiZGlyZWN0aW9uIjoibGVmdCJ9LCJzY2hlbWFWZXJzaW9uIjoxLCJzb3VyY2UiOiJzeXN0ZW0iLCJ0aWNrIjo2fTFDVEFvAAAAj8HoInsiZXZlbnRUeXBlIjoxLCJldmVudFZlcnNpb24iOjEsIm9yZGluYWwiOjcsInBheWxvYWQiOnsic3RlcHMiOjF9LCJzY2hlbWFWZXJzaW9uIjoxLCJzb3VyY2UiOiJzeXN0ZW0iLCJ0aWNrIjo3fTFDVEFwAAAAlXKmGHsiZXZlbnRUeXBlIjozLCJldmVudFZlcnNpb24iOjIsIm9yZGluYWwiOjgsInBheWxvYWQiOnsid2VpZ2h0IjoxfSwic2NoZW1hVmVyc2lvbiI6MSwic291cmNlIjoic3lzdGVtIiwidGljayI6OH0="

    // MARK: - Payload migration (an adapter evolving a payload without a core release)

    /// Pickup grew a `weight` field in version 2. A version-1 object (no weight) is brought forward by the
    /// codec's migration and decodes as weight 1 — driven entirely through the public EventMigrator.
    func testPickupV1MigratesToV2() throws {
        let codec = GridBotCodec()
        XCTAssertEqual(codec.currentVersion(for: .gridPickup), 2)

        let migrator = EventMigrator(table: codec.migrations)
        let v1: [String: Any] = [:]                                  // pickup v1 carried no fields
        let v2 = try migrator.bringForward(v1, tag: .gridPickup, from: 1, to: 2)
        XCTAssertEqual(v2["weight"] as? Int, 1)

        let payload = try codec.decode(v2, tag: .gridPickup, version: 2)
        XCTAssertEqual(payload, .pickedUp(weight: 1))
    }
}
