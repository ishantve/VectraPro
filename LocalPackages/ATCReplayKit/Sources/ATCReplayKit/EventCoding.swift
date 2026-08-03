//
//  EventCoding.swift
//  ATCReplayKit
//
//  How an event becomes bytes.
//
//  Written out by hand rather than left to Swift's synthesised enum `Codable`. The synthesised form
//  keys on Swift case and parameter *names*, so renaming a parameter — a refactor with no intent
//  behind it — would silently stop old recordings decoding. A recording outlives the code that wrote
//  it, so the mapping between names and bytes has to be a decision, written down, and only ever
//  added to.
//
//  Rules for changing this file:
//    • new fields are optional, and absent means "was not recorded", never a default that looks real
//    • `EventKind` numbers are never reused
//    • a field's meaning never changes; a new meaning is a new field
//
//  The payload encodes as JSON. The doc argued for compact binary and the framing *is* binary, which
//  is what buys crash safety — but the payload is a separate concern, and at roughly a thousand
//  events a session the difference is some tens of kilobytes. Being able to read a recording with
//  `cat` while this format is new and its bugs are undiscovered is worth more than that. The seam is
//  `EventCoder`, so switching to binary later touches one type.
//

import Foundation

extension EventPayload: Codable {

    private enum CodingKeys: String, CodingKey {
        case kind
        case code, callsign, slots, reason
        case raw, normalized, spoken
        case windDegrees, windKnots, visibilityMetres, qnh
        case value, rulesVersion
        case action
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

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
        let kind = try container.decode(EventKind.self, forKey: .kind)

        switch kind {
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
        }
    }
}

// MARK: - Coder

/// Turns an event into bytes and back, through a versioned envelope.
///
/// Two stages on read, deliberately: the envelope is read first, then the payload is brought forward
/// through any migrations, and only then decoded into a typed `EventPayload`. A single-stage typed
/// decode could not do that — it would need every historical shape to exist as a Swift type.
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
///       "wallClock"     : 1764792151.4,   optional, audit only
///       "payload"       : { … }       kind-specific, versioned by eventVersion
///     }
///
/// `tick` and `ordinal` sit in the envelope rather than inside the payload so ordering can be read
/// without interpreting — or migrating — a payload this build may not understand.
public struct EventCoder: Sendable {

    private let migrator: EventMigrator

    public init(migrator: EventMigrator = .current) {
        self.migrator = migrator
    }

    // MARK: Encoding

    public func encode(_ event: Event) throws -> Data {
        let envelope = EventEnvelope(event)
        var object: [String: Any] = [
            "schemaVersion": envelope.schemaVersion,
            "eventType": envelope.eventType.rawValue,
            "eventVersion": envelope.eventVersion,
            "tick": envelope.position.tick,
            "ordinal": envelope.position.ordinal,
            "source": envelope.source.rawValue,
            "payload": try payloadObject(event.payload),
        ]
        if let wallClock = envelope.wallClock {
            object["wallClock"] = wallClock.timeIntervalSince1970
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
              let eventType = EventKind(rawValue: UInt16(truncatingIfNeeded: typeRaw)),
              let eventVersion = object["eventVersion"] as? Int,
              let tick = object["tick"] as? Int,
              let ordinal = object["ordinal"] as? Int
        else { throw EventSchemaError.malformed("envelope fields missing or wrong type") }

        return EventEnvelope(schemaVersion: schemaVersion,
                             eventType: eventType,
                             eventVersion: eventVersion,
                             position: EventPosition(tick: tick,
                                                     ordinal: UInt32(truncatingIfNeeded: ordinal)),
                             // Any string decodes, known or not: a source this build has never heard of
                             // must not stop the event being read. Absent means it predates the field,
                             // which is `.unspecified` rather than a guess.
                             source: (object["source"] as? String).map(EventSource.init(rawValue:))
                                 ?? .unspecified,
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

        let brought = try migrator.bringForward(stored,
                                               type: envelope.eventType,
                                               from: envelope.eventVersion)
        // The type discriminator lives in the envelope; `EventPayload`'s decoder reads it from the
        // payload, so it is put back rather than duplicated on the wire.
        var payloadObject = brought
        payloadObject["kind"] = envelope.eventType.rawValue

        let payload = try JSONDecoder().decode(
            EventPayload.self,
            from: try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys]))

        return Event(position: envelope.position, payload: payload,
                     source: envelope.source, wallClock: envelope.wallClock)
    }

    // MARK: Private

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventSchemaError.malformed("not a JSON object")
        }
        return object
    }

    /// The payload as a dictionary, without its `kind` — that belongs to the envelope.
    private func payloadObject(_ payload: EventPayload) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var object = try Self.object(try encoder.encode(payload))
        object["kind"] = nil
        return object
    }
}
