//
//  SeededRandom.swift
//  ATCSimKit
//
//  Reproducible randomness for the simulation.
//
//  The simulation has to be able to run twice from the same starting point and reach the same
//  place — for replay, and for tests that assert on more than one tick. Swift's
//  `Double.random(in:)` and friends draw from a system generator seeded by the OS, so two runs
//  of the same exercise diverge immediately. Nothing in the simulation may use them.
//
//  Nothing here is cryptographic and nothing here should be used for anything that needs to be
//  unguessable. It is chosen for being small, fast, and identical everywhere.
//

import Foundation

/// A deterministic generator: same seed, same sequence, on every run and every device.
///
/// SplitMix64 — the algorithm Java's `SplittableRandom` uses and the one usually recommended for
/// seeding others. Chosen over a hand-rolled LCG because its low bits are as well-mixed as its
/// high bits (an LCG's are not, which shows up as visible patterns in exactly the sort of
/// "pick a bearing" call this is used for), and over Swift's `SystemRandomNumberGenerator`
/// because that one is deliberately unreproducible.
///
/// The whole state is one `UInt64`, so capturing it in a saved simulation is a single field.
public struct SeededGenerator: RandomNumberGenerator, Equatable, Sendable {

    /// The generator's entire state. Exposed so a simulation snapshot can record and restore its
    /// exact position in the sequence — a saved state without this is not resumable, because the
    /// next draw after a restore would not be the next draw that was going to happen.
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

/// The simulation's random streams — one per subsystem, all derived from a single seed.
///
/// The important part is that they are **separate**. With one shared generator, adding a single
/// extra draw anywhere shifts every value every other subsystem would have drawn from then on: a
/// small change to how aircraft spawn would silently change the weather in every existing
/// recording, and every stored simulation would replay differently. Separate streams make each
/// subsystem's sequence depend only on its own draws.
///
