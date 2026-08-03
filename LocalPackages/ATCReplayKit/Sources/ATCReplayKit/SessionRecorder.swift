//
//  SessionRecorder.swift
//  ATCReplayKit
//
//  Writes one session: buffers, flushes, and keeps its seal up to date.
//
//  ── It observes; it never decides ──────────────────────────────────────────
//  The recorder is handed events that already happened. It does not validate them, reorder them, or refuse
//  them, and it returns nothing the caller acts on. That is deliberate: the moment recording can influence
//  what the simulation does, a recorded session and an unrecorded one stop being the same exercise.
//
//  ── Failure does not stop the exercise ─────────────────────────────────────
//  If a write fails, the recorder marks itself **degraded** and the simulation carries on. An earlier draft
//  of the design had an input that could not be recorded refuse to execute, on the grounds that a recording
//  should always explain its session. That is the wrong trade for a training product: a trainee mid-exercise
//  should not have instructions refused because a disk filled up, and an honestly-labelled partial recording
//  beats a broken exercise. `isDegraded` is what makes it honest — a caller can say so, and an assessment
//  that degraded is not a valid assessment.
//

import Foundation

/// Records one session's events.
public final class SessionRecorder {

    public let sessionID: SessionID
    public let sessionClass: SessionClass

    private let store: EventStore
    private var sealBuilder: SessionSealBuilder

    /// Something could not be written. The events already on disk are still valid; the recording is
    /// incomplete from that point.
    public private(set) var isDegraded = false

    /// Why, for the caller to show. First failure only — a full disk produces the same error repeatedly, and
    /// the first one is the informative one.
    public private(set) var degradedReason: String?

    /// Events accepted, whether or not they reached disk.
    public private(set) var acceptedCount = 0

    public init(sessionID: SessionID,
                sessionClass: SessionClass,
                manifestBytes: Data,
                store: EventStore) {
        self.sessionID = sessionID
        self.sessionClass = sessionClass
        self.store = store
        self.sealBuilder = SessionSealBuilder(manifest: manifestBytes)
    }

    deinit {
        try? store.close()
    }

    /// Opens the log for appending.
    ///
    /// Returns the position already in the log, so a caller resuming after a crash can continue its ordinal
    /// counter rather than restarting it — restarting would mint an event id that already exists, since ids
    /// are derived from `(session, ordinal)`.
    @discardableResult
    public func open() throws -> EventPosition? {
        try store.openForAppending()

        // Rebuild the seal over what is already there. A running hasher does not survive the process, so
        // resuming has to re-absorb the existing frames or the final seal would cover only the new ones.
        if store.count > 0, let existing = try? Data(contentsOf: store.url) {
            sealBuilder.add(frame: existing)
        }
        acceptedCount = store.count
        return store.lastPosition
    }

    /// Writes one event down.
    ///
    /// Returns nothing on purpose. A caller that could branch on the result would be a caller whose
    /// behaviour depends on recording, which is the one thing this must not introduce.
    public func record(_ event: Event) {
        acceptedCount += 1
        do {
            sealBuilder.add(frame: try store.append(stamped(event)))
        } catch {
            degrade("could not write event \(event.ordinal): \(error)")
        }
    }

    /// Adds the audit timestamp, if the caller did not supply one.
    ///
    /// **Real time is stamped here and only here.** The simulation and the gateway deal in ticks; this is
    /// the recording layer, and "how long did the trainee take to respond" is a question worth being able to
    /// answer. Nothing inside the simulation reads it — the app's `DeterministicTimeTests` scan enforces
    /// that by banning real time from the command path entirely, which is why this stamp lives on this side
    /// of the boundary rather than in the gateway.
    private func stamped(_ event: Event) -> Event {
        guard event.wallClock == nil else { return event }
        return Event(position: event.position,
                     payload: event.payload,
                     source: event.source,
                     correlationID: event.correlationID,
                     causationID: event.causationID,
                     wallClock: now())
    }

    /// Injectable so a test can pin the timestamp. Defaults to the real clock, which is correct here and
    /// only here.
    public var now: () -> Date = { Date() }

    /// Pushes anything buffered to disk. A no-op for an assessment, which flushes per event.
    public func flush() {
        do { try store.flush() } catch { degrade("could not flush: \(error)") }
    }

    /// The seal over everything recorded so far.
    ///
    /// Readable mid-session — it does not end the seal — so a progress display can show it without
    /// committing to it.
    public var seal: String { sealBuilder.seal() }

    public var recordedBytes: Int { sealBuilder.byteCount }

    /// Closes the log and returns the final seal.
    ///
    /// Nil when the recording degraded: a seal over a recording known to be incomplete would assert
    /// something untrue about it, and an assessment must not be sealable in that state.
    public func finish() -> String? {
        flush()
        try? store.close()
        return isDegraded ? nil : sealBuilder.seal()
    }

    // MARK: - Private

    private func degrade(_ reason: String) {
        guard !isDegraded else { return }   // the first failure is the informative one
        isDegraded = true
        degradedReason = reason
    }
}
