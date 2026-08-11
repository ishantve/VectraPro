//
//  Session.swift
//  ATCReplayKit
//
//  What a recording is, and where it came from.
//
//  A session is identity and lineage. It holds no simulation state and no events — those live in the
//  event log — so it stays small enough to list two hundred of them without opening any.
//

import Foundation

public typealias SessionID = UUID
public typealias AssignmentID = UUID

// MARK: - Class

/// Whether a recording is a tool or evidence.
///
/// Not a cosmetic distinction. A training recording belongs to the trainee and exists to be learned
/// from; an assessment is a record *about* a person, and evidence carries obligations a tool does
/// not — it must be complete, sealed, and not re-scored behind the subject's back.
///
/// Set at creation and never changed. A training session cannot be promoted (its recording never met
/// the durability contract), and an assessment cannot be demoted (that would launder a bad result).
public enum SessionClass: String, Codable, Equatable, Sendable, CaseIterable {

    /// The trainee's own practice. Fork it freely; nothing here is evidence.
    case training

    /// A record about a person. Sealed on completion, flushed per event, never re-scored silently.
    case assessment

    /// Whether every event must reach disk before the next one is accepted.
    ///
    /// Batching a second of input is a reasonable trade for practice and is exactly the argument
    /// that fails at a hearing. At roughly a thousand events per session the I/O is a rounding
    /// error, so there is no trade to make.
    public var flushesEveryEvent: Bool { self == .assessment }

    /// Whether completing the session produces a seal over its contents.
    public var isSealedOnCompletion: Bool { self == .assessment }

    /// Whether a score recorded during the run outranks one recomputed later.
    ///
    /// For an assessment it does: re-deriving under new rules would change a person's result because
    /// the app updated, and change it invisibly.
    public var recordedScoreIsAuthoritative: Bool { self == .assessment }
}

// MARK: - Origin

/// Why this session exists — and, for an assessment, the authority that made it one.
///
/// This is the piece that makes `SessionClass` meaningful. If a trainee could simply choose to record
/// an "assessment", they could also choose not to share a bad one, and an instructor's list would be
/// a self-selected portfolio rather than an assessment record. An assessment the subject may withhold
/// is not an assessment.
///
/// So an assessment comes from an **assignment**: the instructor asking for it is what makes it one,
/// its share is implicit, and the trainee never had a withhold decision to make. Practice sessions
/// stay entirely the trainee's own — which matters, because a trainee who fears their practice will
/// be graded will practise less.
public enum SessionOrigin: Equatable, Sendable {

    /// The trainee started it themselves. Always `.training`.
    case selfDirected

    /// An instructor assigned it. Always `.assessment`, and shared with the assigning instructor on
    /// completion without the trainee being asked.
    case assignment(AssignmentID, assignedBy: String)

    /// Created by continuing from a paused replay. Always `.training`, whatever it was forked from —
    /// exploring "what if I had turned him earlier" is valuable, and must not be able to produce a
    /// second thing that looks like an assessment.
    case fork(from: SessionID, at: Int)

    /// The class this origin implies. Class is derived from origin, never chosen independently.
    public var sessionClass: SessionClass {
        switch self {
        case .assignment: return .assessment
        case .selfDirected, .fork: return .training
        }
    }

    /// The session this one diverged from, if any.
    public var parentID: SessionID? {
        if case .fork(let parent, _) = self { return parent }
        return nil
    }

    /// The tick it diverged at, if any.
    public var forkTick: Int? {
        if case .fork(_, let tick) = self { return tick }
        return nil
    }
}

// MARK: - State

/// Where a session is in its life.
///
/// One value rather than a set of booleans — see `SessionLifecycle` for the machine and for why. Every legal
/// move is enumerated there; an illegal one throws.
public enum SessionState: Equatable, Sendable {

    /// A manifest exists; no events yet.
    case created

    /// Accepting events.
    case recording

    /// A write failed and the exercise carried on. **Still recording** — the events already on disk are
    /// valid, and the recording is incomplete from that point. Cannot be sealed, so an incomplete
    /// assessment cannot pass for a finished one.
    case degraded(reason: String)

    /// Being torn down: flushing, and sealing if it is an assessment. Events are no longer accepted.
    ///
    /// A state rather than a moment, because sealing is real work and something has to describe a session
    /// that is neither recording nor finished.
    case stopping

    /// Finished, and not sealed. The terminal state for training.
    case completed

    /// Finished and sealed. The terminal state for an assessment.
    case sealed(digest: String)

    /// The process died mid-recording. Recoverable and replayable, but **an unsealed assessment is
    /// not a valid assessment** — it must be shown as incomplete rather than scored as though it ran
    /// to the end. Labelling that honestly matters more than salvaging the result.
    case interrupted

    /// Could not proceed at all — a manifest that would not write, storage that is unusable.
    ///
    /// Distinct from `degraded`: that has a partial recording worth keeping, this has nothing.
    case failed(reason: String)

