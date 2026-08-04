//
//  EventTypeTag.swift
//  ReplayCore
//
//  What kind of event this is, as the wire says it — and nothing more.
//
//  ── The core reserves no numbers ────────────────────────────────────────────
//  This file declares no tags. Not one. The numbers are a domain's property: they are on disk, in every
//  recording that domain ever wrote, and a core that named `commandIssued = 1` would both know what an
//  aircraft is and collide with the next adapter's tag 1. So `ReplayCore` owns the *type* and an adapter
//  owns the *values* — `ATCReplayAdapter` declares 1…7 and is answerable for them forever.
//
//  ── A struct, not an enum ───────────────────────────────────────────────────
//  The same reasoning as `EventSource`, and here it matters more. Decoding an enum requires every value to
//  be known, so a recording containing a tag this build has never heard of would fail to decode *entirely*.
//  A recording must survive meeting a tag from the future: the envelope still parses, the event can still be
//  indexed, ordered, counted and sealed, and only its payload is beyond this build. An unknown tag is a
//  payload nobody can read, never a log nobody can open.
//
//  ── Why the core may read it at all ─────────────────────────────────────────
//  Routing. The core must decide whether an event feeds the simulation, and it asks the codec *by tag* so
//  that decision never requires decoding a payload. That is the one thing the core does with this value: it
//  passes it to the codec and puts it in the envelope. It never switches on it.
//

import Foundation

/// A domain's stable wire discriminator for one kind of event.
///
/// **Never renumber a value that has been written.** A stored recording refers to its events by number, so
/// changing one silently reinterprets old data — the reason a tag is a value an adapter declares once and
/// then leaves alone.
public struct EventTypeTag: RawRepresentable, Hashable, Comparable, Codable, Sendable,
                            CustomStringConvertible {

    /// `UInt16` because it is written to every event and 65,535 kinds is more than any simulation will need
    /// — and because a fixed width is a format, where a platform-sized integer is a hope.
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    /// For declaring a constant: `EventTypeTag(1)`.
    public init(_ rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public var description: String { "tag \(rawValue)" }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
