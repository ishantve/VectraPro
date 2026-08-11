//
//  Umbrella.swift
//  ATCReplayKit
//
//  The old module name, kept so nothing downstream changes an import.
//
//  R1 split the package into `ReplayCore` (replay infrastructure) and `ReplayPersistence` (storage backed by
//  SQLite). That is a packaging change, and a packaging change should not reach the application: every app file
//  that imports `ATCReplayKit` still compiles, unchanged, because this target re-exports the new one.
//
//  `@_exported` is underscored and stable in practice — it is how the standard library and most re-export shims
//  do this, and the alternative is either editing every call site or writing typealiases for 39 public types.
//
//  This target is scaffolding, not architecture. It exists so the migration can proceed one phase at a time
//  without a single unshippable commit, and it should be deleted once call sites import `ReplayCore` and
//  `ATCReplayAdapter` directly.
//
//  ── Why the adapter is re-exported too ──────────────────────────────────────
//  R2b-atomic moved the ATC event vocabulary out of the core and into `ATCReplayAdapter`. Before R1, that
//  vocabulary was part of `ATCReplayKit` — so re-exporting only `ReplayCore` would now break the promise this
//  file exists to keep. The old name means "replay, with ATC's events in it", and that is exactly the pair of
//  modules below.
//
//  It is also the honest packaging: an application file that records an ATC event genuinely depends on both,
//  and the alternative — every call site importing two modules mid-migration — buys nothing while the umbrella
//  is still here to be deleted.
//

@_exported import ReplayCore
@_exported import ATCReplayAdapter
