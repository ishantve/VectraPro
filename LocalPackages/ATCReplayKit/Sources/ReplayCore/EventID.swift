//
//  EventID.swift
//  ATCReplayKit
//
//  A stable name for one recorded event.
//
//  Bookmarks, instructor annotations, analytics and cloud sync all need to point at one specific event
//  and keep pointing at it. That needs an identity that survives everything else changing.
//
//  ── Ordering never uses this ────────────────────────────────────────────────
//  Ordering is `(tick, ordinal)`. The id is opaque on purpose so nothing can be tempted to sort by it,
//  which is also why it is not a padded ordinal or a timestamp.
//
//  ── Derived from the two things that never change ───────────────────────────
//      eventID = UUIDv8( SHA256( sessionID ‖ "evt" ‖ ordinal ) )
//
//  Not the payload: payloads are migrated on read, so a content-derived id would change the moment a
//  migration touched an event — silently orphaning every annotation pointing at it. Identity has to
//  outlive the shape.
//
//  Not the tick: `ordinal` alone is unique within a session, and mixing in `tick` would tie identity to
//  a value a future feature might legitimately re-stamp. An annotation must not lose its anchor because
//  a tick was corrected.
//
//  ── Computed, not stored ───────────────────────────────────────────────────
//  Nothing writes this into the log. It therefore cannot disagree with the event's position, it costs
//  no bytes, and — the part worth saying plainly — **this scheme can be replaced without touching a
//  single recording**, because no recording encodes it.
//
//  The trade: an `Event` cannot name itself without knowing its session. That is honest rather than
//  inconvenient; a per-session ordinal means nothing without the session, and anything carrying events
//  across a boundary carries the session id anyway.
//

import Foundation

/// A stable, session-scoped name for one event.
///
/// A `UUID` underneath so it drops into a database column, a JSON field or a dictionary key without
/// ceremony — but a distinct type, so it cannot be confused with a `SessionID` at a call site.
public struct EventID: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {

    public let value: UUID

    public var description: String { value.uuidString }

    /// Derives the id for `ordinal` within `session`.
    ///
    /// Deterministic: the same pair always gives the same id, on every device and every run. That is
    /// what lets two copies of a session — a trainee's and an instructor's — agree about which event an
    /// annotation refers to without exchanging anything but the session.
    public init(session: SessionID, ordinal: UInt32) {
        var input = Data()
        input.append(contentsOf: Self.bytes(of: session))
        // A domain separator, so this hash space cannot collide with anything else we later derive from
        // a session id — a snapshot id, a chunk id.
        input.append(contentsOf: Array("evt".utf8))
        withUnsafeBytes(of: ordinal.littleEndian) { input.append(contentsOf: $0) }

        self.value = Self.uuid(from: SHA256.bytes(input))
    }

    /// For reading an id that was stored elsewhere — an annotation row, a sync payload.
    public init(value: UUID) {
        self.value = value
    }

    // MARK: - Private

    private static func bytes(of uuid: UUID) -> [UInt8] {
        let u = uuid.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    /// The first 16 bytes of a digest, marked as a UUID version 8.
    ///
    /// Version 8 is RFC 9562's "custom" form: derived by a scheme of the implementation's own. Not
    /// version 4, which asserts randomness this is not, and not version 5, which is specified as SHA-1.
    /// Claiming v8 is simply the truthful label, and it means any UUID parser will accept it.
    private static func uuid(from digest: [UInt8]) -> UUID {
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80   // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Event

extension Event {

    /// This event's stable identity within `session`.
    ///
    /// Takes the session because the id is derived rather than stored — see the file header. Cheap, but
    /// not free (one SHA-256), so hold onto the result rather than recomputing it in a loop.
    public func id(in session: SessionID) -> EventID {
        EventID(session: session, ordinal: ordinal)
    }
}

extension EventEnvelope {

    /// The identity of the event this envelope describes.
    ///
    /// Available from the envelope alone, without decoding — or being able to decode — the payload. An
    /// index or a sync manifest can therefore name every event in a log written by a newer build.
    public func id(in session: SessionID) -> EventID {
        EventID(session: session, ordinal: position.ordinal)
    }
}
