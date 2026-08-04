# Extracting ReplayCore — a Domain-Agnostic Replay Platform

**Status:** architecture proposal. No code written. **Date:** 4 August 2026.
**Baseline:** branch `ReplayLogic` at `f028152`, replay system engineering-complete.

---

## 0 · The finding that shapes everything

Before any plan: I inventoried every public type in `ATCReplayKit` and every replay type in the app. The result is
better than expected in one way and worse in another, and both change the shape of this project.

**Better:** `ATCReplayKit` imports **only `Foundation` and `CryptoKit`**. It has no dependency on `ATCSimKit`, no
aircraft, no `MapViewModel`, no phraseology. Of its 39 public types, **31 are already fully generic**. The session
model, lifecycle FSM, manifest, envelope, event id derivation, source attribution, seal, catalogue, store,
branching and retention are domain-agnostic today. This was not luck — it came from the layering rule that the
package must not know about aircraft — but it means the extraction is mostly **relabelling, not redesign**.

**Worse:** there is exactly one hard blocker, and it is load-bearing.

```swift
public enum EventPayload {            // closed enum, ATC vocabulary
    case commandIssued(code: String, callsign: String, slots: [String: String])
    case commandRejected(code: String?, callsign: String?, reason: String)
    case transcriptReceived(raw: String, normalized: String)
    case readbackSpoken(callsign: String, spoken: String)
    case weatherChanged(windDegrees: Int?, windKnots: Int?, visibilityMetres: Int?, qnh: Int?)
    case scoreEvaluated(value: Int, rulesVersion: String)
    case timelineAction(TimelineAction)
}

public enum EventKind: UInt16 { case commandIssued = 1, ... , timelineAction = 7 }
```

`EventKind`'s numbers are **written into every recording on disk**. `EventPayload.affectsSimulation` — the property
that lets replay skip audio events and stay correct — is *derived from the case*, so today the core decides which
events matter by reading ATC vocabulary.

So the real project is not "move files into packages". It is: **make the payload opaque to the core without
invalidating a single existing recording.** Everything else in this document is comparatively easy, and I have
sequenced the plan so that this problem is confronted early rather than discovered late.

One more finding worth stating: the determinism primitives the platform depends on — `SimulationClock`,
`RandomStreams`, `StateHash`, `DeterminismSelfCheck` — do **not** live in `ATCReplayKit`. They live in `ATCSimKit`,
mixed in with aircraft simulation. A replay platform whose determinism contracts sit in someone else's package is
not a platform. They must move.

---

## 1 · Current dependency graph

```
┌─────────────────────────────────────────────────────────────────────┐
│ VectraPro (app target)                                              │
│                                                                     │
│  MapScreen ──────────────┐                                          │
│  HomeScreen ─────────────┤                                          │
│  ReplayBrowserView ──────┤   SwiftUI                                │
│  ReplayTransportBar ─────┘                                          │
│         │                                                           │
│         ▼                                                           │
│  ReplayTransport ──▶ ReplayEngine ──▶ MapViewModel  ◀── ATC world   │
│         │                 │      └──▶ CommandController             │
│         ▼                 │      └──▶ ExerciseDetail (NetworkKit)   │
│  ReplayClock ◀────────────┘      └──▶ AircraftSpawner               │
│                           │                                         │
│  InputGateway ────────────┤                                         │
│  SideEffectGate ──────────┤                                         │
│  SessionCoordinator ──────┘                                         │
└────────────┬───────────────────────────────┬────────────────────────┘
             │                               │
             ▼                               ▼
   ┌──────────────────────┐        ┌──────────────────────┐
   │ ATCReplayKit         │        │ ATCSimKit            │
   │ Foundation, CryptoKit│        │ SimulationClock      │
   │                      │        │ RandomStreams        │
   │ Session, Lifecycle   │        │ StateHash            │
   │ Event, EventKind ◀───┼─ ATC   │ DeterminismSelfCheck │
   │ EventEnvelope        │  vocab │ + aircraft simulation│
   │ Manifest, Scenario   │        └──────────────────────┘
   │ Catalogue, Store     │
   │ Recorder, Seal       │        ┌──────────────────────┐
   │ BranchManager        │        │ ATCReplayStore       │
   │ SessionManager       │◀───────│ SQLite catalogue     │
   └──────────────────────┘        └──────────────────────┘
```

**What this graph shows.** The dependency *directions* are already correct — nothing in `ATCReplayKit` points
upward. Three problems are visible:

