//
//  BranchManager.swift
//  ATCReplayKit
//
//  Forking a session at a tick.
//
//  This is the shortest file in the package, and that is the whole point of the architecture. Because
//  a recording holds *causes* rather than state, a branch is a parent id, a fork tick and a new event
//  log. Nothing is copied — not state, not events. Had we recorded positions instead, a branch would
//  mean duplicating a session.
//
//  ── Two rules the type enforces ────────────────────────────────────────────
//  A fork is always `.training`, whatever it forked from. A trainee replaying their assessment and
//  pressing continue is genuinely useful — "what if I had turned him earlier" is the question the
//  feature exists for — but it must never be able to produce a second thing that looks like the
//  assessment.
//
//  The parent's future is **kept**. It is marked superseded, not truncated. Comparing what the trainee
//  did the first time against the second is the entire value of branching for training; deleting the
//  original future would throw away the comparison the feature exists to enable.
//

import Foundation

public enum BranchError: Error, Equatable {
    case parentNotFound(SessionID)
    /// A fork point beyond where the parent ever got to. There is no state there to continue from.
    case forkTickBeyondParent(tick: Int, parentTicks: Int)
    case negativeForkTick(Int)
}

public final class BranchManager {

    private let sessions: SessionManager

    public init(sessions: SessionManager) {
        self.sessions = sessions
    }

    /// Creates a session continuing from `tick` of `parent`, and marks the parent superseded.
    ///
    /// The new session inherits the parent's seed and exercise, so its traffic continues the same
    /// world rather than starting a different one at the fork point. It inherits the parent's *owner*
    /// too: a fork is the same person exploring their own session.
    ///
    /// The caller is expected to already hold the simulation state at `tick` — it got there by
    /// replaying — so there is nothing to restore here. That absence is the design working.
    public func fork(_ parentID: SessionID,
                     at tick: Int,
                     label: String = "",
                     now: Date = Date(),
                     id: SessionID = UUID()) throws -> Session {

        guard tick >= 0 else { throw BranchError.negativeForkTick(tick) }

        guard let parentSummary = try sessions.catalogue.summary(id: parentID) else {
            throw BranchError.parentNotFound(parentID)
        }
        guard tick <= parentSummary.tickCount else {
            throw BranchError.forkTickBeyondParent(tick: tick,
                                                   parentTicks: parentSummary.tickCount)
        }

        let parentManifest = try sessions.manifest(for: parentID)

        // Started before the parent is marked, so a failure here leaves the parent untouched rather
        // than superseded by a session that does not exist.
        let child = try sessions.start(origin: .fork(from: parentID, at: tick),
                                      seed: parentManifest.seed,
                                      owner: parentManifest.ownerID,
                                      exercise: parentManifest.exercise,
                                      label: label,
                                      now: now,
                                      id: id)

        try markSuperseded(parentSummary, by: child.id, at: tick, manifest: parentManifest)
        return child
    }

    /// The branch tree rooted at `id`, breadth-first.
    ///
    /// Lazily one level at a time via the catalogue, so a deep lineage does not have to be loaded to
    /// draw its first level.
    public func descendants(of id: SessionID) throws -> [SessionSummary] {
        var found: [SessionSummary] = []
        var queue = try sessions.catalogue.children(of: id)
        // A cycle should be impossible — a fork's parent always predates it — but a corrupted
        // catalogue should not hang the app.
        var seen: Set<SessionID> = [id]

        while let next = queue.first {
            queue.removeFirst()
            guard seen.insert(next.id).inserted else { continue }
            found.append(next)
            queue += try sessions.catalogue.children(of: next.id)
        }
        return found
    }

    /// The chain from a root down to `id`, oldest first.
    public func lineage(of id: SessionID) throws -> [SessionSummary] {
        var chain: [SessionSummary] = []
        var current: SessionID? = id
        var seen: Set<SessionID> = []

        while let next = current, seen.insert(next).inserted {
            guard let summary = try sessions.catalogue.summary(id: next) else { break }
            chain.append(summary)
            current = summary.parentID
        }
        return chain.reversed()
    }

    // MARK: - Private

    private func markSuperseded(_ summary: SessionSummary,
                                by child: SessionID,
                                at tick: Int,
                                manifest: SessionManifest) throws {
        let parent = Session(id: summary.id,
                             origin: manifest.origin,
                             seed: manifest.seed,
                             ownerID: manifest.ownerID.storageKey,
                             label: summary.label,
                             state: summary.state,
                             tickCount: summary.tickCount)
        try sessions.catalogue.upsert(
            SessionSummary(session: parent.superseded(by: child, at: tick),
                          manifest: manifest,
                          origin: summary.origin))
    }
}
