//
//  EventBody.swift
//  ReplayCore
//
//  What an event carries, as far as the core is concerned: a tag, and something it must not look inside.
//
//  ── Why the core holds a value it cannot read ───────────────────────────────
//  *ReplayCore routes payloads. Adapters interpret payloads.* Before this type existed, the core held an
//  ATC enum, which meant the platform knew what a callsign was and no second simulation could record
//  anything at all. The body is how a domain's value travels through recording, ordering, framing, sealing
//  and replay without the machinery that moves it ever being able to ask what it means.
//
//  ── Why a box rather than a generic `Event<Payload>` ────────────────────────
//  Making `Event` generic ripples through `SessionManager`, `SessionRecorder`, `EventStore`,
//  `BranchManager`, the catalogue and every test — and the riskiest part of that edit is the part that must
//  not go wrong, the wire format. Erasure at this one type buys the same property (the core cannot read a
//  payload) at a fraction of the blast radius, and it is the shape the transport boundary wants anyway,
//  since a `[Event]` read back from a log is a heterogeneous list. R4's `ReplayEngine<S, C>` reintroduces
//  generics on the hot path, where per-tick dispatch is actually worth avoiding.
//
//  ── Why the tag lives here and not in the codec ────────────────────────────
//  The tag is envelope data: the core writes it, indexes by it, and routes on it. An adapter that had to be
//  consulted to learn an event's tag would make the envelope undecidable without a codec, which is exactly
//  the property the design paid for. So the adapter *supplies* the tag when it builds a body — it is the
//  only party that knows which kind this is — and from then on the core reads it directly.
//

import Foundation

/// A domain payload the core carries but never interprets.
///
/// Built by an adapter, read back by the same adapter. Equality is by tag and by the wrapped value, so an
/// `Event` remains comparable — which the golden corpus and every round-trip test depend on — without the
/// core knowing what it just compared.
///
/// `@unchecked Sendable` because the wrapped value is stored as `Any`, which the compiler cannot see through.
/// The initialiser accepts only a `Sendable` payload and the box is immutable afterwards, so every value that
/// can exist here is one the compiler already checked at the point it was created.
public struct EventBody: Equatable, CustomStringConvertible, @unchecked Sendable {

    /// Which kind of event this is. Owned by the adapter, written to the envelope by the core.
    public let tag: EventTypeTag

    /// The domain's own value. `Any` is the point: there is no protocol the core could name here that would
    /// not be an invitation to look inside.
    private let value: Any

    /// Erased equality and description, captured at construction where the concrete type is still known.
    /// Closures rather than an existential protocol so an adapter's payload needs no conformance it would
    /// not otherwise have — `Equatable` and `Sendable` are enough.
    private let isEqual: @Sendable (Any) -> Bool
    private let describe: @Sendable () -> String

    /// Wraps a domain payload under the tag that names its kind.
    ///
    /// `Sendable` because a recording crosses actors between the gateway that stamps it and the recorder
    /// that writes it; `Equatable` because a recording that could not be compared to what it decoded from
    /// could not be tested at all.
    public init<Payload: Equatable & Sendable>(tag: EventTypeTag, _ payload: Payload) {
        self.tag = tag
        self.value = payload
        self.isEqual = { other in (other as? Payload) == payload }
        self.describe = { String(describing: payload) }
    }

    /// The payload, as the adapter that wrote it.
    ///
    /// Throws rather than returning nil: reaching here with the wrong type means two adapters' events are in
    /// one session, which is a wiring mistake worth a specific error rather than a silently skipped event.
    public func unwrap<Payload: Equatable & Sendable>(_ expected: Payload.Type) throws -> Payload {
        guard let payload = value as? Payload else {
            throw EventSchemaError.malformed(
                "event body for \(tag) holds \(type(of: value)), not \(expected)")
        }
        return payload
    }

    /// Whether the body holds a payload of this type. For an adapter deciding whether an event is its own.
    public func holds<Payload: Equatable & Sendable>(_ expected: Payload.Type) -> Bool {
        value is Payload
    }

    /// The wrapped value's own description, so a failed assertion names the payload rather than a box.
    public var description: String { describe() }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tag == rhs.tag && lhs.isEqual(rhs.value)
    }
}
