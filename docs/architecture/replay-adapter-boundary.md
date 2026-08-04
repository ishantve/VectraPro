# The ReplayCore ⇄ Adapter Boundary

**Status:** permanent architectural contract. Written during R2b, before the vocabulary migration.
**Governing principle:** *ReplayCore routes payloads. Adapters interpret payloads.*

This is the document another engineer reads to build an adapter for a different simulation. It is written to be
sufficient on its own: nothing here requires reading ReplayCore's internals, and if it ever does, that is a defect
in this document rather than a gap in the reader.

---

## 1 · The boundary in one table

| | ReplayCore | Adapter |
|---|---|---|
| **Knows** | envelopes, ordering, timing, routing, sealing, storage, verification, replay policy | what a payload *means* |
| **Never knows** | what a payload means | how events are framed, sealed, ordered or stored |
| **Owns on the wire** | the envelope: schema version, type tag, payload version, tick, ordinal, source, ids, wall clock | the payload object, and the tag numbers that name its kinds |
| **Owns in time** | when a tick happens, when an event is due, what order events apply in | what applying an event does |
| **Owns in trust** | that bytes are intact and a seal verifies | that a payload is meaningful and valid |

The dividing question is always: **could another deterministic simulation need this?** If yes, ReplayCore. If it
only makes sense once you know what the simulation simulates, the adapter.

---

## 2 · What ReplayCore requires from an adapter

Four things, and deliberately no more. Each is a protocol the adapter conforms to.

### 2.1 Payload coding — required

```
func tag(for payload: Payload) -> EventTypeTag
func currentVersion(for tag: EventTypeTag) -> Int
func object(for payload: Payload) throws -> [String: Any]
func payload(from object: [String: Any], tag: EventTypeTag, version: Int) throws -> Payload
```

The core hands over a JSON object and a tag; the adapter returns a payload, or throws. The core never inspects the
object. Dictionaries rather than `Data` on purpose: the core owns the outer object and the sorted-key ordering the
seal depends on, and handing an adapter raw bytes would let it decide framing that is not its business.

### 2.2 Replay policy by tag — required

```
func affectsSimulation(tag: EventTypeTag) -> Bool
```

**By tag, never by decoded payload.** This is the single most consequential signature in the platform. A build that
cannot decode a payload written by a newer build must still be able to replay the recording correctly, and that is
only possible if the skip-or-apply decision never required decoding. Requiring a payload here would silently make
every recording unreadable by every older build.

### 2.3 Event application — required for replay

```
func apply(_ payload: Payload, at position: EventPosition) throws
```

How a recorded input re-enters the world. The core calls this for events whose tag affects the simulation, in
recorded order, at the tick they were issued. The core does not know or care what happens inside.

### 2.4 Migration table — optional

```
var migrations: [EventTypeTag: [Int: EventMigration]] { get }
```

Keyed by tag then by from-version. Absent means "no payload has ever changed shape". The core applies migrations
before calling `payload(from:tag:version:)`, so an adapter's decoder only ever sees the current shape.

---

## 3 · What an adapter provides that ReplayCore does not ask for

These are the adapter's own business. ReplayCore has no opinion and no hook.

| Responsibility | Why it is the adapter's |
|---|---|
| **Input translation** — turning a UI action, a transcript or a network message into a payload | Only the domain knows what its inputs are. ATC turns phraseology plus a resolved callsign into `commandIssued`; a racing adapter would turn a steering sample into something else entirely. |
| **Payload validation** — rejecting a nonsensical instruction | Validity is semantic. The core's only validity question is "are these bytes intact", answered by the frame's crc32 and the seal. |
| **Event interpretation** — deciding what an event implies | This is the definition of payload semantics. |
| **Event execution** — changing the world | The core advances ticks; the adapter changes state. |
| **Scenario decoding** — turning embedded configuration bytes into a world | The core embeds and hands back bytes precisely so it never has to understand them. |
| **Fingerprint composition** — what to include and how to quantise | Which fields matter, and to what precision, is a domain judgement. The core only compares. |
| **Side-effect binding** — which real-world effects the gate suppresses | The core owns the three modes; what counts as an effect is domain-specific. |

