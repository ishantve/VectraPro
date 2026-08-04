# Simulation Recording, Replay & Timeline Engine — Final Review

**Status:** engineering complete. **Branch:** `ReplayLogic`. **Date:** 4 August 2026.

This closes the project that began as an architecture task and ran through Phase 0 (determinism), Phase A
(foundations), Phase B (recording) and Phase C (replay, branching, UI). It records what was built, what it
costs, what is owed, and what should not be changed.

---

## 1 · Overall architecture

The system records **inputs**, not state. A session is a seed, an exercise payload, and an ordered list of the
instructions a trainee gave. Replay re-runs the simulation and injects those instructions at the ticks they were
issued. The world is not restored; it is **recomputed**.

That choice is the whole architecture, and everything else follows from it:

```
                        ┌──────────────────────────────────────────┐
   phraseology ─┐       │  CommandController.perform(...)          │
   keypad ──────┼──────▶│  the one authoritative execution path    │
   speech ──────┘       └───────────────┬──────────────────────────┘
                                        │ submit (before dispatch)
                                ┌───────▼────────┐
                                │  InputGateway  │  ordinal counter, no wall clock
                                └───────┬────────┘
                                        │
                    ┌───────────────────┼────────────────────┐
                    ▼                   ▼                    ▼
            ┌──────────────┐   ┌─────────────────┐   ┌──────────────┐
            │ SideEffectGate│   │ SessionRecorder │   │  simulation  │
            │ live/replay/  │   │ framed log +    │   │ SimulationClock
            │ suppressed    │   │ incremental seal│   │ RandomStreams │
            └──────────────┘   └────────┬────────┘   └──────────────┘
                                        │
                          ┌─────────────▼─────────────┐
                          │ ATCReplayKit / ReplayStore │
                          │ manifest · catalogue · log │
                          └─────────────┬─────────────┘
                                        │
                                ┌───────▼────────┐
                                │  ReplayEngine  │──▶ ReplayClock (sole authority)
                                └───────┬────────┘          │
                                        │                   ▼
                                        │        ReplayTransportState (Codable value)
                                        │        ReplayCommand       (Codable enum)
                                        │                   │
                                        ▼                   ▼
                                  new session         SwiftUI / UIKit / RN / Unity
                                  (Continue)
```

**Determinism is the substrate.** `SimulationClock` counts integer ticks (1 tick = 1 simulated second) and speed
changes only the timer period, never the step. `RandomStreams` gives each subsystem its own seeded SplitMix64
stream so adding a consumer cannot shift another's sequence. `SimulationStateHash` quantises positions to 1e-6°
and angles/speeds to 0.01 and excludes history, labels and colliders — the things that differ without mattering.

**Storage is boring on purpose.** An append-only framed log (magic, length, crc32) for events; SQLite for the
catalogue. Each is used where it is strongest, and a lost catalogue is recoverable because every manifest is still
on disk.

**Layering.** `ATCReplayKit` is Foundation-only and knows nothing about aircraft; `ATCReplayStore` adds SQLite;
the app owns *when* — which exercise, which owner, which seed. The engine and the transport sit above, and the UI
above that owns nothing at all.

---

## 2 · Recording workflow

1. `MapViewModel.reset(seed:)` starts a session through `SessionCoordinator`.
2. `SessionManager.start` writes a manifest (schema-versioned independently of events) with the seed, the owner,
   the **embedded exercise payload**, and the build/architecture environment.
3. Every instruction reaches `CommandController.perform`, which submits to `InputGateway` **before** dispatch.
   The gateway stamps an ordinal and hands the event to the recorder; the recorder frames it, appends it, and
   feeds the incremental SHA-256 seal.
4. Duration end or `clearOnExit()` stops the session: assessments are sealed, degraded recordings are ended as
   degraded, and a failure to end cleanly abandons rather than pretends.
5. Launch runs `recoverAfterLaunch()` **before** the coordinator is attached, truncating each interrupted log to
   its last valid frame.

Three invariants hold and are tested:

- **Exactly one execution path.** Phraseology, keypad and speech all converge on `perform`.
- **Recording observes, never alters.** `testRecordingDoesNotChangeTheSimulation` compares fingerprints with
  recording on and off.
- **Recording disabled is free.** No branch in the simulation asks whether a recorder exists.

One design decision was reversed on your invariant: a failed write **degrades the recording** rather than refusing
the input. A trainee's exercise is not interrupted by a disk problem; the recording simply stops being evidence.

---

## 3 · Replay workflow

