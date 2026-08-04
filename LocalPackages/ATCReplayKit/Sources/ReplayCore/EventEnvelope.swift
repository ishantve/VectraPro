//
//  EventEnvelope.swift
//  ReplayCore
//
//  How a recorded event survives the app changing around it.
//
//  A recording outlives the code that wrote it, by releases. So every stored event carries enough to
//  be interpreted by a build that has never seen its shape:
//
//      schemaVersion   the envelope's own format — how to find the rest
//      eventType       which kind of event this is
//      eventVersion    which version of *that kind's* payload
//      source          where it came from (attribution, never ordering)
//      correlationID   the chain this belongs to        } optional; tracing only,
//      causationID     the event that caused this one   } never ordering, never replay
//
//  Three numbers rather than one, because they change at different rates, for different reasons, and
//  at the hands of different owners. A new field on one kind of payload bumps only that tag's
//  `eventVersion`, and the *adapter* decides that; a change to the envelope itself bumps
//  `schemaVersion`, and the *core* decides that; and neither has anything to do with the manifest,
//  which is versioned separately (`SessionManifest.manifestVersion`). Collapsing them into a single
//  number would mean every unrelated change invalidating every reader's assumptions about every event
//  — and would mean neither side could release without the other.
//
//  ── Why migrations operate on dictionaries ─────────────────────────────────
//  A migration's whole job is to adapt a shape the current types cannot express. If migrations were
//  typed, every historical version of every payload would have to be kept as a Swift type, forever,
//  and the package would accumulate a `V1`, `V2`, `V3`… of every payload a domain ever wrote —
//  in a package that is not allowed to know what any of them mean. Operating on the decoded JSON
//  instead means old shapes need no code at all — only the transformation that brings them forward.
//
//  The chain runs on read, so the rest of the system only ever sees the current shape. Nothing
//  rewrites a stored recording: the bytes on disk stay exactly as they were written, which is what
//  makes a seal over them meaningful.
//

import Foundation

// MARK: - Envelope

/// The wire form of one event: routing information, then the payload.
public struct EventEnvelope: Equatable, Sendable {

    /// The envelope format. Bumped only when *this* structure changes.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int

    /// Which kind of event this is. A domain's number, which the core writes and reads but never interprets.
    public let eventType: EventTypeTag

    /// Which version of *that tag's* payload. The adapter's number — see `EventPayloadCoding.currentVersion`.
    public let eventVersion: Int
    public let position: EventPosition

    /// Where the event came from. In the envelope so it can be filtered without decoding the payload.
    public let source: EventSource

    /// Tracing: the chain's root, and this event's direct cause. Optional, and unpopulated for now — see
    /// `Event`. In the envelope for the same reason as `source`: a chain can then be walked without
    /// decoding payloads a newer build wrote.
    public let correlationID: EventID?
    public let causationID: EventID?

    public let wallClock: Date?

    public init(schemaVersion: Int = EventEnvelope.currentSchemaVersion,
                eventType: EventTypeTag,
                eventVersion: Int,
                position: EventPosition,
                source: EventSource = .unspecified,
                correlationID: EventID? = nil,
                causationID: EventID? = nil,
                wallClock: Date?) {
        self.schemaVersion = schemaVersion
        self.eventType = eventType
        self.eventVersion = eventVersion
        self.position = position
        self.source = source
        self.correlationID = correlationID
        self.causationID = causationID
        self.wallClock = wallClock
    }

    /// The envelope for an event, at the payload version the caller's codec writes.
    ///
    /// `eventVersion` is a parameter rather than something read off the event, because only the adapter knows
    /// it. The core reads the tag from the body — it is envelope data — and asks the codec for the version.
    public init(_ event: Event, eventVersion: Int) {
        self.init(eventType: event.tag,
                  eventVersion: eventVersion,
                  position: event.position,
                  source: event.source,
                  correlationID: event.correlationID,
                  causationID: event.causationID,
                  wallClock: event.wallClock)
    }

