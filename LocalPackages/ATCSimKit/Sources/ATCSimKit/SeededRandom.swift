//
//  SeededRandom.swift
//  ATCSimKit
//
//  The simulator's roster of independent random streams.
//
//  `SeededGenerator` itself moved to SimDeterminism — a SplitMix64 generator is useful to any deterministic
//  simulation. The roster below did not, and deliberately: `spawner`, `promotion`, `traffic` and `weather` are
//  ATC subsystems, and a package that claims to be domain-free should not name them.
//

import Foundation
import SimDeterminism

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