`ReplayEngine.load(_:)` reads the manifest, restores the exercise **from the recording alone** — no network, no
prior setup — reseeds the streams, resets to tick 0, and detaches recording so a replay cannot write itself into a
new log. `ReplayClock` receives the bounds and goes to `.stopped`.

Stepping advances the simulation one tick and injects any events scheduled for it, **in recorded order** — which is
what makes a multi-instruction transmission replay the way it was spoken. `run(to:)` steps in a loop. `play()`
starts a timer whose period is `SimulationClock.tickInterval / speed`. Seeking restarts from tick 0 and re-runs;
there are no snapshots (§8).

Two properties make replay trustworthy:

- **The fingerprint matches.** `testARecordedSessionReplaysToTheSameFingerprint` runs the production engine — not
  a test driver — against real recorded sessions. This was the gate that had to pass before Phase C began.
- **Speed cannot change the answer.** Final fingerprints are identical at 0.25× and 30×, because speed touches
  the interval and never the step. `ReplayClock.speedPreservesCorrectness` states this as code rather than as a
  comment.

Side effects are gated. Replay runs in `.replaying`, so deferred reports coming due during a scrub are not spoken
at a reviewer who is dragging a scrubber.

---

## 4 · Continue Simulation workflow

Continue is **not a mode change**. It creates a new `SessionID`, a new manifest, a new log, and records forward
from the fork tick. The original is marked superseded and otherwise untouched — its events after the fork point
are kept, because comparing what the trainee did the first time against the second is the value of branching.

Nothing is "converted". No snapshot is loaded. The world is already live because it was reached by *simulating*,
and that is why the app-side action is three lines: fork, dismiss the transport, done.

---

## 5 · Branching workflow

`BranchManager.fork(parent, at:)` creates the child; `SessionCoordinator.branch` then **copies the parent's input
prefix** — every event before the fork tick — into the child's own log, at the ticks they were issued.

This replaced the designed approach of snapshotting state at the fork point. It does the same job for a fraction
of the bytes (a few hundred events rather than a serialised world), needs no snapshot machinery, and makes each
branch **self-sufficient**: it replays from tick 0 without reading its parent. The prefix *is* the state,
expressed smaller.

Copies take the child's own event ids, since an id is derived from `(session, ordinal)`. That is correct — they are
this session's record of those instructions.

Lineage lives in `catalogue.children(of:)`. `supersededBy` on the parent means "most recent fork", not "the fork",
because a parent can name only one; investigating a refused `superseded → superseded` transition is what surfaced
that, and it is now documented rather than surprising.

---

## 6 · UI workflow

A single entry point on the radar (`clock.arrow.circlepath`) opens **`ReplayBrowserView`** — a catalogue-driven
list, so two hundred sessions list without opening one. Rows carry label, duration, fork point, date, an
assessment badge, and, when applicable, why the session cannot be scored. Branches are shown with rails and a
glyph, indented by depth.

Selecting a row builds a `ReplayEngine` over `MapViewModel`, loads it, and shows **`ReplayTransportBar`** over the
radar already on screen. Continue forks, dismisses the bar, and the radar is live.

The presentation boundary is two Codable types: `ReplayTransportState` (what to draw) and `ReplayCommand` (what
was asked). Both cross a React Native bridge or a C interface as JSON with nothing added. SwiftUI happens to be
able to observe `ReplayClock` cheaply; other platforms poll `state`. `ReplayTransportBar` could be deleted and
rewritten in UIKit against the same two types — a source-scan test asserts it holds no replay state.

---

## 7 · UX decisions and rationale

| Decision | Why |
|---|---|
| Replay drives the **existing radar**, not a second screen | A reviewer wants the picture the trainee flew. Fewer moving parts, and no second radar to keep in step. |
| Replaying is **the presence of a transport**, not a flag | A flag beside a transport is two things that must agree. |
| Mic and keypad **hidden while replaying** | A replay is driven by recorded instructions; a live transmission has nowhere to go. Leaving them up invited a command that silently did nothing. Hiding them is what makes Continue legible as the way to take control. |
| Zoom stays, lifted above the bar | Looking closer at what happened is most of what a review is. |
| Branch label carries its origin — "Continued from 10:40" | Three forks were three identical rows. |
| Rails for branch depth | A 16pt indent on a 1194pt row made depth two read as depth one. Level is now countable. |
| "Cannot be scored — not sealed" | Consequence first, implementation term second. "Not sealed" is accurate and not the point. |
| Seek on **release**, not during drag | A seek re-simulates; doing it per frame would run hundreds to land in one place. |
| Play hidden at the end rather than inert | The honest answer at the end is "restart or seek back". |
| Architecture-mismatch warning **in the bar**, not a badge elsewhere | A reviewer who does not know a replay is unscoreable might score it. |
| Raw values in `ReplayTransportState`, formatting in the view | How to write a duration is a presentation decision another platform will make differently. |

