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
import ATCReplayAdapter
@testable import ReplayCore

final class EventSchemaTests: XCTestCase {

    // MARK: - The envelope

    /// Every stored event carries all three numbers.
    func testEveryEventCarriesTheThreeVersions() throws {
        let coder = EventCoder(coding: ATCEventCodec())
        for event in Self.oneOfEveryKind {
            let data = try coder.encode(event)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: data) as? [String: Any])

            XCTAssertEqual(object["schemaVersion"] as? Int, EventEnvelope.currentSchemaVersion)
            XCTAssertEqual(object["eventType"] as? Int, Int(event.tag.rawValue))
            XCTAssertEqual(object["eventVersion"] as? Int,
                           ATCEventCodec().currentVersion(for: event.tag))
        }
    }

    /// Ordering lives in the envelope, not the payload, so a log can be indexed and ordered without
    /// interpreting — or being able to interpret — payloads a newer build wrote.
    func testOrderingCanBeReadWithoutTouchingThePayload() throws {
        let coder = EventCoder(coding: ATCEventCodec())
        let data = try coder.encode(ATCEvent.timeline(.paused,
                                                     at: EventPosition(tick: 1_234, ordinal: 99)))

        let envelope = try coder.decodeEnvelope(data)
        XCTAssertEqual(envelope.position, EventPosition(tick: 1_234, ordinal: 99))
        XCTAssertEqual(envelope.eventType, .timelineAction)
    }

    /// A wire tag this build has never heard of costs its payload and nothing else.
    ///
    /// The property R2b-atomic made possible and the reason `EventTypeTag` is a struct: when the tag was an
    /// enum, an unrecognised number failed the *envelope* decode, so one event of a kind added by a newer
    /// release made the surrounding ordering, attribution and tracing unreadable too. Now the envelope decodes,
    /// the event can still be indexed and counted, and only the payload is beyond this build.
    func testAnUnknownTagStillLeavesTheEnvelopeReadable() throws {
        let coder = EventCoder(coding: ATCEventCodec())
        var object = try Self.encodedObject(
            ATCEvent.commandIssued(code: "101", callsign: "AIC1", slots: [:],
                                   at: EventPosition(tick: 77, ordinal: 9),
                                   source: .keypad))
        // A kind from a release that does not exist yet.
        object["eventType"] = 9_999
        let data = try JSONSerialization.data(withJSONObject: object)

        let envelope = try coder.decodeEnvelope(data)
        XCTAssertEqual(envelope.position, EventPosition(tick: 77, ordinal: 9))
        XCTAssertEqual(envelope.source, .keypad)
        XCTAssertEqual(envelope.eventType, EventTypeTag(9_999),
                       "an unknown tag must survive intact rather than being mapped onto a known one")

        XCTAssertThrowsError(try coder.decode(data),
                             "the payload is not readable and saying so beats guessing at it")
    }

    func testAnEnvelopeFromTheFutureIsRefusedRatherThanGuessedAt() throws {
        var object = try Self.encodedObject(
            ATCEvent.timeline(.paused, at: EventPosition(tick: 1, ordinal: 1)))
        object["schemaVersion"] = EventEnvelope.currentSchemaVersion + 1
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try EventCoder(coding: ATCEventCodec()).decode(data)) { error in
            XCTAssertEqual(error as? EventSchemaError,
                           .unsupportedSchema(found: EventEnvelope.currentSchemaVersion + 1,
                                              supported: EventEnvelope.currentSchemaVersion))
        }
    }

    /// A payload version this build has never seen cannot be read, because migrations only go forward.
    /// Saying so beats decoding it as though the extra fields were absent.
    func testAPayloadFromTheFutureIsRefused() throws {
        var object = try Self.encodedObject(
            ATCEvent.commandIssued(code: "101", callsign: "AIC1", slots: [:],
                                   at: EventPosition(tick: 1, ordinal: 1)))
        object["eventVersion"] = 99
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try EventCoder(coding: ATCEventCodec()).decode(data)) { error in
            guard case EventSchemaError.unsupportedEventVersion(let kind, 99, 1)? =
                    error as? EventSchemaError else {
                return XCTFail("expected unsupportedEventVersion, got \(error)")
            }
            XCTAssertEqual(kind, .commandIssued)
        }
    }

    /// Every kind is versioned separately, so bumping one cannot quietly bump the rest.
    ///
    /// Asked of the **codec**, not of the core: the roster of a domain's event kinds and the version each is
    /// written at are the adapter's, and the core migrates to the number it is handed.
    func testEachKindHasItsOwnVersion() {
        let codec = ATCEventCodec()
        for tag in ATCEventCodec.allTags {
            XCTAssertGreaterThanOrEqual(codec.currentVersion(for: tag), 1, "\(tag) has no version")
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
        let tag = EventTypeTag.commandIssued
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

        let brought = try migrator.bringForward(stored, tag: .commandIssued, from: 0, to: 1)
        XCTAssertEqual(brought["code"] as? String, "101")
        XCTAssertNil(brought["phraseologyCode"], "the migration left the old field behind")
    }

    /// A gap in the chain is a specific, loud error rather than a silent partial migration.
    func testAMissingStepIsReportedRatherThanSkipped() {
        // Nothing registered, but the payload claims a version below current — only possible if
        // `currentVersion` was bumped without a migration being written.
        let migrator = EventMigrator()
        XCTAssertThrowsError(
            try migrator.bringForward([:], tag: .commandIssued, from: 0, to: 1)
        ) { error in
            XCTAssertEqual(error as? EventSchemaError, .missingMigration(.commandIssued, from: 0))
        }
    }

    /// The common case costs nothing: a payload already current is returned untouched.
    func testACurrentPayloadIsNotTouched() throws {
        let payload: [String: Any] = ["code": "101", "callsign": "AIC1"]
        let brought = try EventMigrator().bringForward(payload, tag: .commandIssued, from: 1, to: 1)
        XCTAssertEqual(brought["code"] as? String, "101")
        XCTAssertEqual(brought.count, payload.count)
    }

    /// `canRead` answers without attempting — so a session list can show "recorded by a newer version"
    /// without opening the log.
    func testCanReadAnswersWithoutDecoding() {
        let migrator = EventMigrator([RenameCodeMigration()])
        XCTAssertTrue(migrator.canRead(.commandIssued, version: 0, target: 1),
                      "the registered step should apply")
        XCTAssertTrue(migrator.canRead(.commandIssued, version: 1, target: 1), "already current")
        XCTAssertFalse(migrator.canRead(.commandIssued, version: 2, target: 1), "newer than this build")
        XCTAssertFalse(EventMigrator().canRead(.commandIssued, version: 0, target: 1),
                       "no step registered")
    }

    // MARK: - Determinism of the bytes

    /// The same event must always produce the same bytes: the seal is computed over them, so a digest
    /// that varied with dictionary order would be worthless.
    func testEncodingIsByteStable() throws {
        let coder = EventCoder(coding: ATCEventCodec())
        let event = ATCEvent.commandIssued(code: "101", callsign: "AIC123",
                                           slots: ["LEVEL": "260", "SPEED": "300"],
                                           at: EventPosition(tick: 7, ordinal: 3),
                                           wallClock: Date(timeIntervalSince1970: 1_700_000_000))

        let first = try coder.encode(event)
        for _ in 0..<20 {
            XCTAssertEqual(try coder.encode(event), first, "encoding is not deterministic")
        }
    }

    func testEveryKindStillRoundTripsThroughTheEnvelope() throws {
        let coder = EventCoder(coding: ATCEventCodec())
        for event in Self.oneOfEveryKind {
            XCTAssertEqual(try coder.decode(try coder.encode(event)), event)
        }
    }

    // MARK: - Fixtures

    /// One event of every kind, each at its own position.
    ///
    /// Events rather than payloads: these tests assert envelope properties, and an envelope needs a position.
    private static let oneOfEveryKind: [Event] = {
        func p(_ i: Int) -> EventPosition { EventPosition(tick: i, ordinal: UInt32(i)) }
        return [
            ATCEvent.commandIssued(code: "101", callsign: "AIC1", slots: ["LEVEL": "260"], at: p(0)),
            ATCEvent.commandRejected(code: "304", callsign: "AIC1", reason: "unmapped", at: p(1)),
            ATCEvent.transcriptReceived(raw: "air india 123 climb", normalized: "aic123 climb", at: p(2)),
            ATCEvent.readbackSpoken(callsign: "AIC1", spoken: "CLIMBING", at: p(3)),
            ATCEvent.weatherChanged(windDegrees: 270, windKnots: 12, visibilityMetres: 8_000, qnh: 1013,
                                    at: p(4)),
            ATCEvent.scoreEvaluated(value: 82, rulesVersion: "v3", at: p(5)),
            ATCEvent.timeline(.speedChanged(to: 10), at: p(6)),
        ]
    }()

    /// One event, encoded, as a mutable object — so a test can corrupt a single envelope field.
    ///
    /// Takes an `Event` rather than a payload, because a payload is the adapter's to build and `ATCEvent` is
    /// how it is built. There is no longer any way to hand a bare payload to the core, which is the point.
    private static func encodedObject(_ event: Event) throws -> [String: Any] {
        let data = try EventCoder(coding: ATCEventCodec()).encode(event)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
