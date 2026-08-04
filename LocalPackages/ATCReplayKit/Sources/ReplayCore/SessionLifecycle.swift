//
//  SessionLifecycle.swift
//  ATCReplayKit
//
//  A session's states and the transitions between them, written down as a machine.
//
//  ── Why a machine and not flags ─────────────────────────────────────────────
//  `isRecording`, `isSealed`, `didDegrade`, `wasInterrupted` as four booleans is sixteen combinations, of
//  which four are meaningful. The other twelve are not prevented by anything, and the ones that matter —
//  sealed *and* degraded, recording *and* completed — are exactly the ones that would let an incomplete
//  assessment pass for a finished one.
//
//  So the state is one value, and every legal move is enumerated. An illegal move throws, with both states
//  named, rather than being ignored or quietly applied. A session's state is the basis of whether a result
//  may be scored, so a wrong transition that nobody notices is a wrong grade that nobody notices.
//
//  ── Pause is deliberately not a state here ─────────────────────────────────
//  Pausing an exercise stops the simulation clock; it does not stop recording, and a paused session is
//  still recording — a `timelineAction(.paused)` event goes into the log, which is how "this trainee paused
//  fourteen times" is answerable later. Adding a `.paused` session state would mean two things had to agree
//  about pausing, and they would eventually disagree. Pause belongs to the clock.
//

import Foundation

// MARK: - Errors

public enum SessionStateError: Error, Equatable, CustomStringConvertible {

    /// The move is not in the machine.
    case illegalTransition(from: String, to: String)

    /// An assessment cannot complete without a seal, and a degraded recording cannot produce one.
    case sealRequired
    case cannotSealDegraded(reason: String)

    public var description: String {
        switch self {
        case .illegalTransition(let from, let to):
            return "a session cannot go from \(from) to \(to)"
        case .sealRequired:
            return "an assessment must be sealed to complete"
        case .cannotSealDegraded(let reason):
            return "a degraded recording cannot be sealed: \(reason)"
        }
    }
}

// MARK: - State

extension SessionState {

    /// A short name, for errors and for storage.
    public var name: String {
        switch self {
        case .created:     return "created"
        case .recording:   return "recording"
        case .stopping:    return "stopping"
        case .completed:   return "completed"
        case .sealed:      return "sealed"
        case .degraded:    return "degraded"
        case .interrupted: return "interrupted"
        case .failed:      return "failed"
        case .superseded:  return "superseded"
        case .archived:    return "archived"
        }
    }

    /// Whether the session is finished, however it finished.
    public var isTerminal: Bool {
        switch self {
        case .created, .recording, .stopping:
            return false
        case .completed, .sealed, .degraded, .interrupted, .failed, .superseded, .archived:
            return true
        }
    }
}

// MARK: - Transitions

/// What a session is allowed to do next.
///
/// A free function over the state rather than a method on `Session`, so the machine can be read in one place
/// and tested without a session.
public enum SessionLifecycle {

