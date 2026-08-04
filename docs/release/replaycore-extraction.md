# ReplayCore Extraction — Release Package

*Companion to the PR `replaycore-base ← GenericReplayEngine`. Points to the two living design documents:
[`replay-adapter-boundary.md`](../architecture/replay-adapter-boundary.md) (the permanent contract) and
[`building-an-adapter.md`](../architecture/building-an-adapter.md) (the how-to).*

---

## 1 · Executive Summary

**ReplayCore is now a generic, simulation-agnostic record/replay/determinism platform. Any deterministic
simulation can record, replay, seal and verify its sessions by writing a small adapter against ReplayCore's
public API — without changing ReplayCore.**

The system began as an ATC-specific recording feature. A recording is *evidence* — an assessment must replay
to the identical world and verify against a tamper-evident seal — and that guarantee is only safe if the
platform that **orders and stores** events is separate from the domain that gives them **meaning**. This work
made that separation real and enforced it with a written contract: *ReplayCore routes payloads; adapters
interpret payloads.*

The proof is not an assertion, it is an executable test. A second, deliberately unrelated simulation —
**GridBot**, a robot on a grid — was built entirely against ReplayCore's public API and driven end to end
(record → replay → seal → deterministic fingerprint → payload migration). **ReplayCore required no change to
host it.** ATC and GridBot now sit as peers on the same platform.

What this unlocks:
- A new simulation (racing, medical, robotics) gets recording, deterministic replay, sealing, branching and a
  transport UI *for free*, by writing one small adapter.
- ReplayCore can evolve its envelope, and an adapter can evolve its payloads, **independently** — two version
  numbers, two owners.
- Recordings outlive the code that wrote them: the on-disk format is frozen behind a golden corpus, and old
  recordings still replay and still verify.

Scope at a glance: **49 commits, 114 files, +18,979 / −221**, all replay + determinism. Everything unrelated
(GeoNavKit, ATCParserKit, SpeechKit, the NetworkKit extraction, MapScreen/parser refactoring) is below the
base branch and excluded from review.

**Status:** the architecture is **frozen** pending review. The next phase, **R4** (making the codec generic),
is **deferred and not started**.

---

## 2 · Architecture Summary

### The one-sentence contract
> **ReplayCore knows envelope, ordering, timing, routing, sealing, storage and lifecycle. An adapter knows
> what a payload means. Neither knows the other's half.**

### Packages and the dependency direction
```
        ReplayCore            (Foundation + CryptoKit only — knows no domain)
          ▲      ▲
   (conforms)  (extracted from)
          │      │
  ATCReplayAdapter   ReplayPersistence   SimDeterminism
  GridBotAdapter          (SQLite)        (seeded RNG, state hash, one clock)
          ▲
   (app builds core values through the adapter)
          │
  VectraPro (recording gate, ReplayEngine, replay UI)
```
Every arrow points **down** to ReplayCore; ReplayCore points to nothing above it. The one inversion is that
ReplayCore calls back into an adapter through a protocol existential it was handed — it never names a concrete
adapter type. (`ATCReplayKit` is a temporary umbrella that re-exports `ReplayCore` + `ATCReplayAdapter` so the
app's imports did not have to move mid-migration; it is scaffolding, marked for deletion.)

### What an adapter provides — four questions, one protocol (`EventPayloadCoding`)
1. **Coding** — a payload ⇄ a JSON object (`object(for:)` / `payload(from:)`).
2. **Version** — the current payload version per kind (`currentVersion(for:)`).
3. **Routing** — which kinds a replay must apply, answered **by tag, never by decoded payload**
   (`affectsSimulation(tag:)`).
4. **Migration** — how an old payload moves forward (`migrations`, optional).

Everything else — what a payload means, how the world changes, what a fingerprint includes — is the adapter's,
and ReplayCore has no hook for it.

### The types that cross the boundary (nine, all sanctioned)
`Event`, `EventBody` (a tag ReplayCore routes on + a value it cannot read), `EventTypeTag` (the wire tag; the
adapter owns the numbers), `EventPosition` (`(tick, ordinal)` — the ordering authority), `EventSource`,
`EventID`, `TimelineAction`, `EventPayloadCoding`, `EventSchemaError`. No adapter names a core internal
(`EventCoder`, `EventStore`, `SessionManager`).

### Design principles, in order of consequence
1. **ReplayCore routes payloads; adapters interpret them.**
2. **Facts, not mechanics** — an adapter's API names what happened (`ATCEvent.commandIssued`,
   `GridBotEvent.moved`), never how it is stored. This is what let the payload representation change under
   R2b-atomic with zero call-site churn.
3. **Route by tag, never by decoded payload** — a build that cannot decode a newer payload still replays it
   correctly.
4. **Tags and field meanings are permanent** — add, never renumber or repurpose; hand-write the coding.
5. **Determinism is the whole game** — no wall-clock, real randomness or platform state inside `apply`.
6. **Adapters depend on ReplayCore only.**

