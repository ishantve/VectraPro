//
//  EventTracingTests.swift
//  ATCReplayKitTests
//
//  `correlationID` and `causationID` are reserved, not yet populated. These tests exist so that
//  "optional and additive" is a demonstrated property rather than a claim — the alternative being to
//  discover in Phase C that the fields could not actually be added without a migration.
//

import XCTest
import ATCReplayAdapter
@testable import ReplayCore

final class EventTracingTests: XCTestCase {

    private let session = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let coder = EventCoder(coding: ATCEventCodec())

    private func event(_ correlation: EventID? = nil, _ causation: EventID? = nil) -> Event {
        ATCEvent.commandIssued(code: "101", callsign: "AIC123", slots: ["LEVEL": "260"],
                               at: EventPosition(tick: 7, ordinal: 3),
                               source: .voice,
                               correlationID: correlation,
                               causationID: causation)
    }

    // MARK: - Absent by default

    /// Unpopulated is the normal case today, and it must cost nothing on the wire — an absent optional
    /// means "was not recorded", and emitting null would make a reader distinguish two spellings of the
    /// same absence.
    func testAbsentTracingFieldsAreNotWritten() throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try coder.encode(event())) as? [String: Any])

        XCTAssertNil(object["correlationID"])
        XCTAssertNil(object["causationID"])
    }

    /// **The property that makes this reservation worth anything.** A recording written before the fields
    /// existed decodes with them absent, not as an error.
    func testAnEventWithoutTracingFieldsStillDecodes() throws {
        let decoded = try coder.decode(try coder.encode(event()))
        XCTAssertNil(decoded.correlationID)
        XCTAssertNil(decoded.causationID)
        XCTAssertEqual(decoded.payload, event().payload)
    }

    // MARK: - Round trip when present

    func testTracingFieldsRoundTrip() throws {
        let root = EventID(session: session, ordinal: 1)
        let parent = EventID(session: session, ordinal: 2)

        let decoded = try coder.decode(try coder.encode(event(root, parent)))
        XCTAssertEqual(decoded.correlationID, root)
        XCTAssertEqual(decoded.causationID, parent)
    }

    /// Readable from the envelope, so a chain can be walked without decoding — or being able to decode —
    /// payloads a newer build wrote.
    func testTracingIsReadableFromTheEnvelopeAlone() throws {
        let root = EventID(session: session, ordinal: 1)
        let envelope = try coder.decodeEnvelope(try coder.encode(event(root, root)))

        XCTAssertEqual(envelope.correlationID, root)
        XCTAssertEqual(envelope.causationID, root)
    }

    /// A corrupt hint loses the hint, not the event. Tracing is diagnostic; failing a whole event because
    /// a debugging aid was mangled would be the wrong trade.
    func testAMalformedTracingIDIsIgnoredRatherThanFatal() throws {
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try coder.encode(event(EventID(session: session, ordinal: 1)))) as? [String: Any])
        object["correlationID"] = "not-a-uuid"

        let decoded = try coder.decode(try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.correlationID)
        XCTAssertEqual(decoded.payload, event().payload, "the event survived")
    }

    // MARK: - Attaching a chain

    /// `caused(by:)` defaults the correlation to the parent, which is right for the first link: the
    /// event that started a chain *is* the chain's root.
    func testCausedByStartsAChainAtItsParent() {
        let parent = EventID(session: session, ordinal: 1)
        let child = event().caused(by: parent)

        XCTAssertEqual(child.causationID, parent)
        XCTAssertEqual(child.correlationID, parent)
    }

    /// Deeper in a chain, the root is carried rather than replaced — otherwise every link would claim to
    /// be its own root and "everything from that transmission" would stop being one query.
    func testACorrelationIsCarriedThroughAChain() {
        let root = EventID(session: session, ordinal: 1)
        let middle = EventID(session: session, ordinal: 2)

        let deep = event(root, middle).caused(by: middle)
        XCTAssertEqual(deep.correlationID, root)
        XCTAssertEqual(deep.causationID, middle)
    }

    // MARK: - Outside ordering and identity

    /// Ordering is `(tick, ordinal)`. Tracing must never be consulted for it — a replay reading causality
    /// from a hint would be deriving it from metadata rather than from the simulation.
    func testTracingDoesNotAffectOrdering() {
        let a = EventPosition(tick: 1, ordinal: 1)
        let b = EventPosition(tick: 1, ordinal: 2)
        XCTAssertLessThan(a, b)

        // Positions compare on their own; tracing is not part of the type at all.
        XCTAssertEqual(event(EventID(session: session, ordinal: 99)).position,
                       event(nil, EventID(session: session, ordinal: 1)).position)
    }

    /// Two events differing only in their chain are the same event. An annotation must not move because
    /// tracing was added or corrected — the same rule that kept payload, tick and source out of identity.
    func testTracingDoesNotAffectIdentity() {
        let untraced = event().id(in: session)
        let traced = event(EventID(session: session, ordinal: 1),
                           EventID(session: session, ordinal: 2)).id(in: session)
        XCTAssertEqual(untraced, traced)
    }

    /// A chain can cross sessions, which is why these are full `EventID`s rather than bare ordinals: a
    /// fork continues its parent's world, so an event in a branch may legitimately name a cause in the
    /// session it forked from.
    func testAChainCanNameACauseInAnotherSession() throws {
        let parentSession = UUID()
        let causeInParent = EventID(session: parentSession, ordinal: 42)

        let decoded = try coder.decode(try coder.encode(event(causeInParent, causeInParent)))
        XCTAssertEqual(decoded.causationID, causeInParent)
        XCTAssertNotEqual(decoded.causationID, EventID(session: session, ordinal: 42),
                          "an ordinal alone could not have expressed this")
    }
}
