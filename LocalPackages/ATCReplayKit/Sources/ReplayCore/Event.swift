//
//  Event.swift
//  ReplayCore
//
//  The recorded causes. This is the only authoritative record of what happened.
//
//  ── What is an event ───────────────────────────────────────────────────────
//  A cause the simulation could not have worked out on its own. If the simulation can derive it, it
//  is not an event: an aircraft's position, a car's speed, a patient's vitals are all *outputs*,
//  recomputed by re-running the simulation, and recording them would make this a video recorder that
//  stores numbers instead of pixels — about two hundred times larger, and unable to answer "what was
//  that thing trying to do" when a replay is paused.
//
//  ── Why the core cannot say what a cause *is* ──────────────────────────────
//  Only the domain can. An event carries an `EventBody`: a tag the core routes on and a payload it
//  cannot read. Recording an instruction as its own vocabulary rather than as derived simulator
//  commands is a decision that outlives any one domain — a fix to the mapping from instruction to
//  behaviour should reach old recordings rather than being frozen into them, and recording the derived
//  commands would preserve yesterday's bug forever. Which vocabulary that is, though, is the adapter's
//  business: see `ATCReplayAdapter` for the reference one.
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

// MARK: - Timeline

/// What the user did to the timeline.
///
/// A platform vocabulary, not a domain one, and the reason it stays here: pause, resume, speed and seek mean
/// the same thing to a racing replay and a medical one, and recording them is how "this trainee paused
/// fourteen times" stays answerable. An adapter wraps it in a payload of its own so it gets a wire tag from
/// the domain that owns the numbers, but the vocabulary is the core's.
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

    /// What happened, as the domain said it — a tag the core routes on, and a payload it cannot read.
    ///
    /// Built by an adapter; see `EventBody`. Every function that produces one names a fact
    /// (`ATCEvent.commandIssued`), never a mechanism, which is why the representation underneath could change
    /// from a core enum to this box without a single call site moving.
    public let payload: EventBody

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
                payload: EventBody,
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

    /// Which kind of event this is, on the wire.
    ///
    /// Available without a codec, and that is the point: routing, indexing and the skip-or-apply decision are
    /// all answerable from the envelope, so a build that cannot decode a payload a newer build wrote can still
    /// replay the recording correctly.
    public var tag: EventTypeTag { payload.tag }
}