1. ATC vocabulary sits **inside** the bottom package (`EventKind`, `EventPayload`).
2. The determinism contracts sit in a **sibling** package that also contains the ATC simulation.
3. `ReplayEngine`, `ReplayClock` and `ReplayTransport` — the most reusable machinery in the whole system — sit in
   the **app target**, where no other product can reach them.

---

## 2 · Target dependency graph

```
                      ┌────────────────────────────────────┐
                      │ ReplayCore          (Foundation)   │
                      │                                    │
                      │ · Determinism: Clock, Streams,     │
                      │   Fingerprint, SelfCheck           │
                      │ · Session, Lifecycle, Manifest     │
                      │ · Envelope, EventID, EventSource   │
                      │ · OpaquePayload + codec contract   │
                      │ · Engine, Timeline, Recorder       │
                      │ · Branching, Continue              │
                      │ · Transport model (state+commands) │
                      │ · Seal + Snapshot contracts        │
                      │ · Metrics contracts                │
                      │                                    │
                      │ Protocols only, no domain types    │
                      └───┬────────────┬───────────┬───────┘
                          │            │           │
        ┌─────────────────▼──┐  ┌──────▼───────┐ ┌─▼─────────────────┐
        │ ReplayPersistence  │  │ ReplayUI     │ │ ReplayTesting     │
        │ framed log store   │  │ SwiftUI      │ │ contract suites   │
        │ SQLite catalogue   │  │ transport,   │ │ determinism gate  │
        │ (libsqlite3)       │  │ browser      │ │ store/catalogue   │
        └─────────────────┬──┘  └──────┬───────┘ └─┬─────────────────┘
                          │            │           │
                          │     ┌──────▼───────┐   │
                          │     │ ReplayMetrics│   │
                          │     │ measurement  │   │
                          │     └──────┬───────┘   │
                          │            │           │
                    ┌─────▼────────────▼───────────▼─────┐
                    │ ATCReplayAdapter                   │
                    │                                    │
                    │ · ATCEventCodec (tags 1…7)         │
                    │ · ATCSimulation : ReplaySimulation  │
                    │ · ATC side-effect gate binding      │
                    │ · Exercise ⇄ ReplayScenario         │
                    │ · SessionCoordinator (app policy)   │
                    └─────────────────┬──────────────────┘
                                      │
                    ┌─────────────────▼──────────────────┐
                    │ VectraPro (ATC Simulator)          │
                    │ MapViewModel, CommandController,    │
                    │ AircraftSpawner, screens            │
                    └────────────────────────────────────┘
```

`ReplayCore` depends on nothing but `Foundation`. Every arrow points down. The ATC simulator becomes **one adapter**
of six packages, exactly as required.

---

## 3 · Generic architecture

### 3.1 The five contracts that carry the platform

Everything else is detail. These five are the platform.

**`ReplaySimulation`** — what the core drives. The core never asks what a tick *means*.

```
protocol ReplaySimulation
    associatedtype Scenario                      // domain config, decoded by the domain
    func prepare(scenario: Scenario, seed: UInt64) throws
    mutating func advanceOneTick()
    var tick: Int { get }
    var fingerprint: SimulationFingerprint { get }
```

`prepare` replaces today's `reset(seed:)`. `fingerprint` is what makes determinism checkable — the core compares
them; only the domain knows what to include. `advanceOneTick` is deliberately argument-free: a tick is a tick.

**`ReplayEventCodec`** — the answer to §0. The core holds bytes and a tag; the domain owns meaning.

```
protocol ReplayEventCodec
    associatedtype Payload
    func tag(for payload: Payload) -> EventTypeTag        // stable UInt16, domain-owned
    func encode(_ payload: Payload) throws -> Data
    func decode(tag: EventTypeTag, version: UInt16, body: Data) throws -> Payload
    func affectsSimulation(tag: EventTypeTag) -> Bool     // by TAG, not by decoded value
```

The last line is the subtle one and it is not cosmetic. Today `affectsSimulation` reads a decoded enum case. If the
generic version required decoding, a build that could not decode a newer payload could not decide whether to skip
it — and "read the envelope without decoding the payload" is a property the current design paid for deliberately.
Deciding **by tag** preserves it. New recordings will additionally carry the bit in the envelope so a consumer with
no codec registered can still replay-skip correctly; old recordings get it from the ATC codec's tag table.

**`ReplayEventApplying`** — how a recorded input re-enters the world.

