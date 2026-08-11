//
//  ATCPayload.swift
//  ATCReplayAdapter
//
//  What an ATC event says. The vocabulary itself, and the wire tags that name its kinds.
//
//  ── Why this is here and not in ReplayCore ─────────────────────────────────
//  Because it is about aeroplanes. Every case names something only air traffic control has: a phraseology
//  code, a callsign, a readback, a QNH. A replay platform that knew these words could not record a race, a
//  surgery or a robot, and the seven cases below are the whole reason it could not. R2b-atomic moved them.
//
//  ── Cases are added, never renumbered or repurposed ─────────────────────────
//  A recording outlives the code that wrote it, and a retired case stays retired. The numbers in
//  `EventTypeTag` below are **on disk, in every recording ever made by this app**. Changing one does not
//  break a build; it silently reinterprets history, which is worse. They are this adapter's permanent
//  responsibility — the core reserves none and cannot help.
//
//  ── The encoding is written out by hand ─────────────────────────────────────
//  Rather than left to Swift's synthesised enum `Codable`, which keys on Swift case and parameter *names*:
//  renaming a parameter — a refactor with no intent behind it — would silently stop old recordings decoding.
//  The mapping between names and bytes has to be a decision, written down, and only ever added to.
//
//  Rules for changing this file:
//    • new fields are optional, and absent means "was not recorded", never a default that looks real
//    • tag numbers are never reused
//    • a field's meaning never changes; a new meaning is a new field, and a new shape is a new
//      `eventVersion` plus a migration in `ATCEventCodec`
//

import Foundation
import ReplayCore

// MARK: - Wire tags

public extension EventTypeTag {

    // ATC's wire discriminators, 1…7. Declared here because the adapter owns them permanently.
    //
    // As an extension on the core's tag type rather than an enum of our own, for the reason `EventSource` is
    // a struct: a reader that meets a tag it does not know must still be able to read the envelope, and an
    // enum would refuse the whole event. The `.commandIssued` shorthand still works at a call site.

    static let commandIssued      = EventTypeTag(1)
    static let commandRejected    = EventTypeTag(2)
    static let transcriptReceived = EventTypeTag(3)
    static let readbackSpoken     = EventTypeTag(4)
    static let weatherChanged     = EventTypeTag(5)
    static let scoreEvaluated     = EventTypeTag(6)
    static let timelineAction     = EventTypeTag(7)
}

// MARK: - Payload

/// What happened, in ATC's own terms.
public enum ATCPayload: Equatable, Sendable {

    /// A controller instruction, as phraseology rather than as simulator commands.
    ///
    /// Recorded as a code and slots, not as the `AircraftCommand`s it maps to, for two reasons and the second
    /// is the important one: it keeps a recording free of the simulation engine, and the mapping from code to
    /// aircraft behaviour is the simulator's job — a *fix* to that mapping should reach old recordings rather
    /// than being frozen into them. Recording the derived commands would preserve yesterday's bug forever.
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
    /// `TimelineAction` is ReplayCore's: pausing and scrubbing mean the same thing to every simulation. It
    /// gets a *tag* here because tags are a domain's property, so this case is a domain wrapper around a
    /// platform vocabulary rather than either one leaking into the other.
    ///
    /// Kept so a *session* can be reproduced and so "this trainee paused fourteen times" is answerable.
    /// Deliberately in the record but not in the simulation's path: none of these change simulation state.
    case timelineAction(TimelineAction)

    /// Which kind this is, on the wire.
    public var tag: EventTypeTag {
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

    /// The body an `Event` carries, tagged and opaque to the core.
    ///
    /// Internal: an ATC event is built through `ATCEvent`, whose functions name facts. Exposing a boxing
    /// step publicly would put replay mechanics back into the adapter's public API, which is the habit
    /// `ATCEvent` exists to keep out.
    var body: EventBody { EventBody(tag: tag, self) }
}

// MARK: - Coding

extension ATCPayload: Codable {

    private enum CodingKeys: String, CodingKey {
        case kind
        case code, callsign, slots, reason
        case raw, normalized, spoken
        case windDegrees, windKnots, visibilityMetres, qnh
        case value, rulesVersion
        case action
    }