### The extraction, phase by phase
- **R0** — freeze the on-disk format as a committed golden corpus.
- **R1a** — split the package into `ReplayCore` + `ReplayPersistence`.
- **R1b** — extract `SimDeterminism` as an independent package.
- **R2a** — put a seam between the core and the event vocabulary.
- **R2b (survey → prep → atomic)** — classify every ATC dependency, write the boundary contract, give the
  adapter a canonical construction API, then **move payload semantics out of the core**: removed
  `EventPayload` / `EventKind` / `DefaultEventPayloadCoding`; introduced `EventTypeTag` + `EventBody`; the ATC
  vocabulary now lives in `ATCPayload` + `ATCEventCodec`.
- **Reference Adapter Test** — GridBot, the proof.

### One deliberate, unchanged artefact
The on-disk frame magic is `ATC1` (little-endian) and now appears at the head of GridBot frames too. It is a
**format constant, not a name** — renaming it would make every existing recording unreadable. It becomes a
neutral id (e.g. `RCE1`) at the next intentional file-format schema-version bump, not before.

---

## 3 · Reviewer Guide

**The primary review question:** *could an engineer build an adapter for a different deterministic simulation
using only ReplayCore's public API and the ATC adapter as an example, without changing ReplayCore?* GridBot is
the evidence that the answer is yes. Everything else is in service of that.

Review the **destination, then the mechanism, then the proof** — not the 49 commits in order:

1. **The contract** — [`replay-adapter-boundary.md`](../architecture/replay-adapter-boundary.md), §1 (the
   split) and §6a (ownership matrix). The lens for everything else.
2. **ReplayCore** (`LocalPackages/ATCReplayKit/Sources/ReplayCore/`) — `Event` / `EventBody` /
   `EventTypeTag` → `EventEnvelope` + `EventPayloadCoding` → `EventStore` + `EventCoding` → `SessionSeal` →
   `Session*`. **Check:** nothing here names an ATC concept; imports are `Foundation` + `CryptoKit` only.
3. **SimDeterminism** (`LocalPackages/SimDeterminism/`) + its use in `ATCSimKit` (`SeededRandom`,
   `SimulationStateHash`, `SimulationClock`, `WallClockScan`) — why replay reconstructs the identical world.
4. **The adapters** — `ATCReplayAdapter/` (`ATCPayload`, `ATCEventCodec`, `ATCEvent`) then `GridBotAdapter/`,
   read side by side; identical three-file shape.
5. **The how-to** — [`building-an-adapter.md`](../architecture/building-an-adapter.md).
6. **App integration** (`VectraPro/Commands/`) — `InputGateway` → `SessionCoordinator` → `ReplayEngine` /
   `ReplayClock` / `ReplayTransport`.
7. **The proofs last** — `GridBotAdapterTests/GridBotReferenceTest.swift`, then `ATCReplayKitTests`
   `GoldenCorpusTests` + `SessionSealTests`.

**Highest-leverage things to scrutinize:** `affectsSimulation(tag:)` (a wrong value silently breaks replay);
the `EventPayloadCoding` split (R2b-atomic, `c701b29`); that ReplayCore imports no domain module; and that
`GridBotAdapterTests` uses `import ReplayCore` (never `@testable`) and no core internal.

### Commit groups (the 49 commits, as nine named groups)
| Group | Commits | Establishes |
|---|---|---|
| **Design & intent** | `77a7ea7` `00bd318` `fb7caa4` `e771a7c` | Recording/replay/branching architecture; assessment vs training; sharing model; call-site-first design |
| **Determinism foundation** | `883f045` `f4279f6` `c28876c` | Reproducible sim identity + RNG, proven, with a CI determinism gate |
| **Event & session model** | `ca82e6f` `2e9faaa` `daf9346` `7046bf9` `5bc36bf` `7d73e9c` `d7a854b` | Sessions/manifests/catalogue, events that outlive code, `EventID`, `EventSource`, causation, sim-changes-vs-causes |
| **Recording path into the app** | `b205187` `00e7a9b` `2407886` `3b1f821` `3bc399b` `e3d8144` `614dfce` | One input path, one clock, record controller intent, lifecycle FSM, recording behind a gate, cost measured |
| **Replay engine & UI** | `1f490aa` `f4c307f` `4c96e79` `bace0dc` `8e8b4b8` `b75206f` `60ba101` `6ad651f` `db048cb` `f028152` | ReplayEngine, transport + seeking, continue-from-replay, speeds, the replay browser UI |
| **Extraction R0–R2a** | `429e677` `73d9e3c` `3af1db3` `6dd34ab` `68fd908` | Propose from inventory; golden corpus; split ReplayCore/ReplayPersistence; extract SimDeterminism; vocabulary seam |
| **Boundary contract & R2b-prep** | `07ed0d6` `d334ac2` `85c3345` `a29edd2` `76316cf` `4f78e43` `c239fb4` `3626a8d` `b215133` `e5a42a0` | The permanent boundary doc + ownership matrix; canonical `ATCEvent` API; "facts, not mechanics"; classify exposures; migrate call sites/tests |
| **R2b-atomic: sever the vocabulary** | `c701b29` | Move payload semantics out of ReplayCore — the core structural change |
| **Reference adapter & documentation** | `3434a38` `31b70d8` | GridBot proves genericity end-to-end; the canonical how-to |

