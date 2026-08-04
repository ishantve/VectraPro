//
//  EventSchemaTests.swift
//  ATCReplayKitTests
//
//  Whether a recording written by one release can be read by the next.
//
//  There is nothing to migrate yet, so the interesting tests use a **synthetic** step: a fabricated
//  older `commandIssued` that called the field `phraseologyCode`, and a migration that brings it
//  forward to today's `code`. That is the only way to prove the machinery works before it is needed —
//  and the point of building it now is that the first real field addition should be a registration
//  rather than a redesign.
//

import XCTest
@testable import ReplayCore

final class EventSchemaTests: XCTestCase {

    // MARK: - The envelope

    /// Every stored event carries all three numbers.
    func testEveryEventCarriesTheThreeVersions() throws {
        let coder = EventCoder()
        for payload in Self.oneOfEveryKind {
            let data = try coder.encode(Event(position: EventPosition(tick: 1, ordinal: 1),
                                              payload: payload))
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])

            XCTAssertEqual(object["schemaVersion"] as? Int, EventEnvelope.currentSchemaVersion)
            XCTAssertEqual(object["eventType"] as? Int, Int(payload.kind.rawValue))
            XCTAssertEqual(object["eventVersion"] as? Int, payload.kind.currentVersion)
        }
    }

    /// Ordering lives in the envelope, not the payload, so a log can be indexed and ordered without
    /// interpreting — or being able to interpret — payloads a newer build wrote.
    func testOrderingCanBeReadWithoutTouchingThePayload() throws {
        let coder = EventCoder()
        let data = try coder.encode(Event(position: EventPosition(tick: 1_234, ordinal: 99),
                                          payload: .timelineAction(.paused)))

        let envelope = try coder.decodeEnvelope(data)
        XCTAssertEqual(envelope.position, EventPosition(tick: 1_234, ordinal: 99))
        XCTAssertEqual(envelope.eventType, .timelineAction)
    }

    func testAnEnvelopeFromTheFutureIsRefusedRatherThanGuessedAt() throws {
        var object = try Self.encodedObject(.timelineAction(.paused))
        object["schemaVersion"] = EventEnvelope.currentSchemaVersion + 1
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try EventCoder().decode(data)) { error in
            XCTAssertEqual(error as? EventSchemaError,
                           .unsupportedSchema(found: EventEnvelope.currentSchemaVersion + 1,
                                              supported: EventEnvelope.currentSchemaVersion))
        }
    }

    /// A payload version this build has never seen cannot be read, because migrations only go forward.
    /// Saying so beats decoding it as though the extra fields were absent.
    func testAPayloadFromTheFutureIsRefused() throws {
        var object = try Self.encodedObject(.commandIssued(code: "101", callsign: "AIC1",
                                                           slots: [:]))
        object["eventVersion"] = 99
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try EventCoder().decode(data)) { error in
            guard case EventSchemaError.unsupportedEventVersion(let kind, 99, 1)? =
                    error as? EventSchemaError else {
                return XCTFail("expected unsupportedEventVersion, got \(error)")
            }
            XCTAssertEqual(kind, .commandIssued)
        }
    }

    /// Every kind is versioned separately, so bumping one cannot quietly bump the rest.
    func testEachKindHasItsOwnVersion() {
        for kind in EventKind.allCases {
            XCTAssertGreaterThanOrEqual(kind.currentVersion, 1, "\(kind) has no version")
        }
    }

    // MARK: - The manifest is versioned separately

    /// The manifest and the events change for unrelated reasons, so they carry unrelated numbers. A
    /// single shared version would make every field added to either look like a compatibility break in
    /// both.
    func testTheManifestVersionIsIndependentOfEventVersions() throws {
        let manifest = SessionManifest(
            sessionID: UUID(), origin: .selfDirected, seed: 1, ownerID: .user("a"),
            environment: RecordingEnvironment(buildVersion: "1", platform: "iOS"),
            exercise: EmbeddedExercise(payload: Data("{}".utf8)),
            createdAt: Date(timeIntervalSince1970: 0))

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try manifest.encoded()) as? [String: Any])
        XCTAssertEqual(object["manifestVersion"] as? Int, SessionManifest.currentVersion)

        // The environment describes what computed the recording, not a format version.
        let environment = try XCTUnwrap(object["environment"] as? [String: Any])
        XCTAssertNil(environment["schemaVersion"],
                     "a format version leaked back into the environment")
        XCTAssertNotNil(environment["architecture"])
    }

    func testAManifestFromTheFutureIsRefused() throws {
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try SessionManifest(
                sessionID: UUID(), origin: .selfDirected, seed: 1, ownerID: .user("a"),
                environment: RecordingEnvironment(buildVersion: "1", platform: "iOS"),
                exercise: EmbeddedExercise(payload: Data("{}".utf8)),
                createdAt: Date()).encoded()) as? [String: Any])
        object["manifestVersion"] = SessionManifest.currentVersion + 1

        XCTAssertThrowsError(
            try SessionManifest.decode(try JSONSerialization.data(withJSONObject: object))
        ) { error in
            XCTAssertEqual(error as? ManifestError,
                           .futureSchema(SessionManifest.currentVersion + 1))
        }
    }

    // MARK: - Migration, proved with a synthetic step

    /// Stands in for a future release that renamed `code` to `phraseologyCode`.
    ///
    /// A rename is the harshest realistic case: nothing in the old payload can be reused as-is, and a
    /// build without the migration would fail to decode entirely.
    private struct RenameCodeMigration: EventMigration {
        let eventType = EventKind.commandIssued
        // Reads version 0 and produces version 1 — the current one. Anchored at 0 rather than 1 because
        // `commandIssued` is only at version 1 today, so a step *into* the current version is the only
        // one that can actually run. When a real version 2 arrives this becomes `fromVersion = 1`.
        let fromVersion = 0

        func migrate(_ payload: [String: Any]) throws -> [String: Any] {
            var payload = payload
            payload["code"] = payload.removeValue(forKey: "phraseologyCode") ?? payload["code"]
            return payload
        }
    }

    /// A v1 payload, brought forward by a registered step.
    ///
    /// The chain runs on read. Nothing rewrites the stored bytes — which is what keeps a seal over them
    /// meaningful, and what makes migration safe to get wrong and fix later.
    func testAStoredPayloadIsBroughtForwardOnRead() throws {
        let migrator = EventMigrator([RenameCodeMigration()])
        // A payload as an older release would have written it.
        let stored: [String: Any] = ["phraseologyCode": "101", "callsign": "AIC123",
                                     "slots": ["LEVEL": "260"], "source": "voice"]

        let brought = try migrator.bringForward(stored, type: .commandIssued, from: 0)
        XCTAssertEqual(brought["code"] as? String, "101")
        XCTAssertNil(brought["phraseologyCode"], "the migration left the old field behind")
    }

    /// A gap in the chain is a specific, loud error rather than a silent partial migration.
    func testAMissingStepIsReportedRatherThanSkipped() {
        // Nothing registered, but the payload claims a version below current — only possible if
        // `currentVersion` was bumped without a migration being written.
        let migrator = EventMigrator()
        XCTAssertThrowsError(
            try migrator.bringForward([:], type: .commandIssued, from: 0)
        ) { error in
            XCTAssertEqual(error as? EventSchemaError, .missingMigration(.commandIssued, from: 0))
        }
    }

    /// The common case costs nothing: a payload already current is returned untouched.
    func testACurrentPayloadIsNotTouched() throws {
        let payload: [String: Any] = ["code": "101", "callsign": "AIC1"]
        let brought = try EventMigrator().bringForward(payload, type: .commandIssued, from: 1)
        XCTAssertEqual(brought["code"] as? String, "101")
        XCTAssertEqual(brought.count, payload.count)
    }

    /// `canRead` answers without attempting — so a session list can show "recorded by a newer version"
    /// without opening the log.
    func testCanReadAnswersWithoutDecoding() {
        let migrator = EventMigrator([RenameCodeMigration()])
        XCTAssertTrue(migrator.canRead(.commandIssued, version: 0), "the registered step should apply")
        XCTAssertTrue(migrator.canRead(.commandIssued, version: 1), "already current")
        XCTAssertFalse(migrator.canRead(.commandIssued, version: 2), "newer than this build")
        XCTAssertFalse(EventMigrator().canRead(.commandIssued, version: 0), "no step registered")
    }

    // MARK: - Determinism of the bytes

    /// The same event must always produce the same bytes: the seal is computed over them, so a digest
    /// that varied with dictionary order would be worthless.
    func testEncodingIsByteStable() throws {
        let coder = EventCoder()
        let event = Event(position: EventPosition(tick: 7, ordinal: 3),
                          payload: .commandIssued(code: "101", callsign: "AIC123",
                                                  slots: ["LEVEL": "260", "SPEED": "300"]),
                          wallClock: Date(timeIntervalSince1970: 1_700_000_000))

        let first = try coder.encode(event)
        for _ in 0..<20 {
            XCTAssertEqual(try coder.encode(event), first, "encoding is not deterministic")
        }
    }

    func testEveryKindStillRoundTripsThroughTheEnvelope() throws {
        let coder = EventCoder()
        for payload in Self.oneOfEveryKind {
            let event = Event(position: EventPosition(tick: 5, ordinal: 5), payload: payload)
            XCTAssertEqual(try coder.decode(try coder.encode(event)), event)
        }
    }

    // MARK: - Fixtures

    private static let oneOfEveryKind: [EventPayload] = [
        .commandIssued(code: "101", callsign: "AIC1", slots: ["LEVEL": "260"]),
        .commandRejected(code: "304", callsign: "AIC1", reason: "unmapped"),
        .transcriptReceived(raw: "air india 123 climb", normalized: "aic123 climb"),
        .readbackSpoken(callsign: "AIC1", spoken: "CLIMBING"),
        .weatherChanged(windDegrees: 270, windKnots: 12, visibilityMetres: 8_000, qnh: 1013),
        .scoreEvaluated(value: 82, rulesVersion: "v3"),
        .timelineAction(.speedChanged(to: 10)),
    ]

    private static func encodedObject(_ payload: EventPayload) throws -> [String: Any] {
        let data = try EventCoder().encode(Event(position: EventPosition(tick: 1, ordinal: 1),
                                                payload: payload))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