    /// The moves out of each state.
    ///
    /// Written as data rather than as a `switch` inside each transition, so the whole machine is visible at
    /// once — which is the difference between a lifecycle you can audit and one you have to trace.
    public static func canTransition(from current: SessionState, to next: SessionState) -> Bool {
        switch (current, next) {

        // A manifest exists; no events yet.
        case (.created, .recording),
             (.created, .failed):
            return true

        // Recording. Everything ends by way of `stopping`, except the endings nobody chose.
        case (.recording, .stopping),
             (.recording, .degraded),      // a write failed; the exercise carries on
             (.recording, .interrupted),   // the process died
             (.recording, .failed):
            return true

        // Degraded is still recording — the exercise continues, the recording is incomplete.
        case (.degraded, .stopping),
             (.degraded, .interrupted),
             (.degraded, .failed):
            return true

        // Flushing and sealing.
        case (.stopping, .completed),
             (.stopping, .sealed),
             (.stopping, .failed),
             (.stopping, .interrupted):
            return true

        // Finished sessions can be superseded by a fork, or archived.
        case (.completed, .superseded), (.sealed, .superseded), (.degraded, .superseded),
             (.interrupted, .superseded):
            return true

        // Superseded again, because a trainee exploring the same session twice is the ordinary case — and
        // the machine is what made this ambiguity visible.
        //
        // The parent can only name one supersessor, so this means "most recent fork". That is a display
        // convenience and **not** the lineage: the authoritative answer is `catalogue.children(of:)`, which
        // queries the children's own `parent_id`. Every fork is therefore recorded whatever this field says.
        case (.superseded, .superseded):
            return true
        case (.completed, .archived), (.sealed, .archived), (.degraded, .archived),
             (.interrupted, .archived), (.failed, .archived), (.superseded, .archived):
            return true

        // Restoring from an archive returns it to what it was; the caller supplies which.
        case (.archived, .completed), (.archived, .sealed), (.archived, .degraded),
             (.archived, .interrupted):
            return true

        // A degraded recording that stopped is still degraded — `stopping` records that it was being torn
        // down, and the recording's incompleteness outlives that.
        case (.stopping, .degraded):
            return true

        default:
            return false
        }
    }

    /// Every state a session in `current` may move to. For a UI that offers actions, and for the test that
    /// asserts the machine has no unreachable states.
    public static func allowedTransitions(from current: SessionState) -> [SessionState] {
        Self.representativeStates.filter { canTransition(from: current, to: $0) }
    }

    /// One example of each state, for enumerating the machine. The payloads are placeholders — the machine
    /// cares about which case, never about what it carries.
    public static let representativeStates: [SessionState] = [
        .created, .recording, .stopping, .completed, .sealed(digest: "…"),
        .degraded(reason: "…"), .interrupted, .failed(reason: "…"),
        .superseded(by: UUID(), at: 0), .archived,
    ]
}

// MARK: - Session

extension Session {

    /// Moves to `next`, or throws naming both states.
    ///
    /// Throws rather than trapping: an illegal transition usually comes from a UI doing something twice, and
    /// that should be reported and refused, not crash an exercise. Throws rather than returning nil, because
    /// nil at a call site invites `try?` and a silently skipped transition is the failure this machine exists
    /// to prevent.
    public func transitioned(to next: SessionState) throws -> Session {
        guard SessionLifecycle.canTransition(from: state, to: next) else {
            throw SessionStateError.illegalTransition(from: state.name, to: next.name)
        }
        var copy = self
        copy.state = next
        return copy
    }

    /// Begins recording.
    public func started() throws -> Session {
        try transitioned(to: .recording)
    }

    /// Begins teardown. Events are no longer accepted from here.
    public func stopping(tickCount: Int) throws -> Session {
        var copy = try transitioned(to: .stopping)
        copy.tickCount = tickCount
        return copy
    }

    /// Records that a write failed and the exercise continued.
    public func degraded(reason: String) throws -> Session {
        try transitioned(to: .degraded(reason: reason))
    }

    /// Finishes. An assessment needs a seal; a degraded recording cannot give one.
    ///
    /// The two refusals are separate errors because they mean different things to a caller: one is "you have
    /// not sealed it yet", the other is "this one can never be sealed".
    public func completed(digest: String?) throws -> Session {
        if case .degraded(let reason) = state, sessionClass == .assessment {
            throw SessionStateError.cannotSealDegraded(reason: reason)
        }
        switch (sessionClass, digest) {
        case (.assessment, let digest?): return try transitioned(to: .sealed(digest: digest))
        case (.assessment, nil):         throw SessionStateError.sealRequired
        case (.training, _):
            // A degraded training session stays degraded rather than claiming completion — the recording is
            // still incomplete, and saying otherwise would make it look replayable in full.
            if case .degraded = state { return self }
            return try transitioned(to: .completed)
        }
    }
}
