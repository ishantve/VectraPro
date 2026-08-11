//
//  SeededGenerator.swift
//  ATCTrafficKit
//
//  A reproducible random generator, so a schedule can be replayed exactly.
//
//  ── Why this is duplicated ─────────────────────────────────────────────────
//  ATCSimKit has the same type. That is deliberate, not an oversight.
//
//  This package depends on nothing but Foundation, which is what lets it carry a C interface and
//  reach Unity and React Native. ATCSimKit depends on CoreLocation and cannot. Sharing the type
//  would mean either giving this package a dependency it must not have, or inverting the
//  relationship so the simulation engine depends on traffic scheduling for a random generator.
//  Neither is worth it for eight lines of arithmetic.
//
//  The duplication is pinned rather than trusted: both copies are asserted against the same
//  hard-coded sequence in their own test suites (`seededGeneratorMatchesTheSharedVector`). If one
//  is ever changed, that test fails in both packages — the sequences cannot drift apart quietly,
//  which is the only failure mode that would actually matter.
//
//  If a third package needs this, extract it into a shared Foundation-only package instead of
//  copying it a third time.
//

import Foundation

/// A deterministic generator: same seed, same sequence, on every run and every device.
///
/// SplitMix64. Not cryptographic — do not use it for anything that must be unguessable.
public struct SeededGenerator: RandomNumberGenerator, Equatable, Sendable {

    /// The generator's entire state, so a saved schedule can record and restore its exact
    /// position in the sequence.
    public private(set) var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
