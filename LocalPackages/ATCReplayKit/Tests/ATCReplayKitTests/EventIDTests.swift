//
//  EventIDTests.swift
//  ATCReplayKitTests
//
//  The properties an annotation depends on: the same event always has the same id, different events
//  never do, and the id survives everything about the event except its position in its session.
//

import XCTest
@testable import ATCReplayKit

final class EventIDTests: XCTestCase {

    private let session = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let other = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

    // MARK: - Stability

    /// **The property everything else rests on.** Two devices holding copies of the same session must
    /// agree about which event an annotation points at, without exchanging anything but the session id.
    func testTheSameSessionAndOrdinalAlwaysGiveTheSameID() {
        for ordinal in UInt32(0)..<50 {
            XCTAssertEqual(EventID(session: session, ordinal: ordinal),
                           EventID(session: session, ordinal: ordinal))
        }
    }

    /// A hard-coded value, because "deterministic" has to mean *this* value and not merely "the same
    /// within one run". If the derivation ever changes, every stored annotation is orphaned — so a
    /// change here must be a decision, and this is what makes it one.
    func testTheDerivationIsPinned() {
        XCTAssertEqual(EventID(session: session, ordinal: 1).description,
                       "7CBAC22A-FB27-8764-B9C7-AF81A15A84E5")
    }

    // MARK: - Uniqueness

    func testEveryOrdinalInASessionGetsADistinctID() {
        let ids = (UInt32(0)..<5_000).map { EventID(session: session, ordinal: $0) }
        XCTAssertEqual(Set(ids).count, 5_000)
    }

    /// Two sessions can only collide if their session ids did.
    func testTheSameOrdinalInDifferentSessionsDiffers() {
        XCTAssertNotEqual(EventID(session: session, ordinal: 7),
                          EventID(session: other, ordinal: 7))
    }

    /// Adjacent ordinals must not produce adjacent ids — the whole point of hashing rather than
    /// formatting is that nothing can infer order from an id.
    func testAdjacentOrdinalsAreNotAdjacentIDs() {
        let first = EventID(session: session, ordinal: 100).description
        let second = EventID(session: session, ordinal: 101).description
        // Not merely different: they should share no leading structure a reader could sort on.
        XCTAssertNotEqual(first.prefix(8), second.prefix(8))
    }

    // MARK: - Independence from everything mutable

    /// **Identity survives migration.** A payload changing shape on read must not move the id, or every
    /// annotation pointing at that event is silently orphaned the day a migration lands.
    func testTheIDDoesNotDependOnThePayload() {
        let position = EventPosition(tick: 42, ordinal: 9)
        let payloads: [EventPayload] = [
            .commandIssued(code: "101", callsign: "AIC1", slots: ["LEVEL": "260"]),
            .timelineAction(.paused),
            .scoreEvaluated(value: 82, rulesVersion: "v3"),
        ]
        let ids = payloads.map { Event(position: position, payload: $0).id(in: session) }
        XCTAssertEqual(Set(ids).count, 1, "the id moved with the payload")
    }

    /// `tick` is not part of identity, so a repaired or re-based recording keeps its anchors.
    func testTheIDDoesNotDependOnTheTick() {
        let a = Event(position: EventPosition(tick: 10, ordinal: 5),
                      payload: .timelineAction(.paused)).id(in: session)
        let b = Event(position: EventPosition(tick: 9_999, ordinal: 5),
                      payload: .timelineAction(.paused)).id(in: session)
        XCTAssertEqual(a, b)
    }

    /// Wall-clock time is audit data and must not reach identity — two runs of the same session would
    /// otherwise produce different ids for the same event.
    func testTheIDDoesNotDependOnWallClock() {
        let position = EventPosition(tick: 1, ordinal: 1)
        let stamped = Event(position: position, payload: .timelineAction(.paused),
                            wallClock: Date(timeIntervalSince1970: 1_700_000_000))
        let bare = Event(position: position, payload: .timelineAction(.paused))
        XCTAssertEqual(stamped.id(in: session), bare.id(in: session))
    }

    // MARK: - Available without decoding

    /// An envelope can name its event without the payload being decodable — so an index or a sync
    /// manifest can cover a log written by a newer build.
    func testAnEnvelopeCanNameItsEventWithoutThePayload() throws {
        let event = Event(position: EventPosition(tick: 3, ordinal: 11),
                          payload: .commandIssued(code: "101", callsign: "AIC1",
                                                  slots: [:]))
        let coder = EventCoder()
        let envelope = try coder.decodeEnvelope(try coder.encode(event))

        XCTAssertEqual(envelope.id(in: session), event.id(in: session))
    }

    // MARK: - Shape

    /// A well-formed UUID version 8 — RFC 9562's "custom" form. v8 rather than v4 (this is not random)
    /// or v5 (that is specified as SHA-1); the honest label, and one any UUID parser accepts.
    func testTheIDIsAWellFormedVersion8UUID() {
        let uuid = EventID(session: session, ordinal: 1).value
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }

        XCTAssertEqual(bytes[6] >> 4, 0x8, "version nibble is not 8")
        XCTAssertEqual(bytes[8] >> 6, 0b10, "variant bits are not RFC 4122")
        XCTAssertNotNil(UUID(uuidString: uuid.uuidString))
    }

    /// Round-trips through storage, since it will live in an annotations table and in sync payloads.
    func testTheIDRoundTripsThroughCoding() throws {
        let original = EventID(session: session, ordinal: 12_345)
        let decoded = try JSONDecoder().decode(EventID.self,
                                               from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(EventID(value: original.value), original)
    }

    // MARK: - The requirement this scheme creates

    /// Uniqueness rests on `ordinal` never repeating in a session. So when recording resumes on an
    /// existing log — after a crash — the counter has to continue from where the log left off. This is a
    /// reminder in test form: if the counter restarted, two events would share an id.
    func testResumingFromAnExistingLogMustNotRestartOrdinals() {
        let beforeCrash = EventID(session: session, ordinal: 5)
        let ifCounterRestarted = EventID(session: session, ordinal: 5)
        XCTAssertEqual(beforeCrash, ifCounterRestarted,
                       """
                       Identical, which is the hazard: a restarted counter mints an id that already \
                       exists. InputGateway must seed its ordinal from EventStore.lastPosition.
                       """)
    }
}
