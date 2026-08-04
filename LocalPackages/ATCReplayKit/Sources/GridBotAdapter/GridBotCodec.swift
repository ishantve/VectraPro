//
//  GridBotCodec.swift
//  GridBotAdapter
//
//  GridBot's half of the coding contract. Mirrors ATCEventCodec: the four questions answered in this
//  domain's own vocabulary, plus the boxing/unboxing bridge to the core's tag/body contract.
//

import Foundation
import ReplayCore

public struct GridBotCodec: EventPayloadCoding {

    public init() {}

    public static let allTags: [EventTypeTag] = [
        .gridMove, .gridTurn, .gridPickup, .gridAnnotation, .gridTimeline,
    ]

    // MARK: - GridBot's own coding

    public func tag(for payload: GridBotPayload) -> EventTypeTag { payload.tag }

    public func object(for payload: GridBotPayload) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventSchemaError.malformed("payload did not encode to a JSON object")
        }
        object[GridBotPayload.discriminatorKey] = nil   // lives in the envelope, not the payload
        return object
    }

    public func decode(_ object: [String: Any], tag: EventTypeTag, version: Int) throws -> GridBotPayload {
        var object = object
        object[GridBotPayload.discriminatorKey] = tag.rawValue
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(GridBotPayload.self, from: data)
    }

    // MARK: - The routing contract

    /// Pickup grew a `weight` field in version 2; everything else is still on its first shape.
    public func currentVersion(for tag: EventTypeTag) -> Int {
        switch tag {
        case .gridPickup: return 2
        default:          return 1
        }
    }

    /// Which kinds a replay must feed back into the simulation. Notes and timeline actions are annotations.
    public func affectsSimulation(tag: EventTypeTag) -> Bool {
        switch tag {
        case .gridMove, .gridTurn, .gridPickup: return true
        case .gridAnnotation, .gridTimeline:    return false
        default:                                return false
        }
    }

    /// GridBot's one payload evolution: pickup v1 → v2.
    public var migrations: [EventTypeTag: [Int: any EventMigration]] {
        [.gridPickup: [1: GridPickupV1ToV2()]]
    }

    // MARK: - Bridge to the core's body/tag contract

    public func object(for payload: EventBody) throws -> [String: Any] {
        try object(for: payload.unwrap(GridBotPayload.self))
    }

    public func payload(from object: [String: Any], tag: EventTypeTag, version: Int) throws -> EventBody {
        try decode(object, tag: tag, version: version).body
    }
}

/// Pickup version 1 had no weight; a unit of cargo weighed 1. Bring old recordings forward by saying so,
/// rather than freezing their absence into a decode failure.
struct GridPickupV1ToV2: EventMigration {
    let tag: EventTypeTag = .gridPickup
    let fromVersion = 1
    func migrate(_ payload: [String: Any]) throws -> [String: Any] {
        var payload = payload
        if payload["weight"] == nil { payload["weight"] = 1 }
        return payload
    }
}
