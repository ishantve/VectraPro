//
//  EventPayloadCoding.swift
//  ReplayCore
//
//  The seam between the core and a domain's event vocabulary.
//
//  ── Why a seam before a move ───────────────────────────────────────────────
//  R2's goal is that the core holds bytes and a tag while the domain owns meaning. Doing that in one step means
//  making `Event` generic, which ripples through `SessionManager`, `SessionRecorder`, `EventStore`, `BranchManager`
//  and every test — a large edit whose riskiest part is the one that must not go wrong: the wire format.
//
//  So the seam comes first. Payload encoding, payload decoding and the affects-simulation decision move behind one
//  injected object, with the golden corpus proving no byte moved. The vocabulary itself moves out afterwards,
//  against a seam that is already covered. Compatibility before cleanliness: the format is a public protocol now,
//  and a protocol is not the thing to change while also restructuring the code that produces it.
//
//  ── The wire format is unchanged by this file ──────────────────────────────
//  · An old recording still reads — nothing about parsing changed, only who performs it.
//  · A new recording still verifies — the same bytes are produced, so the same seal is computed.
//  · The corpus stays byte-for-byte valid — asserted, not assumed.
//  · The envelope is still independently understandable — `decodeEnvelope` never consults this object.
//
//  ── Deciding by tag, not by value ──────────────────────────────────────────
//  `affectsSimulation(kind:)` takes the wire tag rather than a decoded payload. That is deliberate and it is the
//  property the current design paid for: a build must be able to decide whether an event feeds the simulation
//  *without* being able to decode it, or a recording written by a newer build could not be replayed by an older
//  one. Requiring a decoded value here would quietly throw that away.
//

import Foundation

/// How a domain's payloads become JSON objects, and back.
///
/// Deliberately expressed in dictionaries rather than `Data`: the envelope owns the outer object, the seal is
/// computed over the whole thing with sorted keys, and handing the domain raw bytes would let it decide framing
/// that belongs to the core.
public protocol EventPayloadCoding: Sendable {

    /// The payload as a JSON object, **without** its type discriminator — that lives in the envelope, and
    /// duplicating it on the wire would create two spellings that could disagree.
    func object(for payload: EventPayload) throws -> [String: Any]

    /// The payload from a JSON object already brought forward by any applicable migration.
    func payload(from object: [String: Any], kind: EventKind, version: Int) throws -> EventPayload

    /// Whether replaying the simulation needs this kind of event.
    ///
    /// By tag, never by decoded value. See the file header.
    func affectsSimulation(kind: EventKind) -> Bool
}

// MARK: - The current behaviour, unchanged

/// The ATC vocabulary's coding, exactly as `EventCoder` performed it before the seam existed.
///
/// Still in ReplayCore for now. Moving it to an adapter is the second half of R2, and it is a separate step so
/// that this one can be proved byte-neutral on its own.
public struct DefaultEventPayloadCoding: EventPayloadCoding {

    public init() {}

    public func object(for payload: EventPayload) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventSchemaError.malformed("payload did not encode to a JSON object")
        }
        object["kind"] = nil
        return object
    }

    public func payload(from object: [String: Any], kind: EventKind, version: Int) throws -> EventPayload {
        // The discriminator lives in the envelope; `EventPayload`'s decoder expects it inside the payload, so it
        // is put back here rather than being written twice on the wire.
        var object = object
        object["kind"] = kind.rawValue
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(EventPayload.self, from: data)
    }

    /// The frozen table. `GoldenCorpusTests.testWhichKindsAffectTheSimulationIsFrozen` is what holds it in place,
    /// and it is the single most dangerous value in the extraction: wrong here and a replay silently skips a real
    /// input or applies an annotation.
    public func affectsSimulation(kind: EventKind) -> Bool {
        switch kind {
        case .commandIssued, .weatherChanged:
            return true
        case .commandRejected, .transcriptReceived, .readbackSpoken,
             .scoreEvaluated, .timelineAction:
            return false
        }
    }
}
