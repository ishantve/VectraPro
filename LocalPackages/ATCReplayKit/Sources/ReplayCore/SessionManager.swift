//
//  SessionManager.swift
//  ATCReplayKit
//
//  Session lifecycle: start, end, recover, list, retain.
//
//  Owns the layout on disk and the transitions between states. Does not own the simulation, the
//  events' meaning, or the timeline — it is the registrar.
//
//  ── Layout ─────────────────────────────────────────────────────────────────
//      <root>/
//        catalogue.sqlite            the index (or an in-memory stand-in)
//        <sessionID>/
//          manifest.json            written once, never mutated
//          manifest.json.bak        a second copy — see below
//          events.log               append-only frames
//          snapshots/               later; a cache, safe to delete
//
//  The manifest is written twice. It is small, it is written once, and losing it is the only
//  *unrecoverable* failure in this design: the seed is the root of the whole reconstruction, so a
//  corrupt manifest means a session that can never be replayed, however intact its events are. A few
//  hundred duplicated bytes against that is not a trade worth thinking about.
//

import Foundation

public enum SessionManagerError: Error, Equatable {
    case notRecording
    case alreadyRecording(SessionID)
    case notFound(SessionID)
    case manifestMissing(SessionID)
    /// An assessment cannot be recorded by an unauthenticated owner: there would be nobody for the
    /// result to be about.
    case assessmentRequiresAuthenticatedOwner
}

// MARK: - Retention

/// What to keep.
///
/// Configurable rather than hardcoded, and unlimited by default. Retention is a policy that will
/// change — a device budget, an age limit, an instructor-managed rule — and none of those should need
/// the storage format to change, so this decides only *which sessions to remove*, never how they are
/// stored.
public struct RetentionPolicy: Equatable, Sendable {

    /// Most sessions to keep, or nil for no limit.
    public var maximumSessions: Int?

    /// Oldest a session may be, or nil for no limit.
    public var maximumAge: TimeInterval?

    /// Whether assessments may be removed by retention.
    ///
    /// False by default, and this is the important default: an assessment is a record about a person,
    /// and deleting one is an administrative act with its own audit trail — not something a
    /// housekeeping pass does because a device is filling up.
    public var evictsAssessments: Bool

    public static let unlimited = RetentionPolicy()

    public init(maximumSessions: Int? = nil,
                maximumAge: TimeInterval? = nil,
                evictsAssessments: Bool = false) {
        self.maximumSessions = maximumSessions
        self.maximumAge = maximumAge
        self.evictsAssessments = evictsAssessments
    }

    /// Which of `sessions` should go, oldest first.
    ///
    /// A pure function, so the policy can be reasoned about and tested without a filesystem — and so
    /// a UI can show what a policy *would* remove before it does.
    public func evictable(from sessions: [SessionSummary], now: Date) -> [SessionSummary] {
        var candidates = sessions.filter { summary in
            guard summary.sessionClass != .assessment || evictsAssessments else { return false }
            // Never evict something still being written.
            return summary.state != .recording
        }
        // Oldest first: retention removes history from the far end.
        candidates.sort { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }

        var doomed: [SessionSummary] = []

        if let maximumAge {
            let cutoff = now.addingTimeInterval(-maximumAge)
            doomed += candidates.filter { $0.createdAt < cutoff }
        }

        if let maximumSessions {
            // Counted against *every* session, including the ones retention may not touch — the limit
            // is about how much is on the device, not how much is evictable.
            let excess = sessions.count - doomed.count - maximumSessions
            if excess > 0 {
                let remaining = candidates.filter { candidate in
                    !doomed.contains { $0.id == candidate.id }
                }
                doomed += remaining.prefix(excess)
            }
        }

        return doomed
    }
}

// MARK: - Manager

/// Creates, ends, recovers and lists sessions.
///
/// Not an actor and not thread-safe: one session records at a time, on the main actor, alongside the
/// simulation. Making this concurrent would suggest an ordering freedom that recording does not have.
public final class SessionManager {

    public let root: URL
    public let catalogue: SessionCatalogue
    public let environment: RecordingEnvironment
    public var retention: RetentionPolicy

    /// The session currently accepting events, if any.
    public private(set) var active: Session?

    /// The active session's manifest, kept so `EventStore` and a recorder can be built from it.
    public private(set) var activeManifest: SessionManifest?