```
protocol ReplayEventApplying
    associatedtype Payload
    func apply(_ payload: Payload, at position: EventPosition) throws
```

This is where `ReplayEngine`'s current `injectCommand` goes, and it is the only place the ATC adapter needs to know
about callsigns and `CommandController`.

**`ReplaySideEffectGating`** — already exists conceptually as `SideEffectGate`; becomes a contract with the same
three modes (`live` / `replaying` / `suppressed`) and the same scoped `suppressing {}`. Generic: every simulation
has effects that must not re-fire on a scrub.

**`ReplayEventStoring`** / **`ReplaySessionCatalogue`** — persistence contracts. The second already exists as a
protocol with two conforming implementations and a shared contract test; the first is currently a concrete class and
becomes a protocol so a consumer can supply their own storage.

### 3.2 What genericising the payload actually costs

The event envelope stays exactly as it is — `schemaVersion`, `eventType`, `eventVersion`, position, source, ids.
Only the payload's *interpretation* moves out. Concretely:

| Concern | Today | After |
|---|---|---|
| Payload type | closed `enum EventPayload` in core | `Data` + `EventTypeTag` in core; typed `Payload` in the adapter |
| `affectsSimulation` | computed from the enum case | codec's tag table; explicit envelope bit for new writes |
| Wire tags 1…7 | `EventKind` in core | reserved and owned by `ATCEventCodec`; core reserves nothing |
| Migrations | `EventMigration` keyed by version | unchanged; already dictionary-based and payload-opaque |
| Existing files | — | **read unchanged**, because the envelope format does not move |

That last row is the acceptance criterion for the whole phase, and §7 says how it is proved.

### 3.3 Generic session classification

`SessionClass.training` / `.assessment` is not ATC-specific but it is *training*-specific. A racing simulator has
"practice" and "qualifying"; a medical simulator has "rehearsal" and "certification". Rather than pick a vocabulary
for everyone, the core takes:

- `ReplaySessionClass` as an **extensible constant** (the pattern `EventSource` already uses — a struct, not an
  enum — so a consumer adds one without a core change and old recordings stay readable), and
- `SessionPolicy`, a value the domain supplies, carrying the behaviours that today are inferred from the class:
  `flushEveryEvent`, `requiresSeal`, `allowsBranching`, `retention`.

This is a genuine improvement, not just relabelling: today "assessment ⇒ flush per event ⇒ must seal" is knowledge
spread across `SessionRecorder`, `EventStore` and `SessionCoordinator`. Making it one value makes it one decision.

`EmbeddedExercise` becomes `ReplayScenario` — the same three fields (payload bytes, id, name), the same reason for
embedding rather than referencing, and no exercise vocabulary.

### 3.4 Generic over the simulation, erased at the bridge

`ReplayEngine<S: ReplaySimulation, C: ReplayEventCodec>` — generics, not existentials, so there is no per-tick
dynamic dispatch on the hot path. Measured cost today is 39.8 µs/tick; I am not willing to spend any of it on
witness tables.

For React Native / Unity / a future C API, a separate `AnyReplaySession` facade erases the generics and exposes the
already-`Codable` transport boundary. Erasure at the bridge, not in the engine.

---

## 4 · Adapter architecture

`ATCReplayAdapter` is where every ATC noun goes.

| Adapter component | Wraps / replaces | Knows about |
|---|---|---|
| `ATCEventCodec` | today's `EventPayload`, `EventKind`, `TimelineAction` | phraseology codes, callsigns, slots, readbacks, weather, scores |
| `ATCSimulation` | `MapViewModel` conformance to `ReplaySimulation` | aircraft, spawner, fixes, runways |
| `ATCEventApplier` | `ReplayEngine.injectCommand` | `CommandController.perform`, callsign resolution, selection |
| `ATCScenarioDecoder` | `ReplayEngine.decodeExercise` | `ExerciseDetail`, `ExerciseDetailResponse`, NetworkKit shapes |
| `ATCSideEffectBinding` | `SideEffectGate` ⇄ `CommandFeedback` | readbacks, deferred reports, speech |
| `SessionCoordinator` | stays app-side | Application Support paths, auth owner id, exercise names |

Note `MapViewModel` conforms to `ReplaySimulation` **in the adapter, by extension** — the view model is not moved,
renamed, or restructured. That is what keeps "do not change ATC behaviour" cheap to honour.