    /// Superseded by a fork. The events after the fork point are kept, not deleted: comparing what
    /// the trainee did the first time against what they did the second is the whole value of
    /// branching for training.
    case superseded(by: SessionID, at: Int)

    /// Moved out of the way — compressed, or pushed to storage. Restorable.
    case archived

    /// Whether the log will take more events.
    ///
    /// True while degraded, because the exercise is still running: a further event may fail to write, and
    /// that is different from refusing to try.
    public var acceptsEvents: Bool {
        switch self {
        case .recording, .degraded: return true
        default:                    return false
        }
    }

    /// Whether a result from this session may be scored.
    ///
    /// `degraded` is excluded deliberately: part of the exercise was not recorded, so a replay cannot show
    /// what happened, and a grade nobody can check against the record is not a grade.
    public var isScoreable: Bool {
        switch self {
        case .sealed, .completed:
            return true
        case .created, .recording, .stopping, .degraded, .interrupted, .failed,
             .superseded, .archived:
            return false
        }
    }
}

// MARK: - Session

/// One recording's identity, lineage and state.
public struct Session: Equatable, Sendable, Identifiable {

    public let id: SessionID
    public let origin: SessionOrigin

    /// Derived from `origin`, stored so it survives a round trip and can be queried without
    /// re-deriving. `SessionOrigin.sessionClass` is the authority; this must always agree with it,
    /// which `init` guarantees and a test pins.
    public let sessionClass: SessionClass

    /// The root of every random choice the run makes. Shared with the whole fork lineage, so a
    /// branch's traffic continues its parent's rather than starting a different world.
    public let seed: UInt64

    /// Who recorded it. Ownership never transfers, even when the session is shared.
    public let ownerID: String

    /// A human label. Not identity.
    public var label: String

    public var state: SessionState

    /// Simulated ticks recorded so far. Kept on the session so a list can show durations without
    /// opening any event log.
    public var tickCount: Int

    public init(id: SessionID = UUID(),
                origin: SessionOrigin,
                seed: UInt64,
                ownerID: String,
                label: String = "",
                state: SessionState = .recording,
                tickCount: Int = 0) {
        self.id = id
        self.origin = origin
        self.sessionClass = origin.sessionClass
        self.seed = seed
        self.ownerID = ownerID
        self.label = label
        self.state = state
        self.tickCount = tickCount
    }

    // MARK: Queries

    public var parentID: SessionID? { origin.parentID }
    public var forkTick: Int? { origin.forkTick }
    public var isRoot: Bool { origin.parentID == nil }

    /// The assignment that made this an assessment, if any.
    public var assignmentID: AssignmentID? {
        if case .assignment(let id, _) = origin { return id }
        return nil
    }

    /// Whether this session is shared with its assigning instructor without being asked.
    ///
    /// True only for an assignment. Everything else is shared, or not, by its owner.
    public var isImplicitlyShared: Bool { assignmentID != nil }

    /// Whether a result here may be scored: a finished session, in a state that permits it, and —
    /// for an assessment — sealed.
    ///
    /// An unsealed assessment is deliberately excluded. It is still worth replaying and learning
    /// from; it is not worth grading.
    public var isScoreable: Bool {
        guard state.isScoreable else { return false }
        if sessionClass == .assessment, case .sealed = state { return true }
        return sessionClass == .training
    }

    // MARK: Transitions

    /// Ends the session, going through `stopping` as the machine requires.
    ///
    /// Throws on an illegal move rather than returning nil — see `Session.transitioned(to:)`. Kept as a
    /// convenience over the machine because ending a session is two moves and every caller wants both.
    public func finished(tickCount: Int? = nil, digest: String? = nil) throws -> Session {
        let stopping = try self.stopping(tickCount: tickCount ?? self.tickCount)
        return try stopping.completed(digest: digest)
    }

    /// Marks a session whose process died.
    ///
    /// Tolerant of an already-terminal state, and only this one is: the whole point is to describe an ending
    /// nobody chose, and a recovery sweep should not throw over a session that had already finished.
    public func interrupted() -> Session {
        (try? transitioned(to: .interrupted)) ?? self
    }

    /// Records that a fork now carries this session's future forward.
    ///
    /// The events after `tick` stay where they are. This marks the session as no longer the active
    /// line, not as deleted.
    public func superseded(by child: SessionID, at tick: Int) throws -> Session {
        try transitioned(to: .superseded(by: child, at: tick))
    }

    /// A new session continuing from `tick` of this one.
    ///
    /// Always `.training`, whatever this session is — see `SessionOrigin.fork`. It inherits the seed,
    /// so its traffic continues this world rather than starting a different one.
    public func forking(at tick: Int,
                        id: SessionID = UUID(),
                        label: String = "") -> Session {
        Session(id: id,
                origin: .fork(from: self.id, at: tick),
                seed: seed,
                ownerID: ownerID,
                label: label,
                tickCount: tick)
    }
}
