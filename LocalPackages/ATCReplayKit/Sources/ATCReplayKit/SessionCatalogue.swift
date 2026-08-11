//
//  SessionCatalogue.swift
//  ATCReplayKit
//
//  The list. Every session's metadata, so a trainee with two hundred recordings can browse them
//  without opening any.
//
//  ── Why a protocol, and why the SQLite version lives elsewhere ──────────────
//  The catalogue is the one part of this package that wants a database: it answers queries (mine,
//  shared with me, this lineage) and it wants transactions. But SQLite would tie the package to a
//  platform library, and the rest of it — sessions, events, manifests — is Foundation-only so it can
//  carry a C interface.
//
//  So the interface is here and the SQLite implementation is a separate target. Which also means the
//  managers are testable against an in-memory catalogue rather than a temporary file, and a test that
//  does not touch a disk is a test that does not fail for reasons of its own.
//

import Foundation

// MARK: - Row

/// One session, as the list needs it.
///
/// A flat copy of what a list renders. Deliberately not the `Session` value plus a join: an
/// instructor's list has to show a session's *validity* — sealed, unsealed, wrong architecture, older
/// build — before they spend twenty minutes reviewing something unscoreable, and that answer comes
/// from the manifest. Denormalising it here is what keeps listing cheap.
public struct SessionSummary: Equatable, Sendable, Identifiable {

    public let id: SessionID
    public let ownerID: OwnerID
    public let sessionClass: SessionClass
    public let state: SessionState
    public let label: String

    /// Lineage, so a branch tree can be drawn without reading any manifest.
    public let parentID: SessionID?
    public let forkTick: Int?

    public let seed: UInt64
    public let tickCount: Int
    public let createdAt: Date

    public let exerciseName: String?
    public let exerciseDigest: String
    public let assignmentID: AssignmentID?

    /// Environment facts, for the validity badge.
    public let manifestVersion: Int
    public let buildVersion: String
    public let architecture: String

    /// Whether this row came from this device or arrived from someone else.
    public let origin: StorageOrigin

    public enum StorageOrigin: String, Codable, Equatable, Sendable {
        case local
        case received
    }

    public init(id: SessionID,
                ownerID: OwnerID,
                sessionClass: SessionClass,
                state: SessionState,
                label: String,
                parentID: SessionID?,
                forkTick: Int?,
                seed: UInt64,
                tickCount: Int,
                createdAt: Date,
                exerciseName: String?,
                exerciseDigest: String,
                assignmentID: AssignmentID?,
                manifestVersion: Int,
                buildVersion: String,
                architecture: String,
                origin: StorageOrigin = .local) {
        self.id = id
        self.ownerID = ownerID
        self.sessionClass = sessionClass
        self.state = state
        self.label = label
        self.parentID = parentID
        self.forkTick = forkTick
        self.seed = seed
        self.tickCount = tickCount
        self.createdAt = createdAt
        self.exerciseName = exerciseName
        self.exerciseDigest = exerciseDigest
        self.assignmentID = assignmentID
        self.manifestVersion = manifestVersion
        self.buildVersion = buildVersion
        self.architecture = architecture
        self.origin = origin
    }

    /// Built from a session and its manifest, which is the only way the two can be guaranteed to
    /// agree.
    public init(session: Session, manifest: SessionManifest, origin: StorageOrigin = .local) {
        self.init(id: session.id,
                  ownerID: manifest.ownerID,
                  sessionClass: session.sessionClass,
                  state: session.state,
                  label: session.label,
                  parentID: session.parentID,
                  forkTick: session.forkTick,
                  seed: session.seed,
                  tickCount: session.tickCount,
                  createdAt: manifest.createdAt,
                  exerciseName: manifest.exercise.exerciseName,
                  exerciseDigest: manifest.exercise.digest,
                  assignmentID: manifest.assignmentID,
                  manifestVersion: manifest.manifestVersion,
                  buildVersion: manifest.environment.buildVersion,
                  architecture: manifest.environment.architecture,
                  origin: origin)
    }

    /// A copy with only the fields that change over a session's life changed.
    ///
    /// What a session *is* — its seed, its owner, its class, the exercise it ran, the environment that
    /// computed it — is settled when recording starts. What changes is where it got to and what it is
    /// called. Making that distinction a method rather than a convention is what stops a later write
    /// quietly rewriting which world a session was recorded in.
    public func updated(state: SessionState,
                        label: String? = nil,
                        tickCount: Int? = nil,
                        origin: StorageOrigin? = nil) -> SessionSummary {
        SessionSummary(id: id,
                       ownerID: ownerID,
                       sessionClass: sessionClass,
                       state: state,
                       label: label ?? self.label,
                       parentID: parentID,
                       forkTick: forkTick,
                       seed: seed,
                       tickCount: tickCount ?? self.tickCount,
                       createdAt: createdAt,
                       exerciseName: exerciseName,
                       exerciseDigest: exerciseDigest,
                       assignmentID: assignmentID,
                       manifestVersion: manifestVersion,
                       buildVersion: buildVersion,
                       architecture: architecture,
                       origin: origin ?? self.origin)
    }