The current `ReplayEngine` is ~430 lines. My reading is that roughly 330 are generic mechanics (load, step,
schedule, run, seek, play/pause, continue/fork) and roughly 100 are ATC (exercise decode, callsign resolution,
command injection, announce assertion). The adapter is small. That is the payoff of having had one authoritative
execution path all along.

---

## 5 · Package structure

| Package | Depends on | Why it exists separately |
|---|---|---|
| **ReplayCore** | Foundation | The platform. Must be importable by a consumer with no storage choice made, no UI, and no test dependency. Foundation-only is what makes a future C API and a Linux/server-side scorer possible. |
| **ReplayPersistence** | ReplayCore, libsqlite3 | A system-library dependency must not be forced on a consumer who wants their own store (in-memory, cloud, Core Data). Also lets the framed-log format be versioned independently of the model. |
| **ReplayUI** | ReplayCore | SwiftUI. A Unity or React Native consumer must be able to take the platform without any Apple UI framework. Optional by construction, and already proven disposable by the source-scan test. |
| **ReplayTesting** | ReplayCore, XCTest | **The most valuable package for a third party.** Ships the determinism gate, the fingerprint-equality harness, the catalogue contract suite and the store contract suite, so a new adapter can *prove* it is deterministic instead of hoping. Separate because XCTest must not be linked into a shipping app. |
| **ReplayMetrics** | ReplayCore | Overhead/memory/storage/seal measurement harness. Separate because it is a development tool, and because a consumer should be able to reproduce our numbers on their own simulation. |
| **ATCReplayAdapter** | ReplayCore, ReplayPersistence, ATCSimKit | Local package, not published. Contains everything ATC. Its existence is the proof the extraction worked: if something ATC cannot be expressed here, the abstraction is wrong. |

`ATCSimKit` keeps the aircraft simulation. Its determinism primitives move to `ReplayCore` with `typealias`es left
behind, so no app file changes import lines in that step.

---

## 6 · Migration matrix

Classification of every public type. **Risk** is the risk of *changing behaviour*, not of effort.

### 6.1 `ATCReplayKit` → ReplayCore, unchanged (generic today)

| Type | Target | Reason | Risk | Depends on |
|---|---|---|---|---|
| `Session`, `SessionState`, `SessionOrigin` | ReplayCore | No domain vocabulary; a session is a session | **None** — move only | — |
| `SessionLifecycle`, `SessionStateError` | ReplayCore | Generic FSM over generic states | **None** | Session |
| `EventPosition`, `EventID`, `EventSource` | ReplayCore | Ordering, identity, attribution — all generic | **None** | — |
| `EventEnvelope`, `EventSchemaError` | ReplayCore | Versioning shell, payload-opaque already | **Low** — format must not shift | EventPosition |
| `EventMigration`, `EventMigrator` | ReplayCore | Dictionary-keyed, already payload-agnostic | **None** | Envelope |
| `SessionManifest`, `ManifestError` | ReplayCore | Seed, owner, environment, digest | **Low** — field rename only | Scenario, OwnerID |
| `RecordingEnvironment` | ReplayCore | Build + architecture reproducibility | **None** | — |
| `OwnerID` | ReplayCore | user/device identity is generic | **None** | — |
| `SessionSealBuilder`, `SessionSeal`, `SHA256` | ReplayCore | Incremental hashing, no domain | **None** | CryptoKit → keep or vendor |
| `SessionSummary`, `CatalogueError` | ReplayCore | Row model | **None** | Session, Manifest |
| `SessionCatalogue` (protocol) | ReplayCore | Already an abstraction | **None** | Summary |
| `InMemorySessionCatalogue` | ReplayCore | Reference implementation + test double | **None** | Catalogue |
| `BranchManager`, `BranchError` | ReplayCore | Fork + input-prefix copy are generic | **Low** | SessionManager |
| `SessionManager`, `SessionManagerError` | ReplayCore | Lifecycle orchestration, paths injected | **Medium** — touches disk layout | Catalogue, Store |
| `RetentionPolicy` | ReplayCore | Generic, becomes part of `SessionPolicy` | **None** | — |
| `SessionRecorder` | ReplayCore | Framing + seal feed; payload-opaque after §3.2 | **Medium** | Store, Seal, Codec |
| `EventCoder` | ReplayCore | Envelope coding; payload delegated to codec | **High** — wire format | Envelope, Codec |
| `EventStoreError` | ReplayCore | — | **None** | — |

### 6.2 `ATCReplayKit` → **split**: envelope generic, vocabulary to the adapter