    /// Whether this build can read the envelope at all.
    ///
    /// An envelope from the future is refused rather than guessed at: if the structure changed, we do
    /// not know where the payload is, and a hopeful read produces a plausible wrong event — worse than
    /// an error, because nothing reports it.
    public var isReadable: Bool { schemaVersion <= Self.currentSchemaVersion }
}

// MARK: - Migration

public enum EventSchemaError: Error, Equatable {
    /// The envelope structure is newer than this build understands.
    case unsupportedSchema(found: Int, supported: Int)
    /// The payload is newer than this build understands, and no migration can go backwards.
    case unsupportedEventVersion(EventTypeTag, found: Int, supported: Int)
    /// A step is missing from the chain — version N exists on disk but nothing migrates N → N+1.
    case missingMigration(EventTypeTag, from: Int)
    case malformed(String)
}

/// One step forward for one kind of event.
///
/// Steps are single-version: `1 → 2`, then `2 → 3`. A migration that jumped several versions would
/// have to be rewritten every time another was added, and a gap in the chain would be invisible;
/// single steps make a gap a loud, specific error.
public protocol EventMigration: Sendable {

    /// Which kind of event this step migrates. A tag, because a migration belongs to the adapter that owns
    /// the number — the core neither knows nor reserves any.
    var tag: EventTypeTag { get }

    /// The version this step reads. It produces `fromVersion + 1`.
    var fromVersion: Int { get }

    func migrate(_ payload: [String: Any]) throws -> [String: Any]
}

/// Brings a stored payload forward to the shape a codec expects.
///
/// ── Who decides how far forward ────────────────────────────────────────────
/// The target is a parameter, supplied by the codec through `EventPayloadCoding.currentVersion(for:)`. It
/// used to be read off a per-kind table in the core, which meant the core knew the roster of a domain's event
/// kinds and their versions — the last place the ATC vocabulary was reachable from here. Taking it as an
/// argument is what lets an adapter add a payload version without a core release: the core migrates to the
/// number it is given and has no opinion about what that number should be.
///
/// Empty by default — nothing has needed migrating yet — and that is the point of having it now: the first
/// event field ever added is a one-line registration rather than a redesign, and no historical recording has
/// to be rewritten.
public struct EventMigrator: @unchecked Sendable {

    // @unchecked because the dictionary holds existentials. Every `EventMigration` is `Sendable` and
    // the registry is immutable after init, so this is safe — but the compiler cannot see that through
    // a nested dictionary of existentials.
    private let migrations: [EventTypeTag: [Int: any EventMigration]]

    public init(_ migrations: [any EventMigration] = []) {
        var indexed: [EventTypeTag: [Int: any EventMigration]] = [:]
        for migration in migrations {
            indexed[migration.tag, default: [:]][migration.fromVersion] = migration
        }
        self.migrations = indexed
    }

    /// From a codec's table, already keyed by tag and from-version.
    public init(table: [EventTypeTag: [Int: any EventMigration]]) {
        self.migrations = table
    }

    /// Runs every step from `version` up to `target`.
    ///
    /// A payload already at the target is returned untouched, which is the overwhelmingly common case and
    /// costs nothing.
    public func bringForward(_ payload: [String: Any],
                            tag: EventTypeTag,
                            from version: Int,
                            to target: Int) throws -> [String: Any] {
        // Newer than we know how to read. Migrations only go forward, so there is nothing to try.
        guard version <= target else {
            throw EventSchemaError.unsupportedEventVersion(tag, found: version, supported: target)
        }

        var payload = payload
        var current = version
        while current < target {
            guard let step = migrations[tag]?[current] else {
                throw EventSchemaError.missingMigration(tag, from: current)
            }
            payload = try step.migrate(payload)
            current += 1
        }
        return payload
    }

    /// Whether a stored version can be brought up to `target`, without attempting it. For a session list that
    /// wants to show "recorded by a newer version" without opening the log.
    public func canRead(_ tag: EventTypeTag, version: Int, target: Int) -> Bool {
        guard version <= target else { return false }
        var current = version
        while current < target {
            guard migrations[tag]?[current] != nil else { return false }
            current += 1
        }
        return true
    }
}
