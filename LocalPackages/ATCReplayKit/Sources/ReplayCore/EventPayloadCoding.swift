//
//  EventPayloadCoding.swift
//  ReplayCore
//
//  The routing contract: everything the core must be told about payloads it cannot read.
//
//  ── One protocol, two halves, and only one of them lives here ───────────────
//  R2a put the seam here with an ATC implementation beside it, so the move could be proved byte-neutral
//  before the vocabulary travelled. R2b-atomic finishes the job and the file splits along the boundary:
//
//    · **the core routing contract** — this file. Expressed entirely in `EventBody`, `EventTypeTag`,
//      `[String: Any]` and `Int`. Not one signature here names a domain noun, which is the property that
//      makes it a contract rather than a leak.
//    · **the adapter's typed coding** — `ATCEventCodec`, in `ATCReplayAdapter`. It works in `ATCPayload`,
//      knows what a callsign is, owns tags 1…7, and satisfies this contract by boxing at the boundary.
//
//  Nothing in ReplayCore implements this protocol. There is no default, deliberately: a core-supplied
//  implementation would be some domain's vocabulary wearing a neutral name, which is exactly what was
//  removed. A consumer that has not written a codec has not finished writing an adapter.
//
//  ── The wire format is not this file's business ─────────────────────────────
//  Dictionaries rather than `Data`, so the core keeps what is genuinely its own: the outer object, the
//  sorted-key ordering the seal depends on, and the framing. Handing an adapter raw bytes would let it decide
//  format questions the compatibility contract says have exactly one owner.
//
//  ── Deciding by tag, not by value ──────────────────────────────────────────
//  `affectsSimulation(tag:)` and `currentVersion(for:)` both take a tag rather than a payload, and that is
//  the most consequential shape in the platform. A build must be able to decide whether an event feeds the
//  simulation, and how far to migrate it, *without* being able to decode it — or a recording written by a
//  newer build could not be replayed by an older one at all.
//

import Foundation

/// What the core needs from a domain in order to route its payloads.
///
/// Four requirements and one optional, and deliberately no more. Everything else about an event — framing,
/// ordering, timing, sealing, storage, lifecycle — is the core's and is not negotiable through this protocol.
public protocol EventPayloadCoding: Sendable {

    /// The payload version this build writes for this tag.
    ///
    /// Per tag, so bumping one kind cannot silently bump the rest, and asked of the adapter because payload
    /// versioning is the adapter's half of the migration split: the core owns `schemaVersion`, the adapter owns
    /// `eventVersion`, and neither has to release for the other to evolve.
    ///
    /// It is also the migration target. The core migrates *up to* this number and no further, which is why an
    /// adapter can add a version without the core knowing it happened.
    func currentVersion(for tag: EventTypeTag) -> Int

    /// The payload as a JSON object, **without** its type discriminator — that lives in the envelope, and
    /// duplicating it on the wire would create two spellings that could disagree.
    func object(for payload: EventBody) throws -> [String: Any]

    /// The payload from a JSON object already brought forward by any applicable migration.
    ///
    /// The core hands over an object, a tag and the version it was stored at; the adapter returns a body, or
    /// throws. The core never inspects the object.
    func payload(from object: [String: Any], tag: EventTypeTag, version: Int) throws -> EventBody

    /// Whether replaying the simulation needs this kind of event.
    ///
    /// By tag, never by decoded value. See the file header — this is the single most consequential signature
    /// in the platform, and requiring a payload here would quietly make every recording unreadable by every
    /// older build.
    func affectsSimulation(tag: EventTypeTag) -> Bool

    /// Steps that bring an older payload forward, keyed by tag and then by the version each step reads.
    ///
    /// Optional. Absent means "no payload has ever changed shape", which is the common case and the honest
    /// default. The core applies the chain before calling `payload(from:tag:version:)`, so an adapter's
    /// decoder only ever sees the current shape.
    var migrations: [EventTypeTag: [Int: any EventMigration]] { get }
}

public extension EventPayloadCoding {

    /// No migrations. Overridden by an adapter the first time it changes a payload's shape.
    var migrations: [EventTypeTag: [Int: any EventMigration]] { [:] }
}
