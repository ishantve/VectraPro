//
//  EventSourceTests.swift
//  ATCReplayKitTests
//
//  The one property that matters more than the others: a source this build has never heard of must not
//  stop a recording being read. Everything else here is about that, or about the groupings analytics
//  will ask for.
//

import XCTest
import ATCReplayAdapter
@testable import ReplayCore

final class EventSourceTests: XCTestCase {

    // MARK: - Forward compatibility

    /// **Why this is a struct and not an enum.** A newer build records `"quantum-telepathy"`; this build
    /// must still read the event. An enum would have failed to decode the whole thing, losing events over
    /// a field nobody was reading.
    func testAnUnknownSourceStillDecodes() throws {
        let coder = EventCoder()
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try coder.encode(ATCEvent.timeline(.paused,
                                                     at: EventPosition(tick: 1, ordinal: 1),
                                                     source: .voice))) as? [String: Any])
        object["source"] = "quantum-telepathy"

        let decoded = try coder.decode(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.source.rawValue, "quantum-telepathy")
        XCTAssertEqual(decoded.payload, .timelineAction(.paused), "the event survived intact")
    }

    /// And it survives being written back out, so a round trip through an older build does not silently
    /// destroy attribution it did not understand.
    func testAnUnknownSourceRoundTrips() throws {
        let coder = EventCoder()
        let exotic = EventSource(rawValue: "network-relay-v2")
        let event = ATCEvent.timeline(.paused, at: EventPosition(tick: 1, ordinal: 1), source: exotic)

        XCTAssertEqual(try coder.decode(try coder.encode(event)).source, exotic)
    }

    /// An unrecognised source says so, rather than being quietly lumped in with something familiar.
    func testAnUnknownSourceReportsThatItIsUnknown() {
        XCTAssertFalse(EventSource(rawValue: "something-new").isKnown)
        for source in EventSource.allKnown {
            XCTAssertTrue(source.isKnown, "\(source) is in allKnown but reports itself unknown")
        }
    }

    /// A recording that predates the field is `.unspecified` — "we do not know" rather than a guess.
    func testAnAbsentSourceIsUnspecifiedRatherThanAssumed() throws {
        let coder = EventCoder()
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try coder.encode(ATCEvent.timeline(.paused,
                                                     at: EventPosition(tick: 1, ordinal: 1),
                                                     source: .voice))) as? [String: Any])
        object["source"] = nil

        let decoded = try coder.decode(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.source, .unspecified)
        XCTAssertFalse(decoded.source.isHuman, "unknown attribution must not be claimed as human")
        XCTAssertFalse(decoded.source.isSynthetic)
    }

    // MARK: - Every event carries one

    /// Not only the ones with an obvious human behind them.
    func testEveryPayloadKindCanCarryASource() throws {
        let coder = EventCoder()
        func p(_ i: Int) -> EventPosition { EventPosition(tick: i, ordinal: UInt32(i)) }
        let events: [Event] = [
            ATCEvent.commandIssued(code: "101", callsign: "AIC1", slots: [:],
                                   at: p(0), source: .instructor),
            ATCEvent.commandRejected(code: nil, callsign: nil, reason: "no",
                                     at: p(1), source: .instructor),
            ATCEvent.transcriptReceived(raw: "a", normalized: "a", at: p(2), source: .instructor),
            ATCEvent.readbackSpoken(callsign: "AIC1", spoken: "ROGER", at: p(3), source: .instructor),
            ATCEvent.weatherChanged(windDegrees: 1, at: p(4), source: .instructor),
            ATCEvent.scoreEvaluated(value: 1, rulesVersion: "v1", at: p(5), source: .instructor),
            ATCEvent.timeline(.paused, at: p(6), source: .instructor),
        ]
        XCTAssertEqual(Set(events.map(\.payload.kind)).count, EventKind.allCases.count)

        for event in events {
            XCTAssertEqual(try coder.decode(try coder.encode(event)).source, .instructor)
        }
    }

    /// Readable from the envelope, so a log can be filtered by source without decoding — or being able
    /// to decode — payloads a newer build wrote.
    func testSourceIsReadableWithoutDecodingThePayload() throws {
        let coder = EventCoder()
        let data = try coder.encode(ATCEvent.commandIssued(code: "101", callsign: "A", slots: [:],
                                                           at: EventPosition(tick: 5, ordinal: 5),
                                                           source: .keypad))
        XCTAssertEqual(try coder.decodeEnvelope(data).source, .keypad)
    }

    /// It is attribution, not identity: two events differing only in source are still the same event.
    func testSourceDoesNotAffectIdentity() {
        let session = UUID()
        let position = EventPosition(tick: 1, ordinal: 3)
        let spoken = ATCEvent.timeline(.paused, at: position, source: .voice)
        let typed = ATCEvent.timeline(.paused, at: position, source: .keypad)

        XCTAssertEqual(spoken.id(in: session), typed.id(in: session))
    }

    // MARK: - Groupings

    /// "How much of this exercise did the trainee drive" is a different question from "how much did the
    /// simulator", and both get asked.
    func testHumanAndSyntheticPartitionTheKnownSources() {
        XCTAssertTrue(EventSource.voice.isHuman)
        XCTAssertTrue(EventSource.keypad.isHuman)
        XCTAssertTrue(EventSource.instructor.isHuman)

        XCTAssertTrue(EventSource.ai.isSynthetic)
        XCTAssertTrue(EventSource.system.isSynthetic)
        XCTAssertTrue(EventSource.replay.isSynthetic)
        XCTAssertTrue(EventSource.automation.isSynthetic)

        for source in EventSource.allKnown {
            XCTAssertFalse(source.isHuman && source.isSynthetic,
                           "\(source) claims to be both")
        }
    }

    /// **The grouping with a consequence rather than an insight.** An assessment must not credit or blame
    /// a trainee for an instruction an instructor injected, so instructor input is human but not the
    /// trainee's.
    func testInstructorInputIsHumanButNotTheTrainees() {
        XCTAssertTrue(EventSource.instructor.isHuman)
        XCTAssertFalse(EventSource.instructor.isAttributableToTrainee)

        XCTAssertTrue(EventSource.voice.isAttributableToTrainee)
        XCTAssertTrue(EventSource.keypad.isAttributableToTrainee)
        XCTAssertFalse(EventSource.ai.isAttributableToTrainee)
        XCTAssertFalse(EventSource.unspecified.isAttributableToTrainee)
    }

    /// `network` exists before multiplayer does, so that when multiplayer arrives no recording written
    /// before it needs changing. That is the extensibility claim, stated as a test.
    func testSourcesReservedForFutureFeaturesAlreadyExist() {
        for reserved in [EventSource.network, .replay, .automation, .ai] {
            XCTAssertTrue(reserved.isKnown)
        }
    }

    // MARK: - Coding

    func testSourceRoundTripsThroughCodable() throws {
        for source in EventSource.allKnown + [EventSource(rawValue: "custom")] {
            let decoded = try JSONDecoder().decode(EventSource.self,
                                                   from: try JSONEncoder().encode(source))
            XCTAssertEqual(decoded, source)
        }
    }

    /// Encoded as its bare string, not as a wrapper object — so the wire form stays readable and a future
    /// consumer in another language needs no special handling.
    func testSourceEncodesAsAPlainString() throws {
        let data = try JSONEncoder().encode(EventSource.voice)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"voice\"")
    }
}
