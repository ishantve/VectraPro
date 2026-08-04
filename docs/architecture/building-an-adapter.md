# Building a ReplayCore Adapter — the GridBot worked example

**Status:** canonical how-to. Read [`replay-adapter-boundary.md`](replay-adapter-boundary.md) for *why* the
boundary is shaped this way; this document is *how* to build against it.

ReplayCore records, orders, times, seals, stores and replays events for **any** deterministic simulation. It
knows nothing about what an event means — that is the adapter's job. This guide builds a complete adapter for a
simulation ReplayCore has never heard of: **GridBot**, a robot on an integer grid that moves, turns and picks
up cargo. It uses ReplayCore's **public API only** — no `@testable`, no core internals — and ReplayCore
required no change to host it. That is the proof the boundary is real, and the reason GridBot is the reference.

The whole adapter is four small files plus a test:

```
Sources/GridBotAdapter/
  GridBotPayload.swift    – the vocabulary + wire tags + coding
  GridBotCodec.swift      – the coding contract + migrations
  GridBotEvent.swift      – how events are constructed (facts, not mechanics)
  GridWorld.swift         – the simulation + a deterministic fingerprint
Tests/GridBotAdapterTests/
  GridBotReferenceTest.swift – record → replay → seal → fingerprint, end to end
```

Your target depends on **`ReplayCore` alone**:

```swift
.target(name: "GridBotAdapter", dependencies: ["ReplayCore"]),
```

If you ever reach for `@testable import ReplayCore` or a core internal, stop — the public surface is meant to
be sufficient, and if it isn't, that is a defect in ReplayCore, not a step you route around.

---

## 1 · Adapter structure

An adapter answers four questions and no more (boundary doc §2), all through one protocol,
`EventPayloadCoding`:

1. **What does a payload look like on the wire?** — `object(for:)` / `payload(from:)`
2. **Which version is current, per kind?** — `currentVersion(for:)`
3. **Which kinds must a replay actually apply?** — `affectsSimulation(tag:)`
4. **How does an old payload move forward?** — `migrations` (optional)

Everything else — what a payload *means*, how the world changes, what a fingerprint includes — is yours, and
ReplayCore has no hook for it. Keep the split in mind as you read: the four answers above are the contract; the
rest of this document is your business that the contract never sees.

---

## 2 · Payload — the vocabulary

Your payload is an enum whose cases name **facts in your domain**. GridBot's are `moved`, `turned`, `pickedUp`,
`annotated`, `timeline` — none of which mean anything to another simulation, which is exactly right.

