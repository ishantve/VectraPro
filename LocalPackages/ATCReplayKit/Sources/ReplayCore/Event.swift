//
//  Event.swift
//  ATCReplayKit
//
//  The recorded causes. This is the only authoritative record of what happened.
//
//  ── What is an event ───────────────────────────────────────────────────────
//  A cause the simulation could not have worked out on its own. If the simulation can derive it, it
//  is not an event: aircraft positions, headings, speeds and altitudes are all *outputs*, recomputed
//  by re-running the simulation, and recording them would make this a video recorder that stores
//  numbers instead of pixels — about two hundred times larger, and unable to answer "what was that
//  aircraft trying to do" when a replay is paused.
//
//  ── Why a code and not a command ───────────────────────────────────────────
//  A controller instruction is recorded as its phraseology **code** and slot values, not as the
//  simulator commands it maps to. Two reasons, and the second is the important one:
//
//    • it keeps this package free of the simulation engine, so it stays portable;
//    • the mapping from code to aircraft behaviour is the simulator's job, and a *fix* to that
//      mapping should reach old recordings rather than being frozen into them. Recording the derived
//      commands would preserve yesterday's bug forever.
//

import Foundation

// MARK: - Ordering

/// Where an event sits in a session.
///
/// `tick` alone is **not** a unique key and must never be used as one. Several inputs routinely
/// arrive within one tick — "climb FL260, speed 300, turn right 250" is one transmission and three
/// commands — so order needs the pair. `ordinal` is assigned by the single gateway every input passes
/// through, which is what makes it gap-free and race-free.
public struct EventPosition: Equatable, Hashable, Comparable, Codable, Sendable {

    public let tick: Int
    public let ordinal: UInt32

    public init(tick: Int, ordinal: UInt32) {
        self.tick = tick
        self.ordinal = ordinal
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.tick, lhs.ordinal) < (rhs.tick, rhs.ordinal)
    }
}

// MARK: - Payload

/// What happened.
///
/// Cases are added, never renumbered or repurposed: a recording outlives the code that wrote it, and
/// a retired case stays retired. `EventKind` carries the stable wire discriminator.
public enum EventPayload: Equatable, Sendable {

    /// A controller instruction, as phraseology rather than as simulator commands.
    ///
    /// - Parameters:
    ///   - code: the phraseology `abbreviationCode`. The key everything downstream acts on.
    ///   - callsign: the aircraft addressed, as resolved at the time. Recorded resolved rather than
    ///     as spoken, because resolution depends on who was on frequency then — which a replay
    ///     cannot reconstruct and should not have to guess.
    ///   - slots: the values pulled from the transmission, in template order.
    case commandIssued(code: String, callsign: String, slots: [String: String])

    /// A transmission that was understood but refused, and why. Recorded because a refusal is a
    /// thing the trainee experienced, and a replay that silently omits it is not what happened.
    case commandRejected(code: String?, callsign: String?, reason: String)

    /// The raw transcript, for audit and for parser regression work.
    ///
    /// **Not an input to the simulation** — the simulation acts on `commandIssued`. Kept separate so
    /// improving the parser cannot change what a stored session did.
    case transcriptReceived(raw: String, normalized: String)

    /// What the pilot said back. Presentation, recorded so a replay can speak the same words rather
    /// than re-deriving them from a template set that may since have changed.
    case readbackSpoken(callsign: String, spoken: String)

    /// Weather changed by script or instructor, rather than derived from the seed.
    case weatherChanged(windDegrees: Int?, windKnots: Int?, visibilityMetres: Int?, qnh: Int?)

    /// A score evaluation as computed at the time.
    ///
    /// `rulesVersion` is what makes it reproducible. For an assessment this value is the result and
    /// a later recomputation may only be shown beside it — otherwise a trainee's score changes
    /// because the app updated, invisibly.
    case scoreEvaluated(value: Int, rulesVersion: String)

    /// The user's own timeline actions — pause, resume, speed, seek.
    ///
    /// Kept so a *session* can be reproduced and so "this trainee paused fourteen times" is
    /// answerable. Deliberately in the record but not in the simulation's path: none of these change
    /// simulation state.
    case timelineAction(TimelineAction)

