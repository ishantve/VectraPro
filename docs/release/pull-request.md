# PR: ReplayCore — a generic, simulation-agnostic replay platform (R0–R2b + GridBot reference adapter)

**base:** `replaycore-base`  **head:** `GenericReplayEngine`
**Compare:** https://github.com/ishantve/VectraPro/compare/replaycore-base...GenericReplayEngine

---

## Executive summary

**ReplayCore can now be reused by any deterministic simulation through a small adapter — without changing
ReplayCore.** It records, orders, times, seals, stores and replays events; the adapter supplies only what a
payload *means*. This PR completes that separation and proves it: a second, unrelated simulation (**GridBot**,
a grid robot) was built entirely on ReplayCore's public API and driven end to end — record → replay → seal →
deterministic fingerprint → payload migration — with ReplayCore unchanged. ATC and GridBot are now peers on
one platform.

## Why
A recording is evidence (assessments), so it must replay to the identical world and verify against a
tamper-evident seal. That is only safe if the platform that **orders and stores** events is separate from the
domain that gives them **meaning**. This PR makes that separation real and enforces it with a written contract:
*ReplayCore routes payloads; adapters interpret payloads.*

## What's in scope (in architecture order)
1. **ReplayCore** — envelope, ordering `(tick, ordinal)`, timing, routing, sealing, storage/framing, session
   lifecycle, branching. `Foundation` + `CryptoKit` only; no domain knowledge. R2b moved payload semantics out
   (`EventPayload`/`EventKind` → `EventTypeTag` + `EventBody`).
2. **ReplayPersistence** — the SQLite-backed catalogue, split out so the core stays free of a platform library.
3. **SimDeterminism** — seeded RNG, simulation state hashing, one-clock enforcement, a CI determinism gate.
   Includes the additive determinism changes in **ATCSimKit** and **ATCTrafficKit**, and one additive
   `APIManager.requestWithPayload()` in **NetworkKit** so a recording embeds the exact bytes the backend served
   (re-encoding a decoded copy could replay a different world). These are the replay foundation and are kept
   with it, not split out.
4. **Adapters** — `ATCReplayAdapter` (the real one: `ATCPayload`, `ATCEventCodec`, `ATCEvent`) and
   `GridBotAdapter` (the reference). Same three-file shape; GridBot depends on `ReplayCore` only.
5. **App integration** — one input path for mic + keypad, recording behind a validated gate, `ReplayEngine`
   (load → schedule → feed back), transport + seeking, and the replay browser UI.
6. **Documentation** — `docs/architecture/replay-adapter-boundary.md` (the permanent contract),
   `docs/architecture/building-an-adapter.md` (the how-to), and `docs/release/replaycore-extraction.md` (this
   release package).

## What's NOT in this PR
Everything below the base is excluded: GeoNavKit, ATCParserKit, SpeechKit, the NetworkKit extraction, and the
MapScreen/parser refactoring. `replaycore-base` is the last stable commit before replay work began, so this
diff is replay + determinism only.

## Reviewer focus
**The one question that matters: could an engineer build an adapter for a different deterministic simulation
using only ReplayCore's public API and the ATC adapter as an example, without changing ReplayCore?** GridBot is
the proof that the answer is yes — it is built with `import ReplayCore` (never `@testable`), names no core
internal, and needed zero ReplayCore changes to run end to end. Scrutinize in particular: `affectsSimulation(tag:)`
(a wrong value silently breaks replay), the `EventPayloadCoding` split in `c701b29`, and that ReplayCore imports
no domain module. A full review order and a nine-group commit map are in
`docs/release/replaycore-extraction.md` §3.

## Known cosmetic item (intentionally unchanged)
The on-disk frame magic is `ATC1` (little-endian) and now appears in GridBot logs too. It is a format constant,
not a name — renaming it would make every existing recording unreadable. It becomes a neutral id (e.g. `RCE1`)
at the next intentional file-format schema-version bump, not here.

## Architecture status
The ReplayCore ⇄ Adapter boundary is **frozen** pending this review. **R4** (making the codec generic) is
**deferred and not started** until this PR merges.

## Verification (all green)
- ReplayCore package suite: **175 tests** (14 skipped), 0 failures.
- GridBot reference test: **5 tests**, 0 failures — record/replay/seal/golden/migration.
- App build + replay suites (InputGateway, ReplayEngine, ReplayGate, ReplayKitWiring).
- Golden corpus byte-identical (ATC + GridBot); incremental seal == one-pass recompute; a tampered log fails;
  CI determinism gate green.
- ReplayCore imports `Foundation`/`CryptoKit` only; adapters name no core internal.

Scope: **49 commits · 114 files · +18,979 / −221**, replay + determinism only.