Each kind gets a **wire tag**: a `UInt16` you own, declared as an extension on the core's `EventTypeTag`
(a struct, not an enum, so a reader that meets a tag it doesn't know can still read the envelope):

```swift
public extension EventTypeTag {
    static let gridMove       = EventTypeTag(1)
    static let gridTurn       = EventTypeTag(2)
    static let gridPickup     = EventTypeTag(3)
    static let gridAnnotation = EventTypeTag(4)
    static let gridTimeline   = EventTypeTag(5)
}

public enum GridBotPayload: Equatable, Sendable {
    case moved(steps: Int)
    case turned(GridTurn)
    case pickedUp(weight: Int)
    case annotated(note: String)          // not a simulation input
    case timeline(TimelineAction)         // platform action, wrapped so it gets one of our tags

    public var tag: EventTypeTag { … }    // one case → one tag
    var body: EventBody { EventBody(tag: tag, self) }   // the tagged, core-opaque box
}
```

**Rules that keep old recordings readable** (a recording outlives the code that wrote it):

- **Tag numbers are never reused or renumbered.** They are on disk in every recording. A retired kind keeps
  its number forever.
- **New fields are optional**, and absent means "was not recorded", never a default that looks real.
- **Write the `Codable` by hand.** Synthesised enum coding keys on Swift case/parameter *names*, so a rename —
  a refactor with no intent behind it — would silently stop old logs decoding. GridBot encodes an explicit
  `kind` discriminator (the tag's raw value) and one branch per case. The codec strips `kind` before the wire
  (it lives in the envelope) and puts it back on the way in.

`EventBody` is the crucial type: a tag ReplayCore routes on, wrapped around a value it **cannot read**. The
core carries it opaquely; only your adapter boxes and unboxes it.

---

## 3 · Codec — the coding contract

`GridBotCodec` conforms to `EventPayloadCoding`. Write the **typed** functions first (over `GridBotPayload`),
then a thin bridge to the core's body/tag half:

```swift
public struct GridBotCodec: EventPayloadCoding {
    public func tag(for payload: GridBotPayload) -> EventTypeTag { payload.tag }

    public func object(for payload: GridBotPayload) throws -> [String: Any] {
        // JSONEncoder(.sortedKeys) → [String: Any]; strip the discriminator (it lives in the envelope)
    }
    public func decode(_ object: [String: Any], tag: EventTypeTag, version: Int) throws -> GridBotPayload {
        // put the discriminator back, then JSONDecoder
    }

    public func currentVersion(for tag: EventTypeTag) -> Int {
        switch tag { case .gridPickup: return 2; default: return 1 }
    }

    public func affectsSimulation(tag: EventTypeTag) -> Bool {
        switch tag {
        case .gridMove, .gridTurn, .gridPickup: return true
        case .gridAnnotation, .gridTimeline:    return false
        default:                                return false
        }
    }

    // Bridge to the core's contract — the only place `EventBody` ↔ `GridBotPayload` exists:
    public func object(for payload: EventBody) throws -> [String: Any] {
        try object(for: payload.unwrap(GridBotPayload.self))
    }
    public func payload(from object: [String: Any], tag: EventTypeTag, version: Int) throws -> EventBody {
        try decode(object, tag: tag, version: version).body
    }
}
```

Two signatures decide correctness:

- **`currentVersion(for:)`** is written out tag by tag, not as one constant, so bumping one kind can't silently
  bump the others. An unknown tag answers 1 — claiming higher would invent a history.
- **`affectsSimulation(tag:)` is the most dangerous value in the platform.** Wrong here and a replay silently
  skips a real input or applies an annotation. It is answered **by tag, never by a decoded payload**, so a
  build that can't decode a newer payload can still route the recording correctly. An unknown tag answers
  `false`: an event you can't even name must not be fed to the simulation as though it were an input.

---

## 4 · Event construction — facts, not mechanics

Do **not** let call sites build events by hand. Give them one function per fact, named for the fact:

```swift
public enum GridBotEvent {
    public static func moved(steps: Int, at position: EventPosition,
                             source: EventSource = .system) -> Event {
        Event(position: position, payload: GridBotPayload.moved(steps: steps).body, source: source)
    }
    public static func pickedUp(weight: Int = 1, at position: EventPosition,
                                source: EventSource = .system) -> Event { … }
    // turned, annotated, timeline …

    /// Reading one back — nil when the event carries another domain's payload.
    public static func payload(of event: Event) -> GridBotPayload? {
        try? event.payload.unwrap(GridBotPayload.self)
    }
}
```

This is the single most important design principle, and it earns its keep:

> **An adapter's public API names facts that occurred. It never names how replay stores them.**
> `GridBotEvent.moved(steps:at:)` ✓ — `makeEvent(kind:payloadObject:version:)` ✗.

Because call sites say *what happened* ("a move of 3"), the representation underneath can change — a core enum
became an opaque `EventBody` during R2b-atomic — and **not one call site moved**. An API named after mechanics
would not have that property. `payload(of:)` is the counterpart: the only sanctioned way to read a payload
back, because a body is opaque *to the core*, not to the adapter that wrote it.

`Event` itself is core infrastructure — position, source, identity, tracing. You never extend it; you build one
through your namespace, so your vocabulary never lands on a core type.

---

## 5 · World reconstruction — the simulation

The world is entirely yours. ReplayCore never sees it. It must be **deterministic**: the same events in the
same order produce the same state, which is what makes a fingerprint mean anything.

```swift
public struct GridWorld: Equatable, Sendable {
    public private(set) var x = 0, y = 0
    public private(set) var heading: Heading = .north
    public private(set) var cargoWeight = 0, moveCount = 0

    public mutating func apply(_ payload: GridBotPayload) {
        switch payload {
        case .moved(let steps):     // advance in heading
        case .turned(let dir):      // rotate 90°
        case .pickedUp(let w):      cargoWeight += w
        case .annotated, .timeline: break   // never routed here
        }
    }
}
```

A replay is then just: read the log, keep the events whose tag `affectsSimulation`, apply each to a fresh
world **in recorded order**:

```swift
var world = GridWorld()
for event in try store.readAll() where codec.affectsSimulation(tag: event.tag) {
    if let payload = GridBotEvent.payload(of: event) { world.apply(payload) }
}
```

Ordering is ReplayCore's — `(tick, ordinal)` — and `readAll()` returns events already in it. You never sort.

---

## 6 · Replay verification — fingerprint and seal

Two independent guarantees.

**Determinism (fingerprint).** *Fingerprint composition is your business* — which fields matter, to what
precision. GridBot hashes its whole state:

```swift
public var fingerprint: String {
    let canonical = "x=\(x);y=\(y);h=\(heading.rawValue);w=\(cargoWeight);m=\(moveCount)"
    return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
}
```

The reference test records a session, replays it through the store, and asserts the replayed world's
fingerprint equals the live one — proof the round trip changed nothing.

**Integrity (seal).** ReplayCore's, not yours. Record through `SessionRecorder`; `finish()` returns the seal,
computed incrementally as frames are written. A reader recomputes it in one pass and the two must agree:

```swift
let recorder = SessionRecorder(sessionID: …, sessionClass: .assessment,
                               manifestBytes: manifest,
                               store: EventStore(url: url, sessionClass: .assessment, coding: GridBotCodec()))
try recorder.open()
for event in script() { recorder.record(event) }
let sealed = try recorder.finish()!                       // incremental
let log = try Data(contentsOf: url)
assert(sealed == SessionSeal.compute(manifest: manifest, log: log))   // one-pass recompute
assert(SessionSeal.verify(sealed, manifest: manifest, log: log))      // and a tampered log fails
```

The seal covers the manifest **and** the log, so neither the seed/config nor the events can change without the
verification failing.

**Golden corpus.** Record a scripted session, keep its bytes as a committed fixture, and assert the format
reproduces them exactly — plus that a decode → re-encode is byte-identical. This is what notices if the
on-disk format ever drifts under you. (GridBot stores its golden as a base64 constant in the test.)

---

## 7 · Migration — evolving a payload without a core release

When a payload grows a field, bump its version and register a one-step migration. GridBot's `pickedUp` gained a
`weight` in version 2; version-1 recordings had none, so the migration fills it with 1:

```swift
public func currentVersion(for tag: EventTypeTag) -> Int {
    switch tag { case .gridPickup: return 2; default: return 1 }
}
public var migrations: [EventTypeTag: [Int: any EventMigration]] {
    [.gridPickup: [1: GridPickupV1ToV2()]]
}

struct GridPickupV1ToV2: EventMigration {
    let tag: EventTypeTag = .gridPickup
    let fromVersion = 1
    func migrate(_ payload: [String: Any]) throws -> [String: Any] {
        var p = payload; if p["weight"] == nil { p["weight"] = 1 }; return p
    }
}
```

ReplayCore runs the chain (`from` → `target`, one step at a time) **before** it calls your `decode`, so your
decoder only ever sees the current shape. Steps are single-version (`1 → 2`, then `2 → 3`): a gap becomes a
loud `missingMigration` error rather than silent corruption. Because the target version comes from *your*
`currentVersion`, you can add a payload version with **no ReplayCore release** — the whole point of two
version numbers (envelope vs payload, boundary doc §5).

---

## 8 · Design principles, in order of consequence

1. **The core routes payloads; the adapter interprets them.** If code needs to know what a payload *means*, it
   is yours. If it only needs the envelope — tag, position, source, version — it is the core's.
2. **Facts, not mechanics** (§4). Name events for what happened. It is what let the representation change
   underneath without a single call site moving.
3. **Route by tag, never by decoded payload** (§3). `affectsSimulation` and all routing read the envelope, so a
   log written by a newer build — or another domain's adapter — stays replayable.
4. **Tags and field meanings are permanent.** Add, never renumber or repurpose. Hand-write the coding so a
   rename can't rewrite history.
5. **Determinism is the whole game.** A world that isn't deterministic has no meaningful fingerprint and can't
   be verified. Keep wall-clock, real randomness and platform state out of `apply`.
6. **Depend on `ReplayCore` only.** No core internals, no other adapter. GridBot proves the public surface is
   enough; hold new adapters to the same line.

---

## The checklist a new adapter is done against

- [ ] Payload enum: one case per fact, `Equatable & Sendable`, hand-written `Codable`, `.tag`, `.body`.
- [ ] Wire tags: an `EventTypeTag` extension, numbered, append-only.
- [ ] Codec: typed `object`/`decode`, `currentVersion(for:)`, `affectsSimulation(tag:)`, body/tag bridge.
- [ ] Construction API: one function per fact + `payload(of:)`. No mechanics in the names.
- [ ] World: deterministic `apply`, and a fingerprint you compose.
- [ ] Replay: `readAll()` → filter by `affectsSimulation` → `apply` in order.
- [ ] Seal: record through `SessionRecorder`; assert incremental == one-pass; a tampered log fails.
- [ ] Golden corpus: a committed fixture + a decode/re-encode byte-identity assertion.
- [ ] Migration table (once a payload evolves): single-step, target from `currentVersion`.
- [ ] Target depends on `ReplayCore` only; tests use `import ReplayCore`, never `@testable`.

If every box is ticked and the suite is green, ReplayCore can host your simulation — as it hosts ATC, and as it
hosted GridBot without changing a line.