    /// The discriminator, spelled as the raw `UInt16` it has always been on the wire.
    ///
    /// Explicit rather than encoding the tag as a value, because whether a `RawRepresentable` struct encodes
    /// as a bare number or as an object is a detail of how its conformance is derived — and this byte is the
    /// one every stored recording is read by. It is written here only so `EventPayload`'s hand-written decoder
    /// can find it; `ATCEventCodec` strips it before the object reaches the wire, where the tag lives in the
    /// envelope instead.
    static let discriminatorKey = "kind"

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag.rawValue, forKey: .kind)

        switch self {
        case .commandIssued(let code, let callsign, let slots):
            try container.encode(code, forKey: .code)
            try container.encode(callsign, forKey: .callsign)
            try container.encode(slots, forKey: .slots)

        case .commandRejected(let code, let callsign, let reason):
            try container.encodeIfPresent(code, forKey: .code)
            try container.encodeIfPresent(callsign, forKey: .callsign)
            try container.encode(reason, forKey: .reason)

        case .transcriptReceived(let raw, let normalized):
            try container.encode(raw, forKey: .raw)
            try container.encode(normalized, forKey: .normalized)

        case .readbackSpoken(let callsign, let spoken):
            try container.encode(callsign, forKey: .callsign)
            try container.encode(spoken, forKey: .spoken)

        case .weatherChanged(let windDegrees, let windKnots, let visibility, let qnh):
            try container.encodeIfPresent(windDegrees, forKey: .windDegrees)
            try container.encodeIfPresent(windKnots, forKey: .windKnots)
            try container.encodeIfPresent(visibility, forKey: .visibilityMetres)
            try container.encodeIfPresent(qnh, forKey: .qnh)

        case .scoreEvaluated(let value, let rulesVersion):
            try container.encode(value, forKey: .value)
            try container.encode(rulesVersion, forKey: .rulesVersion)

        case .timelineAction(let action):
            try container.encode(action, forKey: .action)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = EventTypeTag(rawValue: try container.decode(UInt16.self, forKey: .kind))

        switch tag {
        case .commandIssued:
            self = .commandIssued(
                code: try container.decode(String.self, forKey: .code),
                callsign: try container.decode(String.self, forKey: .callsign),
                // Absent rather than empty in older recordings; empty is the honest reading.
                slots: try container.decodeIfPresent([String: String].self, forKey: .slots) ?? [:])

        case .commandRejected:
            self = .commandRejected(
                code: try container.decodeIfPresent(String.self, forKey: .code),
                callsign: try container.decodeIfPresent(String.self, forKey: .callsign),
                reason: try container.decode(String.self, forKey: .reason))

        case .transcriptReceived:
            self = .transcriptReceived(
                raw: try container.decode(String.self, forKey: .raw),
                normalized: try container.decode(String.self, forKey: .normalized))

        case .readbackSpoken:
            self = .readbackSpoken(
                callsign: try container.decode(String.self, forKey: .callsign),
                spoken: try container.decode(String.self, forKey: .spoken))

        case .weatherChanged:
            self = .weatherChanged(
                windDegrees: try container.decodeIfPresent(Int.self, forKey: .windDegrees),
                windKnots: try container.decodeIfPresent(Int.self, forKey: .windKnots),
                visibilityMetres: try container.decodeIfPresent(Int.self, forKey: .visibilityMetres),
                qnh: try container.decodeIfPresent(Int.self, forKey: .qnh))

        case .scoreEvaluated:
            self = .scoreEvaluated(
                value: try container.decode(Int.self, forKey: .value),
                rulesVersion: try container.decode(String.self, forKey: .rulesVersion))

        case .timelineAction:
            self = .timelineAction(try container.decode(TimelineAction.self, forKey: .action))

        // A tag this build has never heard of — written by a newer release, or by another domain's adapter
        // into a log this one was pointed at. Not a switch the compiler can check any more, which is the price
        // of a tag type that can hold a value from the future; the price is worth paying, because the envelope
        // stays readable and only this payload is lost rather than the whole recording.
        default:
            throw EventSchemaError.malformed("no ATC payload is registered for \(tag)")
        }
    }
}