---

## 8 · Performance summary

All figures **measured**, simulator, best-of-3 where noted. See `scripts/verify.sh metrics`.

**Recording overhead** — 2,400 ticks, 120 instructions:

| | total | per tick |
|---|---|---|
| without recording | 0.0881 s | 36.7 µs |
| with recording | 0.0955 s | 39.8 µs |
| difference | +0.0075 s | **+8.5%** |

Cost per event: **62.3 µs**.

**Memory** — `phys_footprint`, same run:

| | baseline | tick 1,200 | tick 2,400 | after release |
|---|---|---|---|---|
| without recording | 36.8 MB | 36.8 MB | 36.8 MB | 36.8 MB |
| with recording | 36.8 MB | 36.8 MB | 36.8 MB | 36.8 MB |

Attributable growth: **+0.0 MB**. The 1,200→2,400 stretch issues no instructions, so a rise there would be a leak
in the step loop rather than in recording. Nothing accumulates per tick.

**Storage** — extrapolated from a long run (120 events, 24,714 bytes):

- 206 bytes per event
- 37 KB per simulated hour
- **2.4 MB per 100 sessions**

**Sealing** — 5,000 frames of 200 bytes:

- incremental: 0.67 µs/event
- one-pass verify: 1,221 MB/s

Both forms agree, which is the property that makes an assessment verifiable at all.

**Seek** — worst case, 2,400 ticks with no snapshots: **≈38 ms**. This is why snapshots were not built (§10).

**Determinism** — golden fingerprint `0x95A9_2889_F6E7_9EBC`, stable across processes and, measured, across
architectures (arm64 == x86_64).

**Test counts** — ATCSimKit 112 · ATCTrafficKit 28 · ATCReplayKit 170 · NetworkKit 4 · app suite green.

---

## 9 · Technical debt

### Requires physical device verification before release

Not project blockers. `ImageRenderer` draws `Slider` and `Menu` as placeholders, so the snapshot pass could not
reach these:

1. **Scrubber interaction feel** — drag responsiveness, seek-on-release.
2. **Speed menu interaction** — opening, checkmark on the current speed.
3. **Playback button visual transitions** — the play↔pause icon swap mid-playback.
4. **Animation polish** — the transport's move/opacity transition.

### Other debt

| Item | Note |
|---|---|
| All profiling is **simulator-only** | No device profile was ever taken. The comparisons hold; the absolute numbers will differ. |
| `SessionSummary.init` is public | Catalogue immutability is enforced *in* the catalogue, not by the type. A caller outside could build an inconsistent summary. |
| MapScreen visual pass never done | Predates this project; still owed. |
| Holding + login/exercise-start smoke tests owed | Named earlier, never written. |
| §22.2 A/B/C decision open | Can a trainee withhold an assessment from an instructor? Product decision, not technical. |
| CocoaPods/npm channels at 1.0.0 | Secrets missing, so those release channels never advanced. |
| Backend phraseology payload | Yours: 320 readback slot, 2 blank hold codes, 3 indistinguishable pairs, empty `keyboardShortCut`. |
| Snapshot design documented, not built | Deliberate; see below. |

---

## 10 · Future roadmap

**Snapshots.** The design is in `replay-engine.md` and stays there. Build them when a measurement demands it — a
seek that exceeds ~250 ms, which given ≈38 ms at 2,400 ticks means sessions roughly 6× longer, or far denser
traffic. The trigger should be adaptive (§7.2 of that doc): snapshot when re-simulation cost exceeds a budget, so
8-aircraft sessions get sparse snapshots and 200-aircraft ones get dense.

**Cloud sync.** The manifest already carries owner, digest and environment; `StorageOrigin` already distinguishes
local from remote. Sync is an upload of a sealed log plus a catalogue row — the seal is what makes a downloaded
session verifiable, so this is additive.

**Instructor tools.** The sharing model you specified — user's own list with play/share icons, instructor's
"Shared with me" — needs an assignment API and a share record. `AssignmentID` is already reserved in the manifest
and deliberately unused.

**Multiplayer.** The hard part is already solved: deterministic fixed-step simulation with seeded streams and
ordinal-stamped inputs is the standard lockstep shape. What is missing is input exchange and a rollback policy.
`correlationID`/`causationID` were reserved for exactly this kind of distributed tracing.