| Type | Target | Reason | Risk | Depends on |
|---|---|---|---|---|
| `Event` | ReplayCore (envelope) + adapter (typed payload) | Position/source/ids generic; payload is domain | **High** | Codec |
| `EventPayload` | **ATCReplayAdapter** | Every case is ATC vocabulary | **High** — wire tags are on disk | ATC types |
| `EventKind` (1…7) | **ATCReplayAdapter** | Numbers are committed to stored files; adapter must own them forever | **High** | — |
| `TimelineAction` | ReplayCore | Pause/resume/speed/seek are platform concepts, not ATC | **Low** | — |
| `EmbeddedExercise` | ReplayCore as `ReplayScenario` | Same shape, exercise vocabulary dropped | **Low** — rename | — |
| `SessionClass` | ReplayCore as extensible `ReplaySessionClass` + `SessionPolicy` | Training vocabulary, not ATC; behaviours consolidated | **Medium** | Policy |

### 6.3 `ATCReplayStore` → ReplayPersistence

| Type | Target | Reason | Risk | Depends on |
|---|---|---|---|---|
| `SQLiteSessionCatalogue` | ReplayPersistence | System library dependency isolated | **None** — move only | libsqlite3, Catalogue |
| `EventStore` (class) | ReplayPersistence + `ReplayEventStoring` protocol in Core | Framed-log implementation is a choice; the contract is not | **Medium** | Envelope |

### 6.4 App target → ReplayCore

| Type | Target | Reason | Risk | Depends on |
|---|---|---|---|---|
| `ReplayClock` | ReplayCore | Zero domain knowledge; the single authority is a platform concept. Drop `ObservableObject`; Core exposes observation without Combine so non-Apple bridges work | **Medium** — SwiftUI observation must keep working | — |
| `ReplayTransportState`, `ReplayCommand` | ReplayCore | Already `Codable`, already domain-free, already designed as the portable boundary | **None** | Clock |
| `ReplayTransport` | ReplayCore | Thin, generic over engine | **Low** | Engine |
| `InputGateway`, `SimulationInput`, `InputReceipt` | ReplayCore | Ordinal stamping, no wall clock, no domain — generic input intake. `SimulationInput`'s payload becomes the codec's `Payload` | **Medium** | Codec |
| `SideEffectMode` | ReplayCore | Three generic modes | **None** | — |
| `ReplayEngine` | **split** ~330 generic / ~100 ATC | Load, step, schedule, seek, play, continue are mechanics; exercise decode, callsign resolution, injection are domain | **High** — the behavioural heart | Simulation, Codec, Applier |

### 6.5 App target / ATCSimKit → stays ATC or becomes adapter

| Type | Target | Reason | Risk |
|---|---|---|---|
| `SideEffectGate` | ATCReplayAdapter | Conforms to `CommandFeedback`; ATC-shaped | **Low** |
| `SessionCoordinator` | App | Application Support paths, auth owner, exercise naming | **None** |
| `CommandController`, `CommandTemplateStore`, `KeyboardCommandCatalog`, `DeferredReportCoordinator` | App, unchanged | Pure ATC | **None** |
| `MapViewModel`, `AircraftSpawner` | App, unchanged; conformance added by extension in adapter | Not moved, not restructured | **Low** |
| `SimulationClock` | ReplayCore | 1 tick = 1 unit, speed changes interval not step — the platform's central contract | **Medium** — widely imported | |
| `RandomStreams`, `SeededGenerator` | ReplayCore | Per-subsystem seeded streams; stream *names* stay a domain concern | **Medium** | |
| `StateHash` | ReplayCore as `SimulationFingerprint` | Quantisation policy stays with the domain; FNV-1a machinery is generic | **Medium** | |
| `DeterminismSelfCheck` | ReplayCore contract + ATC golden value | The mechanism is generic; `0x95A9…` is an ATC fact | **Low** | |
| `ReplayBrowserView`, `SessionRow`, `ReplayTransportBar` | ReplayUI (generic parts) | Rows render generic summary fields; exercise-name filter is a parameter already | **Low** | |
| `ExerciseCard`, `MapScreen`, `HomeScreen` | App, unchanged | ATC screens | **None** |

**Totals:** 31 types move unchanged · 8 need genuine design work · 6 stay ATC. Four items carry **High** risk and
all four are the same problem wearing different hats: the on-disk event format.

---

## 7 · Migration plan

Every phase compiles, passes all suites, and preserves behaviour. The **replay fingerprint gate runs at every
phase** — a recorded ATC session must still replay to the same fingerprint, and that single test is the safety net
for the entire migration.

