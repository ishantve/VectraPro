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
//  without a single unshippable commit, and it should be deleted once call sites import `ReplayCore` directly.
//

@_exported import ReplayCore
