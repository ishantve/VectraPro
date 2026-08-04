//
//  EventStoreTests.swift
//  ATCReplayKitTests
//
//  The log is the only authoritative record of a session, so what matters is what happens when a
//  write is interrupted. Most of these tests corrupt a file on purpose.
//

import XCTest
@testable import ReplayCore

final class EventStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EventStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(_ sessionClass: SessionClass = .training) -> EventStore {
        EventStore(url: directory.appendingPathComponent("events.log"), sessionClass: sessionClass)
    }

    private func command(_ code: String, tick: Int, ordinal: UInt32) -> Event {
        Event(position: EventPosition(tick: tick, ordinal: ordinal),
              payload: .commandIssued(code: code, callsign: "AIC123",
                                      slots: ["LEVEL": "260"]))
    }

    // MARK: - Round trip

    func testEventsComeBackInOrder() throws {
        let store = makeStore()
        try store.openForAppending()
        for i in 0..<10 {
            try store.append(command("10\(i)", tick: i * 10, ordinal: UInt32(i)))
        }
        try store.close()

        let read = try makeStore().readAll()
        XCTAssertEqual(read.count, 10)
        XCTAssertEqual(read.map(\.tick), stride(from: 0, to: 100, by: 10).map { $0 })
    }

    /// Every payload case survives the trip. The point of writing the coding by hand was that a
    /// renamed parameter must not silently stop decoding, and this is what would notice.
    func testEveryPayloadKindSurvivesARoundTrip() throws {
        let payloads: [EventPayload] = [
            .commandIssued(code: "101", callsign: "AIC1", slots: ["LEVEL": "260"]),
            .commandRejected(code: "304", callsign: "AIC1", reason: "unmapped"),
            .transcriptReceived(raw: "air india 123 climb", normalized: "aic123 climb"),
            .readbackSpoken(callsign: "AIC1", spoken: "CLIMBING TO FLIGHT LEVEL 260"),
            .weatherChanged(windDegrees: 270, windKnots: 12, visibilityMetres: 8_000, qnh: 1013),
            .scoreEvaluated(value: 82, rulesVersion: "v3"),
            .timelineAction(.speedChanged(to: 10)),
        ]
        XCTAssertEqual(Set(payloads.map(\.kind)).count, EventKind.allCases.count,
                       "a payload kind is missing from this test")

        let store = makeStore()
        try store.openForAppending()
        for (index, payload) in payloads.enumerated() {
            try store.append(Event(position: EventPosition(tick: index, ordinal: UInt32(index)),
                                   payload: payload))
        }
        try store.close()

        XCTAssertEqual(try makeStore().readAll().map(\.payload), payloads)
    }

    /// Several inputs in one tick is the ordinary case — one transmission, three instructions — so
    /// tick is not a key and the pair must order them.
    func testManyEventsCanShareATick() throws {
        let store = makeStore()
        try store.openForAppending()
        for ordinal in UInt32(0)..<3 {
            try store.append(command("10\(ordinal)", tick: 42, ordinal: ordinal))
        }
        try store.close()

        let read = try makeStore().readAll()
        XCTAssertEqual(read.count, 3)
        XCTAssertEqual(read.map(\.ordinal), [0, 1, 2])
    }

    func testWallClockIsPreservedButOptional() throws {
        let stamped = Event(position: EventPosition(tick: 1, ordinal: 1),
                            payload: .timelineAction(.paused),
                            wallClock: Date(timeIntervalSince1970: 1_700_000_000))
        let store = makeStore()
        try store.openForAppending()
        try store.append(stamped)
        try store.append(Event(position: EventPosition(tick: 2, ordinal: 2),
                               payload: .timelineAction(.resumed)))
        try store.close()

        let read = try makeStore().readAll()
        XCTAssertEqual(read[0].wallClock?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertNil(read[1].wallClock)
    }

    // MARK: - Order is the meaning

    func testAnOutOfOrderAppendIsRefused() throws {
        let store = makeStore()
        try store.openForAppending()
        try store.append(command("101", tick: 10, ordinal: 5))

        XCTAssertThrowsError(try store.append(command("102", tick: 9, ordinal: 6))) { error in
            guard case EventStoreError.outOfOrder = error else {
                return XCTFail("expected outOfOrder, got \(error)")
            }
        }
        // The same position twice is also backwards — ordinals are unique.
        XCTAssertThrowsError(try store.append(command("103", tick: 10, ordinal: 5)))
    }

    /// Reopening must not lose track of where the log got to, or the first append after a crash
    /// could go backwards and be accepted.
    func testReopeningRemembersThePosition() throws {
        let first = makeStore()
        try first.openForAppending()
        try first.append(command("101", tick: 100, ordinal: 7))
        try first.close()

        let second = makeStore()
        try second.openForAppending()
        XCTAssertEqual(second.lastPosition, EventPosition(tick: 100, ordinal: 7))
        XCTAssertEqual(second.count, 1)
        XCTAssertThrowsError(try second.append(command("102", tick: 50, ordinal: 8)))
    }

    func testAppendingContinuesAnExistingLog() throws {
        let first = makeStore()
        try first.openForAppending()
        try first.append(command("101", tick: 1, ordinal: 1))
        try first.close()

        let second = makeStore()
        try second.openForAppending()
        try second.append(command("102", tick: 2, ordinal: 2))
        try second.close()

        XCTAssertEqual(try makeStore().readAll().count, 2)
    }

    // MARK: - Crash recovery

    /// **The reason the log is framed rather than a JSON array.** A process killed mid-write leaves a
    /// partial frame; everything before it must still be readable. A truncated JSON array would parse
    /// as nothing at all.
    func testAHalfWrittenFrameLosesOnlyItself() throws {
        let store = makeStore()
        try store.openForAppending()
        for i in 1...5 { try store.append(command("10\(i)", tick: i, ordinal: UInt32(i))) }
        try store.close()

        // Simulate the kill: chop the last few bytes off the file.
        let url = store.url
        let data = try Data(contentsOf: url)
        try data.prefix(data.count - 20).write(to: url)

        let recovery = try makeStore().recover()
        XCTAssertTrue(recovery.wasTruncated)
        XCTAssertGreaterThan(recovery.trailingBytes, 0)
        XCTAssertEqual(recovery.events.count, 4, "the four complete frames must survive")
        XCTAssertEqual(recovery.events.map(\.tick), [1, 2, 3, 4])
    }

    /// A frame whose bytes were mangled rather than cut short is caught by the checksum, not by the
    /// length — a corrupted event must not decode into a plausible wrong one.
    func testACorruptedPayloadIsRejectedByItsChecksum() throws {
        let store = makeStore()
        try store.openForAppending()
        try store.append(command("101", tick: 1, ordinal: 1))
        try store.append(command("102", tick: 2, ordinal: 2))
        try store.close()

        var data = try Data(contentsOf: store.url)
        data[data.count - 5] ^= 0xFF          // flip a bit inside the last payload
        try data.write(to: store.url)

        let recovery = try makeStore().recover()
        XCTAssertEqual(recovery.events.count, 1)
        XCTAssertTrue(recovery.wasTruncated)
    }

    func testACleanLogIsNotReportedAsTruncated() throws {
        let store = makeStore()
        try store.openForAppending()
        try store.append(command("101", tick: 1, ordinal: 1))
        try store.close()

        let recovery = try makeStore().recover()
        XCTAssertFalse(recovery.wasTruncated)
        XCTAssertEqual(recovery.trailingBytes, 0)
    }

    /// Truncating is separate from reading, and only reading happens by default: nothing should
    /// destroy part of a recording as a side effect of opening it.
    func testTruncatingIsExplicitAndRemovesOnlyTheBadTail() throws {
        let store = makeStore()
        try store.openForAppending()
        for i in 1...3 { try store.append(command("10\(i)", tick: i, ordinal: UInt32(i))) }
        try store.close()

        let before = try Data(contentsOf: store.url).count
        var data = try Data(contentsOf: store.url)
        data.append(contentsOf: [0x41, 0x54, 0x43, 0x31, 0xFF, 0xFF])   // a frame that goes nowhere
        try data.write(to: store.url)

        let discarded = try makeStore().truncateToLastValidFrame()
        XCTAssertEqual(discarded, 6)
        XCTAssertEqual(try Data(contentsOf: store.url).count, before)
        XCTAssertEqual(try makeStore().readAll().count, 3)
        XCTAssertFalse(try makeStore().recover().wasTruncated)
    }

    func testTruncatingACleanLogChangesNothing() throws {
        let store = makeStore()
        try store.openForAppending()
        try store.append(command("101", tick: 1, ordinal: 1))
        try store.close()

        let before = try Data(contentsOf: store.url)
        XCTAssertEqual(try makeStore().truncateToLastValidFrame(), 0)
        XCTAssertEqual(try Data(contentsOf: store.url), before)
    }

    /// A file that is not an event log must say so, rather than being read as an empty one — "there
    /// were no events" and "this is the wrong file" need different answers.
    func testAFileThatIsNotAnEventLogIsRejected() throws {
        let url = directory.appendingPathComponent("events.log")
        try Data("this is not a log, it is a poem".utf8).write(to: url)

        XCTAssertThrowsError(try makeStore().readAll()) { error in
            XCTAssertEqual(error as? EventStoreError, .notAnEventLog)
        }
    }

    func testAMissingLogReadsAsEmptyRatherThanFailing() throws {
        XCTAssertEqual(try makeStore().readAll().count, 0)
        XCTAssertFalse(try makeStore().recover().wasTruncated)
    }

    func testAnEmptyLogReadsAsEmpty() throws {
        let store = makeStore()
        try store.openForAppending()
        try store.close()
        XCTAssertEqual(try makeStore().readAll().count, 0)
    }

    // MARK: - Durability

    /// An assessment must have every event on disk before the next is accepted. Checked by reading
    /// the file from a *second* store while the first is still open and has not been asked to flush.
    func testAnAssessmentIsOnDiskAfterEveryEvent() throws {
        let store = makeStore(.assessment)
        try store.openForAppending()
        try store.append(command("101", tick: 1, ordinal: 1))

        XCTAssertEqual(try makeStore(.assessment).readAll().count, 1,
                       "an assessment event was still only in memory")
        try store.close()
    }

    /// Training may batch, which is the trade: a hard kill loses what has not been flushed. Asserted
    /// so the difference between the two classes is a documented behaviour rather than an accident.
    func testTrainingMayHoldEventsUntilFlushed() throws {
        let store = makeStore(.training)
        try store.openForAppending()
        try store.append(command("101", tick: 1, ordinal: 1))

        XCTAssertEqual(try makeStore(.training).readAll().count, 0, "training flushed too eagerly")
        try store.flush()
        XCTAssertEqual(try makeStore(.training).readAll().count, 1)
        try store.close()
    }

    func testClosingFlushes() throws {
        let store = makeStore(.training)
        try store.openForAppending()
        try store.append(command("101", tick: 1, ordinal: 1))
        try store.close()
        XCTAssertEqual(try makeStore().readAll().count, 1)
    }

    // MARK: - Queries

    func testEventsCanBeFetchedByTickRange() throws {
        let store = makeStore()
        try store.openForAppending()
        for i in 0..<20 { try store.append(command("1", tick: i * 5, ordinal: UInt32(i))) }
        try store.close()

        let window = try makeStore().events(ticks: 20...40)
        XCTAssertEqual(window.map(\.tick), [20, 25, 30, 35, 40])
    }

    // MARK: - Volume

    /// A busy exercise is on the order of a thousand events. The architecture claims that is about a
    /// hundred kilobytes; this checks the claim rather than trusting it, because the whole size
    /// argument for recording causes instead of state rests on it.
    func testAThousandEventsStayWellUnderAMegabyte() throws {
        let store = makeStore()
        try store.openForAppending()
        for i in 0..<1_000 {
            try store.append(Event(position: EventPosition(tick: i, ordinal: UInt32(i)),
                                   payload: .commandIssued(code: "101", callsign: "AIC1234",
                                                           slots: ["LEVEL": "260"])))
        }
        try store.close()

        let bytes = try Data(contentsOf: store.url).count
        XCTAssertLessThan(bytes, 250_000, "1,000 events took \(bytes) bytes")
        XCTAssertEqual(try makeStore().readAll().count, 1_000)
    }
}