### Phase R0 — Freeze the format before touching it *(prerequisite, do not skip)*

Write a **golden corpus**: recordings produced by today's build, committed as binary fixtures, with their expected
event streams and fingerprints. Add a test that reads them and asserts byte-level envelope equality plus replay
fingerprint equality.

Rationale: four High-risk items are all "the wire format must not shift". Right now nothing would tell us if it
did — the tests write and read with the same code, so a symmetric mistake passes. Golden files break that symmetry.
**This is the highest-value step in the project and it produces no architecture.**

Exit: corpus committed; a deliberate one-byte change to the writer fails the test.

### Phase R1 — Split targets in place, no renames

Inside the existing `ATCReplayKit` package, create targets `ReplayCore` and `ReplayPersistence`; move the 31 generic
types and the two storage types. Keep `ATCReplayKit` as an umbrella target that re-exports, so **no app file changes
an import**.

Exit: all suites green; app untouched.

### Phase R2 — Opaque payload *(the hard one)*

Introduce `EventTypeTag`, `ReplayEventCodec`, and envelope-level `affectsSimulation`. Move `EventPayload`,
`EventKind` and their coding into `ATCEventCodec`, registering tags 1…7. Core stops referring to ATC cases.

Exit: golden corpus still reads byte-identically; fingerprint gate green; **no recording written by any prior build
becomes unreadable**. If that cannot be achieved, stop and re-plan — this is the phase that decides whether the
extraction is viable at all.

### Phase R3 — Scenario, class and policy

`EmbeddedExercise` → `ReplayScenario`; `SessionClass` → `ReplaySessionClass` + `SessionPolicy`; consolidate the
flush/seal/branch/retention rules. Leave `typealias`es for one release.

Exit: suites green; manifest schema version bumped with a read-time migration for the renamed keys.

### Phase R4 — `ReplaySimulation` and the engine split *(highest behavioural risk)*

Extract `ReplaySimulation`, `ReplayEventApplying`, `ReplaySideEffectGating`. Make `ReplayEngine` generic. Move the
~100 ATC lines into `ATCEventApplier` and `ATCScenarioDecoder`. `MapViewModel` conforms by extension.

Exit: fingerprint gate green; playback tests green; recording-does-not-change-the-simulation green; measured
per-tick overhead within noise of 39.8 µs.

### Phase R5 — Clock, transport, gateway to Core

Move `ReplayClock`, `ReplayTransportState`, `ReplayCommand`, `ReplayTransport`, `InputGateway`, `SideEffectMode`.
Replace `ObservableObject` with a Core-level observation shim so SwiftUI keeps working without Core importing
Combine.

Exit: transport tests green; the UI-owns-no-state source scan still passes.

### Phase R6 — Determinism primitives out of ATCSimKit

Move `SimulationClock`, `RandomStreams`, `SeededGenerator`, `StateHash`→`SimulationFingerprint`, and the
self-check mechanism. Leave `typealias`es in `ATCSimKit`.

Exit: ATCSimKit's 112 tests green; golden fingerprint `0x95A9_2889_F6E7_9EBC` unchanged.

### Phase R7 — ReplayUI, ReplayTesting, ReplayMetrics, publish

Extract the three remaining packages, write the SDK README and a worked "minimal simulation" sample, tag `1.0.0`,
and — per the standing rule — ship the React Native and Unity wrappers **in the same release**, written against
`ReplayCore` rather than `ATCReplayKit`.

Exit: a sample non-ATC simulation records, replays, seeks, branches and continues without importing anything ATC.

### My recommendation on sequencing

Do **R0–R3 now**. They are cheap, low-risk, and pay off immediately: R0 closes a real hole in the current test
strategy, and R2–R3 remove the only genuine domain leaks from the package.

Hold **R4–R7 until a second consumer is real.** `ReplaySimulation` designed against exactly one simulation is a
guess dressed as an abstraction, and the usual outcome is a contract that fits ATC and nothing else — which is
worse than no contract, because it looks finished. R4 is also where behavioural risk concentrates. If a second
simulation is already planned, say so and I will fold R4 forward; if not, R0–R3 leaves the system strictly better
and R4–R7 fully specified for the day it matters.

---