---

## 4 · Responsibilities that permanently belong to ReplayCore

Permanent means: an adapter may not override these, and a future domain requirement is not a reason to move them.

| Responsibility | Why it can never be an adapter's |
|---|---|
| **Envelope format** | It is the compatibility contract. One writer, or recordings diverge per adapter. |
| **Ordering** | `(tick, ordinal)` is the only ordering authority. An adapter that reordered would make replay non-deterministic. |
| **Timing** | `SimulationClock` is the only time. Speed changes the interval, never the step. |
| **Routing** | Which events reach the simulation, and when, follows from tag plus position — envelope data only. |
| **Sealing and verification** | Incremental and one-pass forms must agree; two implementations would make assessments unverifiable. |
| **Storage and framing** | magic, length prefix, crc32, truncation recovery. |
| **Session lifecycle** | The FSM, including which transitions are illegal. |
| **Branching** | Fork, input-prefix copy, lineage. Independent of what the inputs mean. |
| **Identity** | `EventID` derived from `(session, ordinal)`; `SessionID`; `OwnerID`. |
| **Retention and policy enforcement** | Flush-per-event, must-seal, allows-branching. The adapter *chooses* a policy; the core *enforces* it. |

---

## 5 · Version migration: who owns which half

A genuine split, and the one most likely to be got wrong.

- **ReplayCore owns envelope versioning.** `schemaVersion` describes the envelope's own shape. If the core changes
  the envelope, the core migrates it, and adapters are unaffected.
- **The adapter owns payload versioning.** `eventVersion` describes a payload's shape *for one tag*. If the adapter
  changes a payload, the adapter supplies the migration.
- **The core owns the plumbing.** It reads the versions, selects migrations from the adapter's table, applies them
  in order, and only then calls the adapter's decoder.

Consequence worth stating: an adapter can evolve its payloads without a ReplayCore release, and ReplayCore can
evolve its envelope without every adapter re-releasing. That independence is the point of two version numbers.

---

## 6 · Replay policy: who decides what

| Decision | Decided by | Communicated how |
|---|---|---|
| Does this event feed the simulation? | Adapter | `affectsSimulation(tag:)` — envelope only |
| Is this session an assessment? | Adapter | `SessionPolicy` at session start |
| Must every event reach disk before the next is accepted? | Adapter chooses, core enforces | `SessionPolicy.flushEveryEvent` |
| May this session be branched? | Adapter chooses, core enforces | `SessionPolicy.allowsBranching` |
| When does a tick happen? | **Core only** | not negotiable |
| In what order do events at one tick apply? | **Core only** | `(tick, ordinal)` |
| Is this recording scoreable here? | **Core only** | architecture equality in the manifest |

---

## 6a · Ownership Decision Matrix

For classifying **new** functionality without relying on architectural intuition. Answer the questions in order and
stop at the first that applies — they are ordered so the strongest constraint wins.

