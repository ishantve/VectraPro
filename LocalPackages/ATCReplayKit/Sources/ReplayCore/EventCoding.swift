//
//  EventCoding.swift
//  ReplayCore
//
//  How an event becomes bytes.
//
//  This file writes the envelope and nothing else. The payload arrives as a JSON object from a codec
//  and is placed under one key; on the way back, an object comes out from under that key, is brought
//  forward by any migrations, and is handed to the codec. At no point does anything here look inside
//  it — the core cannot, and that is the property the phase exists to establish.
//
//  Rules for changing this file:
//    • new envelope fields are optional, and absent means "was not recorded", never a default that
//      looks real
//    • the envelope's key names never change meaning; a new meaning is a new key
//    • wire tags are never reused — and they are not ours to reuse: an adapter owns its numbers
//
//  The payload encodes as JSON. The doc argued for compact binary and the framing *is* binary, which
//  is what buys crash safety — but the payload is a separate concern, and at roughly a thousand
//  events a session the difference is some tens of kilobytes. Being able to read a recording with
//  `cat` while this format is new and its bugs are undiscovered is worth more than that. The seam is
//  `EventCoder`, so switching to binary later touches one type.
//

import Foundation

// MARK: - Coder

/// Turns an event into bytes and back, through a versioned envelope.
///
/// Two stages on read, deliberately: the envelope is read first, then the payload is brought forward
/// through any migrations, and only then handed to the codec. A single-stage typed decode could not do
/// that — it would need every historical shape to exist as a Swift type.
///
/// The wire form:
///
///     {
///       "schemaVersion" : 1,          the envelope's own format
///       "eventType"     : 1,          which kind
///       "eventVersion"  : 1,          which version of that kind's payload
///       "tick"          : 42,
///       "ordinal"       : 17,
///       "source"        : "voice",     where it came from — attribution, never ordering
///       "correlationID" : "…",          optional: the chain this belongs to
///       "causationID"   : "…",          optional: the event that caused this one
///       "wallClock"     : 1764792151.4,   optional, audit only
///       "payload"       : { … }       kind-specific, versioned by eventVersion
///     }
///
/// `tick` and `ordinal` sit in the envelope rather than inside the payload so ordering can be read
/// without interpreting — or migrating — a payload this build may not understand.
public struct EventCoder: Sendable {

    /// Who turns payloads into JSON objects and back, which version each tag is written at, and which steps
    /// bring an older one forward.
    ///
    /// Required, with no default. A default would mean some domain's vocabulary living in the core under a
    /// neutral name, which is the thing this phase removed; a consumer without a codec has not finished
    /// writing an adapter, and finding that out at the compiler rather than at the first recording is the
    /// better failure.
    private let payloadCoding: any EventPayloadCoding

    /// Built from the codec's table. The core runs the chain; the adapter owns its contents.
    private let migrator: EventMigrator

    public init(coding: any EventPayloadCoding) {
        self.payloadCoding = coding
        self.migrator = EventMigrator(table: coding.migrations)
    }

    // MARK: Encoding

    public func encode(_ event: Event) throws -> Data {
        // The tag comes off the body — envelope data the adapter supplied when it built the event — and the
        // version comes from the codec, because payload versioning is the adapter's half of the split.
        let envelope = EventEnvelope(event,
                                     eventVersion: payloadCoding.currentVersion(for: event.tag))
        var object: [String: Any] = [
            "schemaVersion": envelope.schemaVersion,
            "eventType": envelope.eventType.rawValue,
            "eventVersion": envelope.eventVersion,
            "tick": envelope.position.tick,
            "ordinal": envelope.position.ordinal,
            "source": envelope.source.rawValue,
            "payload": try payloadCoding.object(for: event.payload),
        ]
        // Written only when present. An absent optional means "was not recorded", and emitting null
        // would make a reader distinguish two spellings of the same absence.
        if let wallClock = envelope.wallClock {
            object["wallClock"] = wallClock.timeIntervalSince1970
        }
        if let correlationID = envelope.correlationID {
            object["correlationID"] = correlationID.value.uuidString
        }
        if let causationID = envelope.causationID {
            object["causationID"] = causationID.value.uuidString
        }
        // Sorted keys, so the same event always produces the same bytes. A seal is computed over these
        // bytes, and a digest that changed with dictionary order would be worthless.
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: Decoding

    /// Reads the envelope only.
    ///
    /// Useful on its own: an index can be built, and a session's ordering checked, without decoding —
    /// or being able to decode — payloads written by a newer build.
    public func decodeEnvelope(_ data: Data) throws -> EventEnvelope {
        let object = try Self.object(data)
        guard let schemaVersion = object["schemaVersion"] as? Int,
              let typeRaw = object["eventType"] as? Int,
              let eventVersion = object["eventVersion"] as? Int,
              let tick = object["tick"] as? Int,
              let ordinal = object["ordinal"] as? Int
        else { throw EventSchemaError.malformed("envelope fields missing or wrong type") }

        // Any tag decodes, known to this build's codec or not — for exactly the reason any source does. The
        // envelope must stay readable when it names a kind of event only a newer build understands, so an
        // unknown tag costs its payload and nothing else.
        return EventEnvelope(schemaVersion: schemaVersion,
                             eventType: EventTypeTag(UInt16(truncatingIfNeeded: typeRaw)),
                             eventVersion: eventVersion,
                             position: EventPosition(tick: tick,
                                                     ordinal: UInt32(truncatingIfNeeded: ordinal)),
                             // Any string decodes, known or not: a source this build has never heard of
                             // must not stop the event being read. Absent means it predates the field,
                             // which is `.unspecified` rather than a guess.
                             source: (object["source"] as? String).map(EventSource.init(rawValue:))
                                 ?? .unspecified,
                             correlationID: Self.eventID(object["correlationID"]),
                             causationID: Self.eventID(object["causationID"]),
                             wallClock: (object["wallClock"] as? Double)
                                 .map(Date.init(timeIntervalSince1970:)))
    }

    public func decode(_ data: Data) throws -> Event {
        let object = try Self.object(data)
        let envelope = try decodeEnvelope(data)

        guard envelope.isReadable else {
            throw EventSchemaError.unsupportedSchema(found: envelope.schemaVersion,
                                                    supported: EventEnvelope.currentSchemaVersion)
        }
        guard let stored = object["payload"] as? [String: Any] else {
            throw EventSchemaError.malformed("payload missing")
        }

        // Migrated only as far as the codec says this tag currently goes. The core has no table of its own to
        // consult, which is what lets an adapter add a version without a core release.
        let brought = try migrator.bringForward(
            stored,
            tag: envelope.eventType,
            from: envelope.eventVersion,
            to: payloadCoding.currentVersion(for: envelope.eventType))

        // The tag travels beside the object rather than inside it: the discriminator lives in the envelope,
        // and writing it twice would create two spellings that could disagree.
        let payload = try payloadCoding.payload(from: brought,
                                                tag: envelope.eventType,
                                                version: envelope.eventVersion)

        return Event(position: envelope.position, payload: payload,
                     source: envelope.source,
                     correlationID: envelope.correlationID,
                     causationID: envelope.causationID,
                     wallClock: envelope.wallClock)
    }

    // MARK: Private

    /// An id from the wire. A malformed one reads as absent rather than throwing: tracing metadata is
    /// diagnostic, and losing a whole event because a debugging hint was corrupt would be the wrong
    /// trade.
    private static func eventID(_ value: Any?) -> EventID? {
        (value as? String).flatMap(UUID.init(uuidString:)).map(EventID.init(value:))
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventSchemaError.malformed("not a JSON object")
        }
        return object
    }


}
