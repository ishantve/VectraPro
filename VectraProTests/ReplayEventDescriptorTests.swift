//
//  ReplayEventDescriptorTests.swift
//  VectraProTests
//
//  Every ATC event tag maps to a human line; playback-control markers and foreign payloads map to nil; and no
//  raw code, enum name, or serialized payload leaks into the text.
//

import XCTest
import ATCReplayKit
@testable import VectraPro

final class ReplayEventDescriptorTests: XCTestCase {

    /// Deterministic label resolver: only "C/M*" is a known code ("Altitude"); everything else is unknown.
    private let d = ReplayEventDescriptor(label: { $0 == "C/M*" ? "Altitude" : nil })

    private func pos(_ tick: Int, _ ordinal: UInt32 = 0) -> EventPosition {
        EventPosition(tick: tick, ordinal: ordinal)
    }

    private func assertClean(_ s: String?, file: StaticString = #filePath, line: UInt = #line) {
        let text = s ?? ""
        for banned in ["C/M*", "commandIssued", "timelineAction", "ATCPayload", "{", "}", "Optional(", "EventBody"] {
            XCTAssertFalse(text.contains(banned), "leaked internal token “\(banned)” in: \(text)", file: file, line: line)
        }
    }

    func testCommandIssuedKnownCodeUsesCategoryAndValues() {
        let e = ATCEvent.commandIssued(code: "C/M*", callsign: "AIC231",
                                       slots: ["level": "260", "unit": "FL"], at: pos(12))
        let s = d.describe(e)
        XCTAssertEqual(s, "Controller issued Altitude clearance to AIC231 (level 260, unit FL)")
        assertClean(s)
    }

    func testCommandIssuedUnknownCodeFallsBackWithoutExposingCode() {
        let e = ATCEvent.commandIssued(code: "Z/Z?", callsign: "BAW9", slots: ["heading": "270"], at: pos(3))
        let s = d.describe(e)
        XCTAssertEqual(s, "Controller issued a clearance to BAW9 (heading 270)")
        assertClean(s)
    }

    func testCommandIssuedEmptyCallsignReadsAsSelectedAircraft() {
        let e = ATCEvent.commandIssued(code: "C/M*", callsign: "", slots: [:], at: pos(1))
        XCTAssertEqual(d.describe(e), "Controller issued Altitude clearance to the selected aircraft")
    }

    func testCommandRejected() {
        let e = ATCEvent.commandRejected(code: "H/M*", callsign: "AIC231",
                                         reason: "no aircraft selected", at: pos(30))
        XCTAssertEqual(d.describe(e), "Instruction refused to AIC231 — no aircraft selected")
        let e2 = ATCEvent.commandRejected(code: nil, callsign: nil, reason: "outside limits", at: pos(31))
        XCTAssertEqual(d.describe(e2), "Instruction refused — outside limits")
    }

    func testTranscriptReceivedUsesNormalized() {
        let e = ATCEvent.transcriptReceived(raw: "aic two three one descend",
                                            normalized: "AIC231 DESCEND FL260", at: pos(12))
        XCTAssertEqual(d.describe(e), "Transmission: AIC231 DESCEND FL260")
    }

    func testReadbackSpoken() {
        let e = ATCEvent.readbackSpoken(callsign: "AIC231",
                                        spoken: "descending flight level two six zero", at: pos(13))
        XCTAssertEqual(d.describe(e), "AIC231 read back: descending flight level two six zero")
    }

    func testWeatherChangedFull() {
        let e = ATCEvent.weatherChanged(windDegrees: 270, windKnots: 12, visibilityMetres: 8000,
                                        qnh: 1013, at: pos(60))
        XCTAssertEqual(d.describe(e), "Weather updated — wind 270°/12 kt, visibility 8000 m, QNH 1013")
    }

    func testWeatherChangedAllNilStillReadable() {
        let e = ATCEvent.weatherChanged(at: pos(90))
        XCTAssertEqual(d.describe(e), "Weather updated")
    }

    func testScoreEvaluated() {
        let e = ATCEvent.scoreEvaluated(value: 87, rulesVersion: "atc-scoring-1.2.0", at: pos(120))
        XCTAssertEqual(d.describe(e), "Score evaluated: 87")
    }

    func testTimelineStartedAndStoppedAreShown() {
        XCTAssertEqual(d.describe(ATCEvent.timeline(.replayStarted, at: pos(0))), "Session started")
        XCTAssertEqual(d.describe(ATCEvent.timeline(.replayStopped, at: pos(200))), "Session ended")
    }

    func testPlaybackControlTimelineActionsAreFiltered() {
        for action in [TimelineAction.paused, .resumed, .speedChanged(to: 4), .seeked(to: 12)] {
            XCTAssertNil(d.describe(ATCEvent.timeline(action, at: pos(5))),
                         "\(action) is a playback artifact and must not appear in the timeline")
        }
    }

    func testEveryDescribedLineIsClean() {
        let events = [
            ATCEvent.commandIssued(code: "C/M*", callsign: "AIC231", slots: ["level": "260"], at: pos(1)),
            ATCEvent.commandRejected(code: "H/M*", callsign: nil, reason: "no aircraft selected", at: pos(2)),
            ATCEvent.transcriptReceived(raw: "x", normalized: "AIC231 DESCEND", at: pos(3)),
            ATCEvent.readbackSpoken(callsign: "AIC231", spoken: "wilco", at: pos(4)),
            ATCEvent.weatherChanged(windDegrees: 270, windKnots: 12, visibilityMetres: nil, qnh: nil, at: pos(5)),
            ATCEvent.scoreEvaluated(value: 87, rulesVersion: "v1", at: pos(6)),
            ATCEvent.timeline(.replayStarted, at: pos(0)),
        ]
        for e in events { assertClean(d.describe(e)) }
    }
}
