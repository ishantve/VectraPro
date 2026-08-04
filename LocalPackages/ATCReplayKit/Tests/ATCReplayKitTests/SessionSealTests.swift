//
//  SessionSealTests.swift
//  ATCReplayKitTests
//
//  The seal is computed one way while recording and verified another way when reading. The test that matters
//  is the one asserting the two agree — a disagreement would make every assessment unverifiable, and it
//  would not show up anywhere else.
//

import XCTest
import ATCReplayAdapter
@testable import ReplayCore

final class SessionSealTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Seal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recorder(_ sessionClass: SessionClass = .assessment,
                          manifest: Data = Data(#"{"seed":42}"#.utf8)) -> (SessionRecorder, URL) {
        let url = directory.appendingPathComponent("events.log")
        let recorder = SessionRecorder(sessionID: UUID(), sessionClass: sessionClass,
                                       manifestBytes: manifest,
                                       store: EventStore(url: url, sessionClass: sessionClass,
                                                         coding: ATCEventCodec()))
        recorder.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        return (recorder, url)
    }

    private func event(_ ordinal: UInt32) -> Event {
        ATCEvent.commandIssued(code: "101", callsign: "AIC123", slots: ["LEVEL": "260"],
                               at: EventPosition(tick: Int(ordinal), ordinal: ordinal),
                               source: .voice)
    }

    // MARK: - The two forms agree

    /// **The property everything else depends on.** Built incrementally while recording, recomputed in one
    /// pass on read; if they disagreed, no assessment could ever be verified.
    func testTheIncrementalSealMatchesAOnePassRecompute() throws {
        let manifest = Data(#"{"seed":42}"#.utf8)
        let (recorder, url) = self.recorder(manifest: manifest)
        try recorder.open()
        for ordinal in UInt32(1)...20 { recorder.record(event(ordinal)) }

        let sealed = try XCTUnwrap(recorder.finish())
        let recomputed = SessionSeal.compute(manifest: manifest, log: try Data(contentsOf: url))

        XCTAssertEqual(sealed, recomputed)
        XCTAssertTrue(SessionSeal.verify(sealed, manifest: manifest,
                                         log: try Data(contentsOf: url)))
    }

    /// A tampered log fails. This is corruption detection, not tamper resistance — an unkeyed digest can be
    /// recomputed on the device after an edit — but a bit-flip or a truncation is caught.
    func testAnAlteredLogFailsVerification() throws {
        let manifest = Data(#"{"seed":42}"#.utf8)
        let (recorder, url) = self.recorder(manifest: manifest)
        try recorder.open()
        for ordinal in UInt32(1)...5 { recorder.record(event(ordinal)) }
        let sealed = try XCTUnwrap(recorder.finish())

        var log = try Data(contentsOf: url)
        log[log.count - 3] ^= 0x01
        XCTAssertFalse(SessionSeal.verify(sealed, manifest: manifest, log: log))
    }

    /// A different manifest fails too — the seal covers the seed and the exercise, not only the events.
    func testADifferentManifestFailsVerification() throws {
        let (recorder, url) = self.recorder(manifest: Data(#"{"seed":42}"#.utf8))
        try recorder.open()
        recorder.record(event(1))
        let sealed = try XCTUnwrap(recorder.finish())

        XCTAssertFalse(SessionSeal.verify(sealed, manifest: Data(#"{"seed":43}"#.utf8),
                                          log: try Data(contentsOf: url)))
    }

    /// Length-prefixing the manifest is what stops a manifest and a first event being rearranged into the
    /// same digest. Without it, `"ab" + "c"` and `"a" + "bc"` would seal identically.
    func testTheManifestBoundaryIsUnambiguous() {
        let first = SessionSeal.compute(manifest: Data("ab".utf8), log: Data("c".utf8))
        let second = SessionSeal.compute(manifest: Data("a".utf8), log: Data("bc".utf8))
        XCTAssertNotEqual(first, second)
    }

    func testAnEmptySessionStillSeals() throws {
        let (recorder, _) = self.recorder()
        try recorder.open()
        XCTAssertNotNil(recorder.finish(), "a session with no events is still a session")
    }

    /// Readable mid-session without ending the seal, for a progress display.
    func testTheSealCanBeReadWithoutFinishing() throws {
        let (recorder, _) = self.recorder()
        try recorder.open()
        recorder.record(event(1))

        let midway = recorder.seal
        recorder.record(event(2))
        XCTAssertNotEqual(recorder.seal, midway, "the seal should have moved on")
        XCTAssertNotNil(recorder.finish())
    }

    // MARK: - Resuming

    /// A running hasher does not survive the process, so resuming has to re-absorb the frames already on
    /// disk — otherwise the final seal would cover only the events written after the crash.
    func testResumingCoversTheEventsWrittenBeforeTheCrash() throws {
        let manifest = Data(#"{"seed":42}"#.utf8)
        let url = directory.appendingPathComponent("events.log")

        // First run, killed after three events.
        let first = SessionRecorder(sessionID: UUID(), sessionClass: .assessment,
                                    manifestBytes: manifest,
                                    store: EventStore(url: url, sessionClass: .assessment,
                                                      coding: ATCEventCodec()))
        first.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        try first.open()
        for ordinal in UInt32(1)...3 { first.record(event(ordinal)) }
        first.flush()

        // Second run continues.
        let second = SessionRecorder(sessionID: UUID(), sessionClass: .assessment,
                                     manifestBytes: manifest,
                                     store: EventStore(url: url, sessionClass: .assessment,
                                                      coding: ATCEventCodec()))
        second.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        let position = try second.open()
        XCTAssertEqual(position?.ordinal, 3, "the resumed recorder must see where the log got to")
        for ordinal in UInt32(4)...6 { second.record(event(ordinal)) }

        let sealed = try XCTUnwrap(second.finish())
        XCTAssertEqual(sealed, SessionSeal.compute(manifest: manifest,
                                                   log: try Data(contentsOf: url)),
                       "the resumed seal did not cover the events written before the crash")
    }

    // MARK: - Degrading

    /// **A recording known to be incomplete cannot be sealed.** A seal would assert something untrue about
    /// it, and an assessment must not be sealable in that state.
    func testADegradedRecordingRefusesToSeal() throws {
        let (recorder, _) = self.recorder()
        // Never opened, so every write fails.
        recorder.record(event(1))

        XCTAssertTrue(recorder.isDegraded)
        XCTAssertNotNil(recorder.degradedReason)
        XCTAssertNil(recorder.finish(), "a degraded recording produced a seal")
    }

    /// The first failure is the informative one; a full disk produces the same error repeatedly.
    func testOnlyTheFirstFailureIsKept() {
        let (recorder, _) = self.recorder()
        recorder.record(event(1))
        let first = recorder.degradedReason
        recorder.record(event(2))
        XCTAssertEqual(recorder.degradedReason, first)
    }

    /// Recording keeps accepting after it degrades, because the exercise carries on. The events already on
    /// disk stay valid; the recording is incomplete from that point.
    func testAcceptingContinuesAfterDegrading() {
        let (recorder, _) = self.recorder()
        for ordinal in UInt32(1)...5 { recorder.record(event(ordinal)) }
        XCTAssertEqual(recorder.acceptedCount, 5)
        XCTAssertTrue(recorder.isDegraded)
    }
}