| # | Question | If yes → | Why this order |
|---|---|---|---|
| 1 | Would it let ReplayCore reach a concrete adapter type, an app type, or a simulation package? | **Never allowed** | Structural. It would reverse the dependency graph and no later cleanup recovers it. |
| 2 | Would it let an adapter change envelope format, ordering, tick timing, framing, or the seal? | **Never allowed** | These are the compatibility contract. Two writers means recordings diverge per adapter and assessments stop being verifiable. |
| 3 | Does it require understanding what a payload *means*? | **Adapter** | The governing principle. Includes interpretation, execution, validation, and any decision read out of payload contents. |
| 4 | Does it require executing simulation behaviour or mutating the world? | **Adapter** | The core advances ticks; only the adapter changes state. |
| 5 | Does it require domain validation — is this instruction sensible? | **Adapter** | Validity is semantic. The core's only validity question is "are these bytes intact". |
| 6 | Does it require deterministic replay **ordering**? | **ReplayCore** | `(tick, ordinal)` is the single ordering authority. |
| 7 | Does it require deterministic **timing**? | **ReplayCore** | `SimulationClock` is the only time; speed changes the interval, never the step. |
| 8 | Does it require **storage** — framing, appending, truncation recovery, indexing? | **ReplayCore** (contract) + **ReplayPersistence** (implementation) | The contract is the core's; a consumer may bring their own store behind it. |
| 9 | Does it require replay **verification** — sealing, digest comparison, scoreability? | **ReplayCore** | Incremental and one-pass forms must agree; a second implementation makes assessments unverifiable. |
| 10 | Does it require replay **transport** — play, pause, seek, speed, position? | **ReplayCore** | `ReplayClock` is the single authority, all the way to the presentation layer. |
| 11 | Does the core need a fact to route or schedule, but only the domain can supply it? | **Shared contract** | Promote it into the envelope and answer it *by tag*, never by payload. `affectsSimulation` is the worked example. |
| 12 | Is it a *choice* the domain makes but the core must *enforce*? | **Shared contract** | `SessionPolicy` — flush-per-event, must-seal, allows-branching, retention. Adapter chooses; core enforces. |
| 13 | Would another deterministic simulation need it, expressed without domain nouns? | **ReplayCore** | The general test, applied only after the specific ones above. |
| 14 | Anything else | **Adapter** | The default is the adapter. A thing that cannot be justified as generic is not generic. |

### Worked examples

| Proposed feature | Path | Owner |
|---|---|---|
| "Record which runway was in use" | Q3 — needs payload meaning | Adapter |
| "Skip audio-only events when seeking" | Q11 — core schedules, domain classifies by tag | Shared contract |
| "Encrypt the event log at rest" | Q8 — storage | ReplayCore contract + Persistence |
| "Warn if a trainee paused more than ten times" | Q3 — reads recorded meaning | Adapter (from `TimelineAction`, which the core records) |
| "Let an assessment forbid branching" | Q12 — domain chooses, core enforces | Shared contract (`SessionPolicy`) |
| "Let an adapter renumber its own event tags" | Q2 — tags are on disk | Never allowed |
| "Add a per-aircraft snapshot every 60 ticks" | Q3/Q4 — capture is domain, cadence is core | Split: core owns `ReplaySnapshotting` + trigger, adapter owns capture |
| "Expose replay position to a Unity UI" | Q10 — transport | ReplayCore (via the Codable boundary) |

### The tie-breaker

When two answers seem to apply, ask: **does this decision have to be identical for every adapter, or may it differ
per simulation?** Must be identical → ReplayCore. May differ → adapter. Must differ per simulation *but* the core
depends on it → shared contract, promoted into the envelope.

---

## 6b · The adapter speaks its simulation's language

A permanent principle, and the reason `ATCEvent` exists in the shape it does.

**An adapter's public API names facts that occurred. It never names how replay stores them.**

```
ATCEvent.commandIssued(code:callsign:slots:at:)      ✓ a fact
ATCEvent.aircraftSpawned(...)                        ✓ a fact
ATCEvent.makeEvent(kind:payloadObject:version:)      ✗ replay mechanics
ATCEvent.encodePayload(...)                          ✗ replay mechanics
```

Future adapters follow the same pattern without needing to be told: `RacingEvent.lapStarted(...)`,
`MedicalEvent.procedureCompleted(...)`, `RobotEvent.taskAssigned(...)`. Each speaks its own domain.

**The two vocabularies are meant to stay different.** ReplayCore says *envelope, tag, ordinal, tick, seal, position*.
An adapter says *command, callsign, lap, procedure, task*. Where a word from one appears in the other's public API,
that is a coupling to look at — a core API naming a callsign is a leak, and an adapter API naming a payload version
is mechanics escaping upward.

