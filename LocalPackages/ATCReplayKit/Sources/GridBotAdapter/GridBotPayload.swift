//
//  GridBotPayload.swift
//  GridBotAdapter
//
//  Reference adapter — a second, deliberately unrelated simulation, built to test whether ReplayCore is
//  genuinely usable by something other than ATC. A robot on an integer grid: it moves, it turns, it picks
//  cargo up. None of these words mean anything to air traffic control, which is the point.
//
//  Written against ReplayCore's public API and ATCReplayAdapter as the worked example only — no ReplayCore
//  internals are imported anywhere in this target or its tests. If any of this had needed `@testable import
//  ReplayCore`, that would have been the finding.
//

import Foundation
import ReplayCore

// MARK: - Wire tags (this adapter owns its own numbers, independent of ATC's)

public extension EventTypeTag {
    static let gridMove       = EventTypeTag(1)
    static let gridTurn       = EventTypeTag(2)
    static let gridPickup     = EventTypeTag(3)
    static let gridAnnotation = EventTypeTag(4)
    static let gridTimeline   = EventTypeTag(5)
}

/// Which way the robot rotates in place.
public enum GridTurn: String, Codable, Equatable, Sendable {
    case left, right
}

// MARK: - Payload

/// What a GridBot event says, in the robot's own terms.
public enum GridBotPayload: Equatable, Sendable {

    /// Advance `steps` cells in the current heading. Feeds the simulation.
    case moved(steps: Int)

    /// Rotate 90° in place. Feeds the simulation.
    case turned(GridTurn)

    /// Pick a unit of cargo up. Feeds the simulation.
    ///
    /// `weight` was added in payload version 2; version-1 recordings had no weight, and the migration in
    /// `GridBotCodec` fills it with 1 — the exercise that proves an adapter can evolve a payload.
    case pickedUp(weight: Int)

    /// A free-text note. **Not** an input to the simulation — the analogue of ATC's transcript.
    case annotated(note: String)

    /// A user timeline action. Platform vocabulary, wrapped so it gets one of this domain's tags.
    case timeline(TimelineAction)

    public var tag: EventTypeTag {
        switch self {
        case .moved:      return .gridMove
        case .turned:     return .gridTurn
        case .pickedUp:   return .gridPickup
        case .annotated:  return .gridAnnotation
        case .timeline:   return .gridTimeline
        }
    }

    /// The tagged, core-opaque body an `Event` carries.
    var body: EventBody { EventBody(tag: tag, self) }
}

// MARK: - Coding (hand-written, so a renamed parameter can never silently stop old logs decoding)

extension GridBotPayload: Codable {

    static let discriminatorKey = "kind"

    private enum CodingKeys: String, CodingKey {
        case kind
        case steps, direction, weight, note, action
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tag.rawValue, forKey: .kind)
        switch self {
        case .moved(let steps):     try container.encode(steps, forKey: .steps)
        case .turned(let dir):      try container.encode(dir, forKey: .direction)
        case .pickedUp(let weight): try container.encode(weight, forKey: .weight)
        case .annotated(let note):  try container.encode(note, forKey: .note)
        case .timeline(let action): try container.encode(action, forKey: .action)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = EventTypeTag(rawValue: try container.decode(UInt16.self, forKey: .kind))
        switch tag {
        case .gridMove:
            self = .moved(steps: try container.decode(Int.self, forKey: .steps))
        case .gridTurn:
            self = .turned(try container.decode(GridTurn.self, forKey: .direction))
        case .gridPickup:
            // Always present by the time the payload reaches here: version-1 objects are brought forward by
            // the migration before decode, which is exactly the property the migration exists to guarantee.
            self = .pickedUp(weight: try container.decode(Int.self, forKey: .weight))
        case .gridAnnotation:
            self = .annotated(note: try container.decode(String.self, forKey: .note))
        case .gridTimeline:
            self = .timeline(try container.decode(TimelineAction.self, forKey: .action))
        default:
            throw EventSchemaError.malformed("no GridBot payload is registered for \(tag)")
        }
    }
}