Reading the groups top to bottom is the full evolution: *design → make it deterministic → model events →
record → replay → extract the platform → contract the boundary → sever the vocabulary → prove it.*

---

## 4 · Migration Guide

For anyone with code on top of the pre-extraction ReplayCore (or an in-flight branch). Two kinds of migration —
**source API** (things changed) and **on-disk data** (nothing changed).

### 4.1 On-disk / data — nothing to do
Recordings written before this work **still replay and still verify**. R0's golden corpus asserts the format is
byte-for-byte unchanged, and the seal computation is unchanged. No re-recording, no data migration.

### 4.2 Source API — what moved (post R2b-atomic)
| Before | After |
|---|---|
| `EventPayload` (enum of ATC cases) | Build via `ATCEvent.commandIssued(…)` etc.; the payload is now an opaque `EventBody` |
| `EventKind` | `EventTypeTag` (adapter owns the numbers, declared as `EventTypeTag` extensions) |
| `event.kind` | `event.tag` |
| `event.affectsSimulation` | `codec.affectsSimulation(tag: event.tag)` |
| `DefaultEventPayloadCoding()` | `ATCEventCodec()` (or your adapter's codec) |
| `EventStore(url:sessionClass:)` | `EventStore(url:sessionClass:coding:)` — inject the codec |
| `EventCoder()` | `EventCoder(coding:)` |
| `EventEnvelope(event)` | `EventEnvelope(event, eventVersion:)` — version comes from the codec |
| `EventMigration.eventType` | `EventMigration.tag` |
| reading a payload back | `ATCEvent.payload(of: event)` (returns your typed payload, or nil) |

Practical rule: **construct and read events through the adapter's API, never through a payload type.** Call
sites that already did this did not change at all — that was the point of the construction API.

### 4.3 The umbrella shim
`import ATCReplayKit` still works: the umbrella re-exports `ReplayCore` + `ATCReplayAdapter`. It is temporary.
When convenient, change call sites to `import ReplayCore` and `import ATCReplayAdapter` directly and delete the
umbrella. Nothing forces this in one commit.

### 4.4 Building a new adapter
Follow [`building-an-adapter.md`](../architecture/building-an-adapter.md) — four files (payload, codec,
construction API, world) against `ReplayCore` only, plus a test that records → replays → seals → fingerprints.
GridBot is the copyable reference.

---

## 5 · Deferred Work / Future Roadmap

Nothing below is started; the architecture is frozen until this PR merges.

| Item | State | Trigger / plan |
|---|---|---|
| **R4 — generic codec** | Deferred, not started | Make the codec generic so `tag(for:)` becomes total over the typed payload and the two `EventPayloadCoding` halves collapse into one protocol. Begin **only** after this PR is reviewed and merged. |
| **`RCE1` frame magic** | Deferred (cosmetic) | Rename `ATC1` → a neutral id at the **next intentional file-format schema-version bump** — never on its own, because it would break existing recordings. Fold into R4 or the next format change. |
| **`affectsSimulation` envelope bit** | Deferred, with an explicit activation condition | Promote the skip/apply decision into the envelope only when a consumer must make replay decisions **without a payload codec**. Until then, tag-based routing is the sanctioned mechanism. (Boundary doc §6d.) |
| **Delete the `ATCReplayKit` umbrella** | Deferred (mechanical) | Once call sites import `ReplayCore` + `ATCReplayAdapter` directly. No rush; it is honest packaging while the migration settles. |
| **Second real adapter (beyond GridBot)** | Not planned here | GridBot proves the boundary. A genuine second product simulation would be the next real-world validation, and the reference-adapter test is the template. |

---

## Verification Summary

All green on `GenericReplayEngine`:

| Gate | Result |
|---|---|
| ReplayCore package suite (`ATCReplayKitTests`) | **175 tests**, 14 skipped, 0 failures |
| GridBot reference test (`GridBotAdapterTests`) | **5 tests**, 0 failures — record/replay/seal/golden/migration |
| App build + replay suites | InputGateway, ReplayEngine, ReplayGate, ReplayKitWiring — pass |
| Golden corpus | byte-for-byte identical (ATC + GridBot) |
| Session seal | incremental == one-pass recompute; a tampered log fails |
| Determinism | CI determinism gate green; one-clock scan clean |
| Boundary | ReplayCore imports `Foundation`/`CryptoKit` only; adapters name no core internal; GridBot needed **zero** ReplayCore changes |

**ReplayCore extraction is complete, verified, and documented. Considered closed until the PR is reviewed and
merged.**
