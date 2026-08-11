//
//  ATCEventCodec.swift
//  ATCReplayAdapter
//
//  ATC's half of the coding contract: what a payload becomes on the wire, how far forward to bring an old
//  one, and which kinds a replay must actually apply.
//
//  ── The split this type sits on ─────────────────────────────────────────────
//  `EventPayloadCoding` is ReplayCore's routing contract, expressed only in tags, bodies and JSON objects —
//  it names no ATC noun and could not. This type is the other half: the same four questions answered in
//  ATC's own vocabulary, over `ATCPayload`, with the boxing and unboxing at the boundary between them.
//
//  The typed functions are the real implementation and are public in their own right, because a caller who
//  has an `ATCPayload` should not have to launder it through an `EventBody` to encode it. The protocol
//  conformance is a thin bridge over them.
//
//  ── `affectsSimulation` is the most dangerous value in the platform ─────────
//  Wrong here and a replay silently skips a real instruction, or applies an annotation the trainee only heard.
//  It is answered **by tag** and never by a decoded payload, so a build that cannot decode a payload a newer
//  release wrote can still route the recording correctly — the property the design paid for deliberately.
//  `GoldenCorpusTests.testWhichTagsAffectTheSimulationIsFrozen` is what holds the table in place.
//

import Foundation
import ReplayCore

/// How ATC payloads become JSON, and back.
public struct ATCEventCodec: EventPayloadCoding {

    public init() {}

    /// Every tag ATC has ever written.
    ///
    /// Ordered by number, and only ever appended to. A retired kind stays in this list: recordings that
    /// contain it still have to be readable, and the number stays spent forever either way.
    public static let allTags: [EventTypeTag] = [
        .commandIssued, .commandRejected, .transcriptReceived, .readbackSpoken,
        .weatherChanged, .scoreEvaluated, .timelineAction,
    ]

    // MARK: - ATC's own coding

    /// The tag naming a payload's kind.
    public func tag(for payload: ATCPayload) -> EventTypeTag { payload.tag }

    /// The payload as a JSON object, without its discriminator.
    ///
    /// The discriminator is stripped because it lives in the envelope; writing it twice would create two
    /// spellings of one fact that could disagree. `ATCPayload`'s own encoder writes it so that its decoder can
    /// find it, and this is where it comes back off.
    public func object(for payload: ATCPayload) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventSchemaError.malformed("payload did not encode to a JSON object")
        }
        object[ATCPayload.discriminatorKey] = nil
        return object
    }

    /// The payload from a JSON object already brought forward by any applicable migration.
    ///
    /// Named `decode` rather than overloading `payload(from:…)` on return type alone: two functions that differ
    /// only in what they hand back are two functions a reader has to disambiguate by squinting.
    public func decode(_ object: [String: Any],
                       tag: EventTypeTag,
                       version: Int) throws -> ATCPayload {
        // The discriminator lives in the envelope; `ATCPayload`'s decoder expects it inside the payload, so it
        // is put back here rather than being written twice on the wire.
        var object = object
        object[ATCPayload.discriminatorKey] = tag.rawValue
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(ATCPayload.self, from: data)
    }

    // MARK: - The routing contract

    /// The payload version this build writes, per tag.
    ///
    /// Written out tag by tag rather than returning a single constant, so that bumping one cannot silently bump
    /// the others — which is the entire point of versioning them separately. An unknown tag answers 1: it is
    /// not ours, nothing can be migrated for it, and claiming a higher number would invent a history.
    public func currentVersion(for tag: EventTypeTag) -> Int {
        switch tag {
        case .commandIssued:      return 1
        case .commandRejected:    return 1
        case .transcriptReceived: return 1
        case .readbackSpoken:     return 1
        case .weatherChanged:     return 1
        case .scoreEvaluated:     return 1
        case .timelineAction:     return 1
        default:                  return 1
        }
    }

    /// The frozen table: which kinds of event a replay must feed back into the simulation.
    ///
    /// The rest are annotations — real records of what happened, but not causes the simulation consumes.
    /// Separating them is what lets a replay skip audio and still be correct.
    ///
    /// An unknown tag answers `false`, and that choice is deliberate: an event this build cannot even name must
    /// not be handed to `CommandController` as though it were an instruction. It is the reading that risks an
    /// incomplete replay over a wrong one.
    public func affectsSimulation(tag: EventTypeTag) -> Bool {
        switch tag {
        case .commandIssued, .weatherChanged:
            return true
        case .commandRejected, .transcriptReceived, .readbackSpoken,
             .scoreEvaluated, .timelineAction:
            return false
        default:
            return false
        }
    }

    // `migrations` is left as the protocol's default rather than declared empty here: no ATC payload has
    // changed shape yet, and when the first field is added the change is a registration in this type. An absent
    // property is a clearer starting point than an empty one that looks like it was already thought about.

    // MARK: - Bridging to the core's contract

    // The core hands over bodies because it cannot hold an `ATCPayload`. These two functions are the only place
    // that distinction exists, and they are the entire cost of the payload being opaque.

    public func object(for payload: EventBody) throws -> [String: Any] {
        try object(for: payload.unwrap(ATCPayload.self))
    }

    public func payload(from object: [String: Any],
                        tag: EventTypeTag,
                        version: Int) throws -> EventBody {
        try decode(object, tag: tag, version: version).body
    }
}