## 8 · Risk assessment

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Wire format shifts; existing recordings unreadable | Medium | **Critical** — assessments are evidence | Phase R0 golden corpus before any change; byte-level assertions |
| R2 | `affectsSimulation` decided differently after genericising ⇒ replay diverges | Medium | Critical | Decide by tag; assert the tag table against the old enum in a migration test |
| R3 | Per-tick overhead grows from protocol dispatch | Medium | High | Generics not existentials; re-measure at R4 against 39.8 µs |
| R4 | `ReplaySimulation` fits only ATC | **High** | High | Defer R4 until a second consumer; validate with the sample simulation in R7, not with ATC |
| R5 | `ReplayClock` losing `ObservableObject` breaks SwiftUI updates | Medium | Medium | Observation shim; transport tests + a snapshot render |
| R6 | `EventKind` numbers accidentally reused by a future domain | Low | Critical | Tags are per-codec, not global; document 1…7 as ATC-owned |
| R7 | Manifest key renames break the catalogue | Medium | High | Manifest is versioned independently; read-time migration + corpus |
| R8 | Determinism primitives moving changes the golden fingerprint | Low | Critical | Fingerprint asserted before and after R6; no logic edits during a move |
| R9 | Migration stalls half-done, leaving two idioms | Medium | Medium | Umbrella re-export target keeps every phase shippable |
| R10 | Effort spent on a platform with no second consumer | **High** | Medium | Stated plainly above; R0–R3 justified on their own merits |

---

## 9 · Public API proposal

What a third party writes to adopt the platform. Illustrative shape, not final signatures.

```
// 1 · Describe your simulation.
struct MySim: ReplaySimulation {
    typealias Scenario = MyScenario
    func prepare(scenario: MyScenario, seed: UInt64) throws
    mutating func advanceOneTick()
    var tick: Int
    var fingerprint: SimulationFingerprint
}

// 2 · Describe your events.
struct MyCodec: ReplayEventCodec {
    typealias Payload = MyEvent
    func tag(for: MyEvent) -> EventTypeTag
    func encode(_: MyEvent) throws -> Data
    func decode(tag: EventTypeTag, version: UInt16, body: Data) throws -> MyEvent
    func affectsSimulation(tag: EventTypeTag) -> Bool
}

// 3 · Say how a recorded event re-enters the world.
struct MyApplier: ReplayEventApplying { func apply(_: MyEvent, at: EventPosition) throws }

// 4 · Record.
let platform = ReplayPlatform(store: .framedLog(at: url),
                              catalogue: .sqlite(at: url),
                              policy: .practice)
let session = try platform.startRecording(scenario: scenario, seed: seed, owner: owner)
try platform.record(MyEvent.somethingHappened, source: .user)
try platform.stopRecording(tickCount: sim.tick)

// 5 · Replay.
let engine = ReplayEngine(simulation: sim, codec: MyCodec(), applier: MyApplier(), platform: platform)
let loaded = try engine.load(sessionID)
try engine.play()                       // or step / run(to:) / seek(to:) / setSpeed
let branch = try engine.continueLive(label: "what if")

// 6 · Render anything.
engine.transport.state               // ReplayTransportState — Codable
engine.transport.perform(.pause)     // ReplayCommand      — Codable

// 7 · Prove you are deterministic.
ReplayTesting.assertDeterministic(MySim.self, seed: 1, ticks: 2_400)
ReplayTesting.assertReplayReproduces(sessionID, using: engine)
```

Design commitments in that surface:

- **Three protocols to adopt**, not thirteen. The other contracts have defaults or concrete implementations.
- **`ReplayPlatform` is the one façade** for storage and lifecycle, so a consumer never assembles a
  `SessionManager` + `EventStore` + `Catalogue` by hand.
- **`ReplayTesting` is part of the public API**, not a private helper. A replay SDK whose users cannot prove
  determinism has sold them the hard half and kept the tools.
- **Nothing in the surface is SwiftUI.** `ReplayUI` is additive.

---

## 10 · Testing strategy

Current inventory: ATCSimKit 112 · ATCTrafficKit 28 · ATCReplayKit 170 · NetworkKit 4 · app suite (≈14 files).

