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
/// Adding a stream is safe for the same reason — existing streams are unaffected.
public struct RandomStreams: Equatable, Sendable {

    /// Which subsystem a stream belongs to. The raw value is mixed into the seed, so it must
    /// stay stable: changing one renumbers that subsystem's sequence and invalidates saved
    /// simulations. Add cases, never renumber them.
    public enum Stream: UInt64, CaseIterable, Sendable {
        case spawner   = 1
        case promotion = 2
        case traffic   = 3
        case weather   = 4
    }

    /// The root this set was derived from. Recorded so a simulation can be reconstructed from it.
    public let seed: UInt64

    /// Aircraft creation: spawn point, callsign, type, squawk, initial level and speed.
    public var spawner: SeededGenerator
    /// Choosing which hangar aircraft is promoted onto the radar.
    public var promotion: SeededGenerator
    /// Traffic scheduling — the interval until the next arrival, departure or overflight.
    public var traffic: SeededGenerator
    /// Reserved for dynamic weather. Declared now so introducing it later cannot disturb the
    /// streams above.
    public var weather: SeededGenerator

    public init(seed: UInt64) {
        self.seed = seed
        spawner   = SeededGenerator(seed: Self.derive(seed, .spawner))
        promotion = SeededGenerator(seed: Self.derive(seed, .promotion))
        traffic   = SeededGenerator(seed: Self.derive(seed, .traffic))
        weather   = SeededGenerator(seed: Self.derive(seed, .weather))
    }

    /// A fixed seed, for tests and for a run that has not chosen one yet.
    public static let defaultSeed: UInt64 = 0x5EED_0000_0000_0001

    /// A new seed for a fresh live run, so exercises still differ from each other.
    ///
    /// **The only place the simulation may touch the system generator.** Everything downstream is
    /// a function of the value this returns, which is exactly what makes recording one seed enough
    /// to reproduce a whole exercise.
    public static func freshSeed() -> UInt64 {
        var system = SystemRandomNumberGenerator()
        return system.next()
    }

    /// A stream's starting point: the root seed mixed with the stream's identity.
    ///
    /// Mixed rather than `seed + rawValue`, so that two nearby seeds do not give two streams that
    /// start at the same place — with plain addition, root seed 1 stream 2 and root seed 2
    /// stream 1 would be the same sequence.
    private static func derive(_ seed: UInt64, _ stream: Stream) -> UInt64 {
        var mixer = SeededGenerator(seed: seed ^ (stream.rawValue &* 0x9E37_79B9_7F4A_7C15))
        return mixer.next()
    }
}

// MARK: - Convenience

extension SeededGenerator {

    /// A `Double` in `range`, drawn from this generator.
    ///
    /// These wrappers exist so call sites read like the standard library's — `rng.double(in:)`
    /// beside the old `Double.random(in:)` — which makes a stray unseeded call easy to spot in
    /// review rather than something that has to be hunted for.
    public mutating func double(in range: Range<Double>) -> Double {
        .random(in: range, using: &self)
    }

    public mutating func double(in range: ClosedRange<Double>) -> Double {
        .random(in: range, using: &self)
    }

    public mutating func int(in range: ClosedRange<Int>) -> Int {
        .random(in: range, using: &self)
    }

    public mutating func bool() -> Bool {
        .random(using: &self)
    }

    /// A uniformly-chosen element, or nil when the collection is empty.
    public mutating func pick<C: Collection>(_ collection: C) -> C.Element? {
        collection.randomElement(using: &self)
    }

    /// `collection`, shuffled.
    public mutating func shuffle<C: Collection>(_ collection: C) -> [C.Element] {
        collection.shuffled(using: &self)
    }
}