    public var kind: EventKind {
        switch self {
        case .commandIssued:       return .commandIssued
        case .commandRejected:     return .commandRejected
        case .transcriptReceived:  return .transcriptReceived
        case .readbackSpoken:      return .readbackSpoken
        case .weatherChanged:      return .weatherChanged
        case .scoreEvaluated:      return .scoreEvaluated
        case .timelineAction:      return .timelineAction
        }
    }

    /// Whether replaying the simulation needs this event.
    ///
    /// The rest are annotations: real records of what happened, but not causes the simulation
    /// consumes. Separating them is what lets a replay skip audio and still be correct.
    public var affectsSimulation: Bool {
        switch self {
        case .commandIssued, .weatherChanged:
            return true
        case .commandRejected, .transcriptReceived, .readbackSpoken,
             .scoreEvaluated, .timelineAction:
            return false
        }
    }
}

/// Stable wire discriminators. **Never renumber a case.** A stored recording refers to these by
/// number, so changing one silently reinterprets old data.
public enum EventKind: UInt16, Codable, Equatable, Sendable, CaseIterable {
    case commandIssued      = 1
    case commandRejected    = 2
    case transcriptReceived = 3
    case readbackSpoken     = 4
    case weatherChanged     = 5
    case scoreEvaluated     = 6
    case timelineAction     = 7
}

/// What the user did to the timeline.
public enum TimelineAction: Equatable, Sendable, Codable {
    case paused
    case resumed
    case speedChanged(to: Int)
    case seeked(to: Int)
    case replayStarted
    case replayStopped
}

// MARK: - Event

/// One recorded fact, at one position in one session.
public struct Event: Equatable, Sendable {

    public let position: EventPosition
    public let payload: EventPayload

    /// Where this came from — see `EventSource`.
    ///
    /// On every event rather than only on the ones that obviously have a human behind them, and in the
    /// envelope rather than the payload, for the same reason `tick` and `ordinal` are: it can then be
    /// read and filtered without decoding — or being able to decode — a payload a newer build wrote.
    ///
    /// Never used for ordering or for replay. It answers questions asked *about* a session.
    public let source: EventSource

    /// The chain this event belongs to — the `eventID` of whatever started it.
    ///
    /// One transmission produces several events: a transcript, two or three commands, a readback. They
    /// share a correlation, so "everything that came of that instruction" is one query rather than a
    /// reconstruction from ticks and guesswork.
    ///
    /// An `EventID` rather than a new kind of identifier, so the chain's root names itself and no second
    /// id space has to be kept unique. Optional, and unpopulated for now.
    ///
    /// **Not for ordering, and not for replay.** A replay that consulted this would be deriving causality
    /// from a hint rather than from the simulation.
    public let correlationID: EventID?

    /// The event that directly caused this one.
    ///
    /// `correlationID` names the root of a chain; this names the immediate parent, so a chain can be
    /// walked as a tree rather than only as a set. An AI decision chain and a command's consequences are
    /// both trees, and flattening them loses the part worth debugging.
    ///
    /// Optional, and unpopulated for now.
    public let causationID: EventID?

    /// Real time, for audit only.
    ///
    /// **Nothing inside the simulation may read this.** It answers "how long did the trainee take to
    /// respond", which is a genuine assessment question, while being structurally incapable of
    /// affecting a replay — a rule that is enforceable in review precisely because the field is here
    /// and named.
    public let wallClock: Date?

    public init(position: EventPosition,
                payload: EventPayload,
                source: EventSource = .system,
                correlationID: EventID? = nil,
                causationID: EventID? = nil,
                wallClock: Date? = nil) {
        self.position = position
        self.payload = payload
        self.source = source
        self.correlationID = correlationID
        self.causationID = causationID
        self.wallClock = wallClock
    }

    /// A copy attributed to a chain.
    ///
    /// Here rather than making the fields mutable: an event is a record of something that happened, and
    /// the only legitimate reason to change one is that the caller knows the chain the moment after
    /// constructing it. A copy makes that explicit and keeps the type immutable.
    public func caused(by parent: EventID, correlation: EventID? = nil) -> Event {
        Event(position: position, payload: payload, source: source,
              correlationID: correlation ?? correlationID ?? parent,
              causationID: parent, wallClock: wallClock)
    }

    public var tick: Int { position.tick }
    public var ordinal: UInt32 { position.ordinal }
    public var kind: EventKind { payload.kind }
}