| Current tests | Destination | Note |
|---|---|---|
| `ATCReplayKit` session/lifecycle/manifest/catalogue/seal/branch/store (~150) | **ReplayCore** + **ReplayPersistence** | Generic already; move with their types |
| Catalogue contract suite (in-memory vs SQLite) | **ReplayTesting**, run by both | Already caught one real divergence; becomes a public contract suite |
| `EventPayload`/`EventKind` coding tests (~20) | **ATCReplayAdapter** | They assert ATC vocabulary |
| Envelope/migration tests | **ReplayCore** | Payload-opaque already |
| `DeterminismTests`, `DeterministicTimeTests` | **ReplayTesting** harness + ATC golden values | Mechanism generic, `0x95A9…` is ATC |
| `ReplayEngineTests`, `ReplayPlaybackTests` | **split** | Mechanics (load, step, order, speed) → Core against a sample sim; ATC specifics (exercise decode, callsign resolution) → adapter |
| `ReplayGateTests` (fingerprint gate) | **stays ATC** and also becomes a **ReplayTesting** template | The ATC instance is the regression guard for the whole migration |
| `ReplayTransportTests`, `ReplayClock` tests | **ReplayCore** | Domain-free |
| `SideEffectBoundaryTests` | **split** | Gate contract → Core; `CommandFeedback` binding → adapter |
| `IsolatedDeinitScanTests`, wall-clock and UI-state scans | **duplicated** | Each package scans its own sources; the rules are per-target |
| `RecordingMetricsTests` | **ReplayMetrics** | Parameterised by simulation |
| `ReplayVisualSnapshotTests` | **ReplayUI** | Renders generic rows; ATC fixtures become sample fixtures |
| `KeypadValidationTests`, `ReplayKitWiringTests` | **app** | ATC |
| **New: golden corpus** | **ReplayCore** (fixtures) + adapter (ATC streams) | Phase R0 |
| **New: sample simulation** | **ReplayTesting** | A ~100-line non-ATC deterministic sim. The only honest proof the core is domain-free |

The last row matters more than its size suggests. Every other test can pass while the core is still secretly
ATC-shaped. A second simulation that records, replays, seeks, branches and continues is the acceptance criterion
for the extraction itself.

---

## 11 · Future extensibility roadmap

- **Snapshots.** Contract in Core from the start (`ReplaySnapshotting`: capture/restore/quantise), implementation
  deferred exactly as today — ≈38 ms worst-case seek does not justify it. A generic platform makes the trigger
  policy per-domain, which is what §7.2 of `replay-engine.md` already wanted.
- **Cloud sync.** `StorageOrigin` and the seal already exist; a `ReplaySyncing` contract in Core lets a consumer
  bring their own backend. Sealed logs are verifiable by the recipient, which is what makes sync safe.
- **Instructor tools.** `AssignmentID` is reserved and unused. Sharing is a persistence + policy concern, so it
  belongs in `ReplayPersistence` plus a domain policy — not in Core.
- **Multiplayer.** Deterministic fixed-step + seeded streams + ordinal-stamped inputs is the standard lockstep
  shape; extraction makes `InputGateway` reusable as the input-exchange point. Missing: transport and a rollback
  policy. `correlationID`/`causationID` were reserved for this.
- **Analytics.** Derive from replayed sessions, never record derived numbers — a derived value can be recomputed
  when rules change. `SessionPolicy` carries the rules version.
- **C API / Unity / React Native.** `AnyReplaySession` erases generics; the transport boundary is already
  `Codable`. Per the standing rule, wrappers ship in the same release as the Core API they expose — and today
  **ATCReplayKit has no RN or Unity wrapper at all**, which is an open debt this extraction is the right moment to
  clear (see §12).
- **Server-side scoring.** Foundation-only Core is what makes a Linux scorer possible: replay a sealed session on a
  server and compute a score without a simulator UI.

---

## 12 · Open questions for you

1. **Is a second simulation real?** This decides R4–R7 now versus later, and it is the single biggest input to the
   plan. My recommendation is R0–R3 now regardless.
2. **Is this an internal platform or a product?** A published SDK needs semantic-version discipline, a deprecation
   policy and the RN/Unity wrappers from day one. Internal-only is materially cheaper.
3. **Who owns the ATC event tags long-term?** I propose the adapter owns 1…7 permanently and Core reserves nothing,
   so no future domain can collide.
4. **`SessionClass` vocabulary.** Confirm that training/assessment becoming an extensible constant plus a policy is
   acceptable, since it is the one place I am proposing to generalise a concept you specified concretely.
5. **RN/Unity wrappers.** Confirmed as owed. Should they target `ReplayCore` after R7 (my recommendation), or
   `ATCReplayKit` sooner?

---

*No code has been written. Nothing in the current ATC replay implementation has been modified. On approval I would
begin with Phase R0, which changes no architecture and closes the format-safety hole that makes every later phase
verifiable.*
