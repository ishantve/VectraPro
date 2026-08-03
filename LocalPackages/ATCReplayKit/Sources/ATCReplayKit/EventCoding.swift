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
        case code, callsign, slots, source, reason
        case raw, normalized, spoken
        case windDegrees, windKnots, visibilityMetres, qnh
        case value, rulesVersion
        case action
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

        switch self {
        case .commandIssued(let code, let callsign, let slots, let source):
            try container.encode(code, forKey: .code)
            try container.encode(callsign, forKey: .callsign)
            try container.encode(slots, forKey: .slots)
            try container.encode(source, forKey: .source)

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
                slots: try container.decodeIfPresent([String: String].self, forKey: .slots) ?? [:],
                source: try container.decodeIfPresent(InputSource.self, forKey: .source) ?? .voice)

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

// MARK: - Event

extension Event: Codable {

    private enum CodingKeys: String, CodingKey {
        case tick, ordinal, payload, wallClock
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(position.tick, forKey: .tick)
        try container.encode(position.ordinal, forKey: .ordinal)
        try container.encode(payload, forKey: .payload)
        // Seconds since the epoch: a fixed number rather than a format that depends on the decoder's
        // date strategy, since a recording may be read by a build configured differently.
        try container.encodeIfPresent(wallClock?.timeIntervalSince1970, forKey: .wallClock)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let seconds = try container.decodeIfPresent(Double.self, forKey: .wallClock)
        self.init(position: EventPosition(tick: try container.decode(Int.self, forKey: .tick),
                                         ordinal: try container.decode(UInt32.self, forKey: .ordinal)),
                  payload: try container.decode(EventPayload.self, forKey: .payload),
                  wallClock: seconds.map(Date.init(timeIntervalSince1970:)))
    }
}

// MARK: - Coder

/// Turns an event into bytes and back.
///
/// A named seam, so the payload format can change without touching the log's framing — the framing is
/// what makes a truncated file recoverable, and it should not have to be revisited to make the
/// payload smaller.
public struct EventCoder: Sendable {

    public init() {}

    public func encode(_ event: Event) throws -> Data {
        let encoder = JSONEncoder()
        // Sorted, so the same event always produces the same bytes. A seal is computed over these
        // bytes, and a digest that changed with dictionary order would be worthless.
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event)
    }

    public func decode(_ data: Data) throws -> Event {
        try JSONDecoder().decode(Event.self, from: data)
    }
}