    /// How this consumer's payloads are coded.
    ///
    /// Held because the registrar opens event logs — to recover an interrupted session, and to read one back —
    /// and a log cannot be read without the codec that wrote it. Passed through to every `EventStore` this
    /// manager creates, so a caller supplies it once rather than at every open.
    public let coding: any EventPayloadCoding

    public init(root: URL,
                catalogue: SessionCatalogue,
                environment: RecordingEnvironment,
                coding: any EventPayloadCoding,
                retention: RetentionPolicy = .unlimited) {
        self.root = root
        self.catalogue = catalogue
        self.environment = environment
        self.coding = coding
        self.retention = retention
    }

    // MARK: Paths

    public func directory(for id: SessionID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func manifestURL(for id: SessionID) -> URL {
        directory(for: id).appendingPathComponent("manifest.json")
    }

    public func eventLogURL(for id: SessionID) -> URL {
        directory(for: id).appendingPathComponent("events.log")
    }

    private func manifestBackupURL(for id: SessionID) -> URL {
        directory(for: id).appendingPathComponent("manifest.json.bak")
    }

    // MARK: Starting

    /// Begins recording.
    ///
    /// Writes the manifest **before** returning, so a session that starts is always identifiable
    /// afterwards — including one whose process dies a second later. A crashed session with no
    /// manifest would be an orphan directory nobody could interpret.
    @discardableResult
    public func start(origin: SessionOrigin,
                      seed: UInt64,
                      owner: OwnerID,
                      exercise: EmbeddedExercise,
                      label: String = "",
                      now: Date = Date(),
                      id: SessionID = UUID()) throws -> Session {

        if let active { throw SessionManagerError.alreadyRecording(active.id) }

        if origin.sessionClass == .assessment, !owner.isAuthenticated {
            throw SessionManagerError.assessmentRequiresAuthenticatedOwner
        }

        let manifest = SessionManifest(sessionID: id,
                                       origin: origin,
                                       seed: seed,
                                       ownerID: owner,
                                       environment: environment,
                                       exercise: exercise,
                                       createdAt: now)

        try FileManager.default.createDirectory(at: directory(for: id),
                                                withIntermediateDirectories: true)
        let encoded = try manifest.encoded()
        try encoded.write(to: manifestURL(for: id))
        try encoded.write(to: manifestBackupURL(for: id))

        let session = Session(id: id,
                              origin: origin,
                              seed: seed,
                              ownerID: owner.storageKey,
                              label: label,
                              state: .recording,
                              tickCount: origin.forkTick ?? 0)

        try catalogue.upsert(SessionSummary(session: session, manifest: manifest))
        active = session
        activeManifest = manifest
        return session
    }

    /// Replaces the active session with a moved-on version of itself.
    ///
    /// For a transition the manager did not drive — a recorder degrading mid-exercise. Checked rather than
    /// trusted: swapping in a different session would silently detach the recorder from what it is recording.
    public func replaceActive(with session: Session) throws {
        guard let active, active.id == session.id else {
            throw SessionManagerError.notRecording
        }
        try record(session)
        self.active = session
    }

    // MARK: Ending

    /// Ends the active session.
    ///
    /// `digest` is required for an assessment and ignored for training — the seal is what makes an
    /// assessment evidence, and `Session.finished` refuses the transition without one.
    @discardableResult
    public func end(tickCount: Int, digest: String? = nil) throws -> Session {
        guard var session = active else { throw SessionManagerError.notRecording }
        session.tickCount = tickCount

        let finished = try session.finished(tickCount: tickCount, digest: digest)
        try record(finished)
        active = nil
        activeManifest = nil
        return finished
    }

    /// Marks the active session as interrupted without ending it cleanly. For a controlled teardown
    /// that is not a completion — leaving the exercise, for instance.
    @discardableResult
    public func abandon(tickCount: Int) throws -> Session {
        guard var session = active else { throw SessionManagerError.notRecording }
        session.tickCount = tickCount
        let interrupted = session.interrupted()
        try record(interrupted)
        active = nil
        activeManifest = nil
        return interrupted
    }

    // MARK: Recovery

    /// What a launch-time sweep found.
    public struct RecoveryReport: Equatable, Sendable {
        public let sessionID: SessionID
        /// Bytes discarded from the end of the log — a partial write from a killed process.
        public let discardedBytes: Int
        public let recoveredEvents: Int
        public let sessionClass: SessionClass

        /// True when an assessment was interrupted, and therefore is not a valid assessment. Kept as
        /// its own flag because it is the one outcome a UI must not present as an ordinary recording.
        public var isIncompleteAssessment: Bool { sessionClass == .assessment }
    }

    /// Finds sessions left in `.recording` by a dead process, truncates their logs to the last valid
    /// frame, and marks them interrupted.
    ///
    /// Called once at launch. Truncation happens here and only here: reading a log never destroys
    /// anything, so a recording cannot lose bytes as a side effect of being opened.
    @discardableResult
    public func recoverInterrupted() throws -> [RecoveryReport] {
        var reports: [RecoveryReport] = []

        for summary in try catalogue.allSessions() where summary.state == .recording {
            // Skip the session this process is recording right now.
            if summary.id == active?.id { continue }

            let store = EventStore(url: eventLogURL(for: summary.id),
                                   sessionClass: summary.sessionClass,
                                   coding: coding)
            let discarded = (try? store.truncateToLastValidFrame()) ?? 0
            let events = (try? store.readAll().count) ?? 0

            guard let manifest = try? manifest(for: summary.id) else {
                // No manifest means no seed, which means nothing to replay. Recorded as a report so a
                // UI can offer to delete it rather than showing an unusable row forever.
                reports.append(RecoveryReport(sessionID: summary.id, discardedBytes: discarded,
                                              recoveredEvents: events,
                                              sessionClass: summary.sessionClass))
                continue
            }

            var session = Session(id: summary.id,
                                  origin: manifest.origin,
                                  seed: manifest.seed,
                                  ownerID: manifest.ownerID.storageKey,
                                  label: summary.label,
                                  state: .recording,
                                  tickCount: summary.tickCount)
            session = session.interrupted()
            try catalogue.upsert(SessionSummary(session: session, manifest: manifest,
                                                origin: summary.origin))

            reports.append(RecoveryReport(sessionID: summary.id, discardedBytes: discarded,
                                          recoveredEvents: events,
                                          sessionClass: summary.sessionClass))
        }
        return reports
    }

    // MARK: Reading

    public func manifest(for id: SessionID) throws -> SessionManifest {
        let primary = manifestURL(for: id)
        if let data = try? Data(contentsOf: primary),
           let manifest = try? SessionManifest.decode(data) {
            return manifest
        }
        // The backup exists precisely for this: a manifest lost is a session that can never be
        // replayed, whatever survives of its events.
        if let data = try? Data(contentsOf: manifestBackupURL(for: id)),
           let manifest = try? SessionManifest.decode(data) {
            return manifest
        }
        throw SessionManagerError.manifestMissing(id)
    }

    public func events(for id: SessionID) throws -> [Event] {
        let manifest = try manifest(for: id)
        return try EventStore(url: eventLogURL(for: id),
                              sessionClass: manifest.sessionClass,
                              coding: coding).readAll()
    }

    // MARK: Retention

    /// Which sessions the current policy would remove. Nothing is deleted.
    public func evictable(now: Date = Date()) throws -> [SessionSummary] {
        retention.evictable(from: try catalogue.allSessions(), now: now)
    }

    /// Applies the policy, deleting each session's directory and row.
    ///
    /// Separate from `evictable` so deletion is always a deliberate call, and so a UI can show what
    /// will go before it goes.
    @discardableResult
    public func applyRetention(now: Date = Date()) throws -> [SessionID] {
        var removed: [SessionID] = []
        for summary in try evictable(now: now) {
            try delete(summary.id)
            removed.append(summary.id)
        }
        return removed
    }

    /// Removes a session's data and its row.
    ///
    /// Refuses to delete the session being recorded — that would leave the recorder writing into a
    /// directory that no longer exists.
    public func delete(_ id: SessionID) throws {
        if id == active?.id { throw SessionManagerError.alreadyRecording(id) }
        try? FileManager.default.removeItem(at: directory(for: id))
        try catalogue.remove(id: id)
    }

    // MARK: Private

    private func record(_ session: Session) throws {
        let manifest = try manifest(for: session.id)
        let existing = try catalogue.summary(id: session.id)
        try catalogue.upsert(SessionSummary(session: session, manifest: manifest,
                                            origin: existing?.origin ?? .local))
    }
}
