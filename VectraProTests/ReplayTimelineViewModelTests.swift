//
//  ReplayTimelineViewModelTests.swift
//  VectraProTests
//
//  The timeline reads a recording's events, orders them by (tick, ordinal), stamps them MM:SS from the tick,
//  drops playback-control markers, and reports the current entry for a given replay position.
//

import XCTest
import ATCReplayKit
import ATCReplayStore
@testable import VectraPro

@MainActor
final class ReplayTimelineViewModelTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Timeline-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func startedManager() throws -> (SessionManager, SessionID) {
        let cat = try SQLiteSessionCatalogue(url: root.appendingPathComponent("c.sqlite"))
        let m = SessionManager(root: root, catalogue: cat,
                               environment: RecordingEnvironment(buildVersion: "1.0.0", architecture: "arm64",
                                                                 platform: "test"),
                               coding: ATCEventCodec())
        let s = try m.start(origin: .selfDirected, seed: 1, owner: .user("t"),
                            exercise: EmbeddedExercise(payload: Data("{}".utf8), exerciseName: "T"))
        return (m, s.id)
    }

    private func pos(_ tick: Int, _ ordinal: UInt32 = 0) -> EventPosition { EventPosition(tick: tick, ordinal: ordinal) }

    private func write(_ events: [Event], to m: SessionManager, _ id: SessionID, endAt tick: Int) throws {
        let store = EventStore(url: m.eventLogURL(for: id), sessionClass: .training, coding: ATCEventCodec())
        try store.openForAppending()
        for e in events { try store.append(e) }
        try store.close()
        _ = try m.end(tickCount: tick)
    }

    private func vm() -> ReplayTimelineViewModel {
        ReplayTimelineViewModel(descriptor: ReplayEventDescriptor(label: { _ in "Altitude" }))
    }

    func testOrderedByTickThenOrdinalWithMMSSTimestamps() throws {
        let (m, id) = try startedManager()
        // The store enforces monotonic (tick, ordinal) on append, so ordering is a write-time guarantee; the
        // point under test is that the VM stamps MM:SS from the tick and keeps two events that share a tick in
        // ordinal order (readback 65/0 before command 65/1), both reading "01:05".
        try write([
            ATCEvent.timeline(.replayStarted, at: pos(0, 0)),
            ATCEvent.readbackSpoken(callsign: "AIC231", spoken: "wilco", at: pos(65, 0)),
            ATCEvent.commandIssued(code: "C/M*", callsign: "AIC231", slots: [:], at: pos(65, 1)),
        ], to: m, id, endAt: 65)

        let model = vm()
        model.load(sessionID: id, using: m)

        XCTAssertNil(model.failure)
        XCTAssertEqual(model.entries.map(\.tick), [0, 65, 65])
        XCTAssertEqual(model.entries.map(\.ordinal), [0, 0, 1])            // ordinal breaks the tick-65 tie
        XCTAssertEqual(model.entries.map(\.timestamp), ["00:00", "01:05", "01:05"])
        XCTAssertEqual(model.entries[0].text, "Session started")
        XCTAssertTrue(model.entries[1].text.contains("read back"))
        XCTAssertTrue(model.entries[2].text.contains("clearance"))
    }

    func testPlaybackControlMarkersAreExcluded() throws {
        let (m, id) = try startedManager()
        try write([
            ATCEvent.timeline(.replayStarted, at: pos(0)),
            ATCEvent.timeline(.paused, at: pos(1)),
            ATCEvent.timeline(.speedChanged(to: 4), at: pos(2)),
            ATCEvent.timeline(.seeked(to: 10), at: pos(3)),
            ATCEvent.timeline(.resumed, at: pos(4)),
            ATCEvent.commandIssued(code: "C/M*", callsign: "A", slots: [:], at: pos(5)),
        ], to: m, id, endAt: 5)

        let model = vm()
        model.load(sessionID: id, using: m)
        // Only the started marker + the command survive; the four playback artifacts are gone.
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertEqual(model.entries.map(\.tick), [0, 5])
    }

    func testCurrentEntryTracksReplayPosition() throws {
        let (m, id) = try startedManager()
        try write([
            ATCEvent.timeline(.replayStarted, at: pos(0)),
            ATCEvent.commandIssued(code: "C/M*", callsign: "A", slots: [:], at: pos(12)),
            ATCEvent.commandIssued(code: "C/M*", callsign: "A", slots: [:], at: pos(30)),
        ], to: m, id, endAt: 30)

        let model = vm()
        model.load(sessionID: id, using: m)
        let ids = model.entries.map(\.id)
        XCTAssertEqual(model.currentEntryID(atPosition: 0), ids[0])
        XCTAssertEqual(model.currentEntryID(atPosition: 5), ids[0])   // between start and first command
        XCTAssertEqual(model.currentEntryID(atPosition: 12), ids[1])
        XCTAssertEqual(model.currentEntryID(atPosition: 29), ids[1])
        XCTAssertEqual(model.currentEntryID(atPosition: 100), ids[2]) // past the end clamps to last
    }
}