**Analytics.** Scoring must stay versioned (your Phase A requirement) so a re-score is comparable. Derive metrics
from replayed sessions rather than recording them — a derived number can be recomputed when the rules change; a
recorded one cannot.

---

## 11 · Retrospective

### The most important architectural decisions

1. **Record inputs, not state.** Everything good downstream is a consequence: tiny logs (206 bytes/event),
   branches that need no snapshots, a "continue" that is already live, and multiplayer left within reach.
2. **One authoritative execution path.** Because phraseology, keypad and speech all pass through `perform`,
   recording needed one insertion point rather than three.
3. **`ReplayClock` as the single authority, all the way to the view.** The bug class this removes — scrubber says
   one thing, engine another — is the class nobody can reproduce.
4. **Separating simulation state from external side effects.** Your requirement. Without the gate, scrubbing
   would speak readbacks at a reviewer.
5. **Explicit finite state machines** for session lifecycle and replay mode. Illegal transitions throw. One
   refused transition taught us something true about the data model (§5).
6. **Versioning everything at the boundary** — `schemaVersion`/`eventType`/`eventVersion`, manifest versioned
   independently, dictionary-based read-time migrations.

### Assumptions that turned out to be wrong

- **"This will need a big determinism retrofit."** It was already ~80% there — the fixed-step loop existed because
  someone wanted a smooth clock. The work was removing wall-clock and unseeded-random reads, not rebuilding.
- **"Branching needs state snapshots."** Copying the input prefix is cheaper, simpler, and gives self-sufficient
  branches. The designed answer was worse than the discovered one.
- **"Seeking will need snapshots."** ≈38 ms said otherwise. Measuring saved a subsystem.
- **"Only singletons need `nonisolated deinit`."** Wrong four times. The rule is *every* `final class` in this
  target, and `IsolatedDeinitScanTests` now checks it rather than trusting memory.
- **"There is a keypad validation bug."** There was not. All 14 bindings carry integer slots and none is in
  `answeredFromAircraft`. The design doc was corrected and characterisation tests written instead of a fix for a
  bug that did not exist.
- **"Replay speeds can reuse the live speed set."** Replay wants something live has no use for — slower than real
  time. It got its own `Double` set.
- **"A UI that passes its tests looks fine."** The snapshot pass found four real problems in a suite that was
  entirely green.

### Bugs the acceptance gates prevented

| Gate | Bug |
|---|---|
| Replay fingerprint gate | **Keypad commands recorded an empty callsign.** Selection cannot be reconstructed from a seed, so every keypad instruction would have replayed against nothing. Fixed by recording the resolved selected callsign. |
| Replay fingerprint gate | **My replay driver injected one tick late** (29/89/149 vs 30/90/150). The *recording* was correct; the driver keyed on a loop counter instead of the clock. Had the gate not existed, this would have been "fixed" in the recorder and corrupted every session. |
| Catalogue contract test | **In-memory and SQLite catalogues disagreed** about which fields an update may change. Both now enforce one immutable set via `SessionSummary.updated(...)`. |
| `testRecordingDoesNotChangeTheSimulation` | Would have caught any observer that perturbed the world; kept recording honest throughout. |
| Cross-architecture fingerprint | Turned "should be deterministic" into a measurement. |
| Source-scan guards | Wall-clock reads, side-effect bypasses, UI-owned replay state — each caught at the point of reintroduction, twice including my own. |
| Isolated-deinit scan | Four process aborts that presented as "all tests fail at 0.000 s". |
| Snapshot pass | Overlapping controls, indistinguishable branch labels, invisible depth, implementation jargon in user text. |

### Principles that should remain frozen

1. **Inputs are the record.** Never store simulation state as the source of truth for a session.
2. **One authoritative execution path.** Any new input source goes through `CommandController.perform`.
3. **No wall clock in the simulation.** `SimulationClock` is the only time.
4. **No unseeded randomness.** New consumers get their own `RandomStreams` stream, never an existing one.
5. **Speed changes the interval, never the step.**
6. **Recording observes; it never alters.** A recording failure degrades the recording, never the exercise.
7. **Side effects cross the gate.** Simulation state and external effects stay separate.
8. **The UI owns no replay state.** `ReplayClock` is the authority; the boundary stays two Codable types.
9. **Original recordings are immutable.** Branching creates; it never converts.
10. **Illegal state transitions fail loudly.**
11. **Measure before building.** Snapshots are the standing example.
12. **Every `final class` in the app target gets `nonisolated deinit`.**

---

*Reviewed against branch `ReplayLogic` at commit `60ba101`. All package and app suites green; the four
device-verification items above are the only open validation work.*