The practical payoff is the one R2b relies on: because call sites name intents, the payload representation
underneath can change from a core enum to an opaque body and **no call site moves**. An API named after mechanics
would not have that property, which is why "is this a fact or a mechanism?" is the review question for every new
adapter function.

---

## 7 · Dependency diagram

```
        ┌───────────────────────────────────────────────┐
        │ ReplayCore                    (Foundation)    │
        │ envelope · ordering · timing · routing ·      │
        │ sealing · storage · lifecycle · branching     │
        └───────────────▲───────────────────┬───────────┘
                        │ (A) conforms      │ (B) calls
                        │     to protocols  │     adapter hooks
        ┌───────────────┴───────────────────▼───────────┐
        │ ATCReplayAdapter                              │
        │ ATCEventCodec · tags 1…7 · migrations ·       │
        │ ATCEventApplier · ATCScenarioDecoder ·        │
        │ side-effect binding · SessionPolicy choice    │
        └───────────────▲───────────────────┬───────────┘
                        │ (C) reads world   │ (D) drives world
        ┌───────────────┴───────────────────▼───────────┐
        │ ATCSimKit  (+ app: MapViewModel, Commands)    │
        │ aircraft · physics · spawning · fingerprint   │
        └───────────────────────────────────────────────┘
```

Every crossing, and whether it is meant to last:

| # | Crossing | Why it exists | Why it belongs on that side | Stable? |
|---|---|---|---|---|
| **A** | Adapter → ReplayCore protocols | The core must be told how to code payloads, whether a tag affects the simulation, and how to apply one | Upward conformance keeps the core's dependency count at zero; the core names the contract, the adapter satisfies it | **Yes** — this is the platform's public surface |
| **B** | ReplayCore → adapter hooks | Replay is a loop the core drives; it must call out at the points only the domain can answer | Inversion, not a dependency: the core holds an existential it was handed, never a concrete adapter type | **Yes** |
| **C** | Adapter → ATCSimKit / app types | The adapter must read aircraft to resolve a callsign and compose a fingerprint | This is the adapter's whole reason to exist; ATC knowledge has to live somewhere and this is that somewhere | **Yes**, and deliberately the *only* place this direction is allowed |
| **D** | Adapter → world mutation | Applying a recorded instruction means executing it, through `CommandController.perform` — the one authoritative path | Execution is domain behaviour; routing it there is the core's job, doing it is not | **Yes** |

**Crossings that must never exist:** ReplayCore → ATCSimKit, ReplayCore → app, ReplayCore → any concrete adapter
type, adapter → ReplayCore internals. The first three are structurally impossible once the vocabulary moves, because
ReplayCore's package has no dependency to express them. The fourth is a review rule.

---

## 8 · The reference-adapter test

R2b is not complete until an engineer can build an adapter for an unrelated simulation by reading only ReplayCore's
public API and `ATCReplayAdapter`. Concretely, they must be able to answer without opening core internals:

1. Which protocols must I conform to? (§2 — four, one optional)
2. What does the core do with what I give it? (§4)
3. What am I responsible for that the core will not do? (§3)
4. Who migrates what when a format changes? (§5)
5. What am I forbidden from influencing? (§6, "Core only" rows)

If any answer requires reading `EventCoder`, `EventStore` or `SessionManager`, this document is incomplete and that
is the defect to fix — not the reader's problem.

---

## 9 · Compatibility gates, restated as the definition of done

R2b succeeds only if **all** of these hold:

- Golden corpus byte-for-byte identical.
- Replay fingerprint gate green.
- Existing recordings replay identically.
- Existing seals verify.
- ReplayCore contains no ATC payload semantics — no `EventPayload`, no `EventKind`, no per-kind version table.
- The envelope remains readable without decoding any payload.

Compatibility outranks cleanliness. A recording cannot be reconstructed once it is unreadable; ReplayCore can always
be made cleaner later.
