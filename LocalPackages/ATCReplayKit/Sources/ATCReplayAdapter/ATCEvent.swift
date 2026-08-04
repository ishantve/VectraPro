//
//  ATCEvent.swift
//  ATCReplayAdapter
//
//  How ATC events are constructed. The only sanctioned way.
//
//  ── This is an API, not a migration shim ───────────────────────────────────
//  It would have been cheaper to write a test helper, migrate the call sites, and delete it after R2b. That would
//  also have been the wrong thing: the reason 80 call sites had to change is precisely that they reached into
//  ReplayCore's payload vocabulary directly, and a helper that exists only to make the next commit smaller leaves
//  that habit intact for the next author.
//
//  So this is the adapter's construction API and it is meant to outlive the migration. Everything that makes an ATC
//  event — tests, fixture generation, the golden corpus, future tooling, and the recording path itself — goes
//  through here. After R2b-atomic the payload type underneath changes from a ReplayCore enum to an opaque body, and
//  **not one call site moves**. That property is the whole point, and it is only available because the call sites
//  name an intent ("a command was issued") rather than a representation.
//
//  ── Why free functions rather than an initialiser ──────────────────────────
//  An `Event` is core infrastructure: position, source, identity, tracing. What varies per domain is only the
//  payload, so extending `Event` with ATC initialisers would put ATC vocabulary on a core type — the exact coupling
//  this phase removes. A separate namespace keeps the direction right: the adapter builds core values, the core
//  never learns to build ATC ones.
//

import Foundation
import ReplayCore

/// Constructors for every ATC event.
///
/// One function per recorded fact, named for the fact rather than for its encoding. Parameter order is the same
/// throughout — what happened, then where in the session, then who caused it — so a reader of one call can predict
/// the others.
public enum ATCEvent {

    /// A controller instruction that was accepted.
    ///
    /// `callsign` is the aircraft **as resolved at the time**, not as spoken: resolution depends on who was on
    /// frequency then, which a replay cannot reconstruct and must not guess.
    public static func commandIssued(code: String,
                                     callsign: String,
                                     slots: [String: String],
                                     at position: EventPosition,
                                     source: EventSource = .system,
                                     correlationID: EventID? = nil,
                                     causationID: EventID? = nil,
                                     wallClock: Date? = nil) -> Event {
        Event(position: position,
              payload: .commandIssued(code: code, callsign: callsign, slots: slots),
              source: source, correlationID: correlationID,
              causationID: causationID, wallClock: wallClock)
    }

    /// A transmission that was understood but refused.
    ///
    /// Recorded because a refusal is something the trainee experienced; a replay that omits it is not what happened.
    public static func commandRejected(code: String?,
                                       callsign: String?,
                                       reason: String,
                                       at position: EventPosition,
                                       source: EventSource = .system,
                                       correlationID: EventID? = nil,
                                       causationID: EventID? = nil,
                                       wallClock: Date? = nil) -> Event {
        Event(position: position,
              payload: .commandRejected(code: code, callsign: callsign, reason: reason),
              source: source, correlationID: correlationID,
              causationID: causationID, wallClock: wallClock)
    }

    /// The raw transcript. Audit and parser-regression material — **not** an input to the simulation.
    public static func transcriptReceived(raw: String,
                                          normalized: String,
                                          at position: EventPosition,
                                          source: EventSource = .voice,
                                          correlationID: EventID? = nil,
                                          causationID: EventID? = nil,
                                          wallClock: Date? = nil) -> Event {
        Event(position: position,
              payload: .transcriptReceived(raw: raw, normalized: normalized),
              source: source, correlationID: correlationID,
              causationID: causationID, wallClock: wallClock)
    }

    /// What the pilot said back. Recorded so a replay speaks the same words rather than re-deriving them from a
    /// template set that may since have changed.
    public static func readbackSpoken(callsign: String,
                                      spoken: String,
                                      at position: EventPosition,
                                      source: EventSource = .system,
                                      correlationID: EventID? = nil,
                                      causationID: EventID? = nil,
                                      wallClock: Date? = nil) -> Event {
        Event(position: position,
              payload: .readbackSpoken(callsign: callsign, spoken: spoken),
              source: source, correlationID: correlationID,
              causationID: causationID, wallClock: wallClock)
    }

    /// Weather set by script or instructor, rather than derived from the seed. Feeds the simulation.
    public static func weatherChanged(windDegrees: Int? = nil,
                                      windKnots: Int? = nil,
                                      visibilityMetres: Int? = nil,
                                      qnh: Int? = nil,
                                      at position: EventPosition,
                                      source: EventSource = .system,
                                      correlationID: EventID? = nil,
                                      causationID: EventID? = nil,
                                      wallClock: Date? = nil) -> Event {
        Event(position: position,
              payload: .weatherChanged(windDegrees: windDegrees, windKnots: windKnots,
                                       visibilityMetres: visibilityMetres, qnh: qnh),
              source: source, correlationID: correlationID,
              causationID: causationID, wallClock: wallClock)
    }

    /// A score as computed at the time.
    ///
    /// `rulesVersion` is what makes it reproducible: for an assessment this value *is* the result, and a later
    /// recomputation may only be shown beside it — otherwise a trainee's score changes because the app updated.
    public static func scoreEvaluated(value: Int,
                                      rulesVersion: String,
                                      at position: EventPosition,
                                      source: EventSource = .system,
                                      correlationID: EventID? = nil,
                                      causationID: EventID? = nil,
                                      wallClock: Date? = nil) -> Event {
        Event(position: position,
              payload: .scoreEvaluated(value: value, rulesVersion: rulesVersion),
              source: source, correlationID: correlationID,
              causationID: causationID, wallClock: wallClock)
    }

    /// A timeline action the user took — pause, resume, speed, seek.
    ///
    /// In the record but not in the simulation's path: none of these change simulation state, and keeping them is
    /// what makes "this trainee paused fourteen times" answerable.
    public static func timeline(_ action: TimelineAction,
                               at position: EventPosition,
                               source: EventSource = .system,
                               correlationID: EventID? = nil,
                               causationID: EventID? = nil,
                               wallClock: Date? = nil) -> Event {
        Event(position: position,
              payload: .timelineAction(action),
              source: source, correlationID: correlationID,
              causationID: causationID, wallClock: wallClock)
    }
}