    // MARK: Validity

    /// Whether a replay here can be compared against the original run.
    ///
    /// Architecture must match; the build need not. Phase 0 measured arm64 and x86_64 to agree, so
    /// this will normally be true — but it is checked rather than assumed, because that measurement
    /// describes today's toolchain and a recording outlives it.
    public func isReproducible(on environment: RecordingEnvironment) -> Bool {
        architecture == environment.architecture
    }

    /// Whether a result here may be scored, given where it is being reviewed.
    ///
    /// Three conditions, and each rules out a real situation: the session finished properly, an
    /// assessment was sealed, and this machine computes the simulation the same way. An assessment
    /// reviewed on a machine that computes differently is not what the trainee flew.
    public func isScoreable(on environment: RecordingEnvironment) -> Bool {
        guard isReproducible(on: environment) else { return false }
        switch state {
        case .sealed:    return true
        case .completed: return sessionClass == .training
        case .created, .recording, .stopping, .degraded, .interrupted, .failed,
             .superseded, .archived:
            return false
        }
    }

    /// Why it cannot be scored, for the UI to show up front.
    public func unscoreableReason(on environment: RecordingEnvironment) -> String? {
        if isScoreable(on: environment) { return nil }
        switch state {
        case .created:     return "Not started"
        case .recording:   return "Still recording"
        case .stopping:    return "Finishing"
        case .degraded(let reason):
            return "Part of this exercise was not recorded — \(reason)"
        case .interrupted: return sessionClass == .assessment
            ? "Interrupted before it was sealed — not a complete assessment"
            : "Interrupted"
        case .failed(let reason): return "Recording failed — \(reason)"
        case .superseded:  return "Superseded by a branch"
        case .archived:    return "Archived"
        case .completed where sessionClass == .assessment:
            return "Not sealed"
        default: break
        }
        if architecture != environment.architecture {
            return "Recorded on \(architecture); this device is \(environment.architecture)"
        }
        return "Not scoreable"
    }
}

// MARK: - Catalogue

public enum CatalogueError: Error, Equatable {
    case notFound(SessionID)
    case storageFailure(String)
}

/// Session metadata storage.
///
/// Holds no event or snapshot bytes — those live in the session's own directory. This is the index
/// over them, and it is rebuildable from the manifests if it is ever lost.
public protocol SessionCatalogue: AnyObject {

    func upsert(_ summary: SessionSummary) throws
    func summary(id: SessionID) throws -> SessionSummary?
    func remove(id: SessionID) throws

    /// A trainee's own sessions, newest first.
    func sessions(ownedBy owner: OwnerID) throws -> [SessionSummary]

    /// Sessions that arrived from someone else — the instructor's "Shared with me".
    func receivedSessions() throws -> [SessionSummary]

    /// Everything, newest first. For maintenance and retention rather than for a screen.
    func allSessions() throws -> [SessionSummary]

    /// The direct children of a session — one step of the branch tree, not the whole subtree, so a
    /// caller can expand it lazily.
    func children(of parent: SessionID) throws -> [SessionSummary]
}

// MARK: - In-memory

/// A catalogue that forgets. For tests, and for a first run before any storage exists.
///
/// Sorting is duplicated between this and the SQLite version, which is a real (small) risk of
/// divergence — so the ordering contract is asserted against *both* by the same shared test.
public final class InMemorySessionCatalogue: SessionCatalogue {

    private var rows: [SessionID: SessionSummary] = [:]

    public init() {}

    /// Inserts, or updates only the fields that may change.
    ///
    /// The immutable set is preserved rather than overwritten — the same rule the SQL implementation
    /// enforces through its `DO UPDATE SET` column list. A shared contract test caught these two
    /// disagreeing, which is exactly why that test runs against both.
    public func upsert(_ summary: SessionSummary) throws {
        guard let existing = rows[summary.id] else {
            rows[summary.id] = summary
            return
        }
        rows[summary.id] = existing.updated(state: summary.state,
                                            label: summary.label,
                                            tickCount: summary.tickCount,
                                            origin: summary.origin)
    }
    public func summary(id: SessionID) throws -> SessionSummary? { rows[id] }
    public func remove(id: SessionID) throws { rows[id] = nil }

    public func sessions(ownedBy owner: OwnerID) throws -> [SessionSummary] {
        sorted(rows.values.filter { $0.ownerID == owner && $0.origin == .local })
    }

    public func receivedSessions() throws -> [SessionSummary] {
        sorted(rows.values.filter { $0.origin == .received })
    }

    public func allSessions() throws -> [SessionSummary] {
        sorted(rows.values)
    }

    public func children(of parent: SessionID) throws -> [SessionSummary] {
        sorted(rows.values.filter { $0.parentID == parent })
    }

    /// Newest first, and **tie-broken by id**. Two sessions can share a timestamp — a fork is created
    /// in the same instant as its parent is superseded — and a dictionary's values have no order, so
    /// without the tiebreak the same list could come back in a different order each call.
    private func sorted(_ values: some Collection<SessionSummary>) -> [SessionSummary] {
        values.sorted {
            ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString)
        }
    }
}
