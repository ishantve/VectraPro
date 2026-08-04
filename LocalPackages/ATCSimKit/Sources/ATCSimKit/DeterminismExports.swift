//
//  DeterminismExports.swift
//  ATCSimKit
//
//  Keeps `SimulationClock` and `SeededGenerator` visible to everything that imports ATCSimKit.
//
//  They now live in SimDeterminism, which is a packaging change and should not reach the application or the
//  replay engine. Re-exporting means no call site moves and no import line changes — the same compatibility
//  approach the ReplayCore split used in R1a.
//
//  Unlike those umbrellas, this one is not scaffolding to be deleted: ATCSimKit genuinely builds on these
//  primitives, so re-exporting them to its own consumers is a reasonable long-term arrangement.
//

@_exported import SimDeterminism
