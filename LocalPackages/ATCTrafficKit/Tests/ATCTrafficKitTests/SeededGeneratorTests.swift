//
//  SeededGeneratorTests.swift
//  ATCTrafficKitTests
//
//  Pins this package's copy of `SeededGenerator` to a shared sequence.
//
//  ATCSimKit has the same type, for the reason given in SeededGenerator.swift: this package must
//  stay Foundation-only so it can carry a C interface. The duplication is acceptable only while
//  the two behave identically, so both suites assert the same hard-coded values. If either copy is
//  ever edited, both tests fail — the sequences cannot diverge quietly, which is the only way this
//  duplication could actually hurt.
//

import XCTest
@testable import ATCTrafficKit

final class SeededGeneratorTests: XCTestCase {

    /// The shared vector. Both copies of `SeededGenerator` — this package's and ATCSimKit's —
    /// assert against these exact values, so the two cannot drift apart without a test failing in
    /// both places. Do not regenerate them to make a failing test pass: a change here silently
    /// changes every saved simulation.
    static let sharedVector: [UInt64] = [
        0x988C_ED4D_9E13_3DAA, 0x659E_27C2_A1C5_FFA8, 0xD0F1_527C_73B2_EFBC,
        0x46FC_33FF_15BE_F56A, 0x00DD_4AAB_4072_C7E9, 0xEC50_5698_F15D_1984,
    ]

    /// The seed the vector was generated from. Matches `RandomStreams.defaultSeed` in ATCSimKit.
    static let sharedVectorSeed: UInt64 = 0x5EED_0000_0000_0001

    func testSeededGeneratorMatchesTheSharedVector() {
        var rng = SeededGenerator(seed: Self.sharedVectorSeed)
        for (index, expected) in Self.sharedVector.enumerated() {
            XCTAssertEqual(rng.next(), expected, "diverged at draw \(index)")
        }
    }

    /// The same seed twice gives the same sequence — the whole point.
    func testTheSameSeedReplaysTheSameSequence() {
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        for _ in 0..<100 { XCTAssertEqual(first.next(), second.next()) }
    }

    /// Different seeds do not.
    func testDifferentSeedsDiverge() {
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 43)
        XCTAssertNotEqual((0..<10).map { _ in first.next() },
                          (0..<10).map { _ in second.next() })
    }

    /// State is the whole generator: restoring it resumes the sequence exactly. This is what
    /// makes a saved schedule resumable rather than merely re-startable.
    func testCapturedStateResumesTheSequence() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<10 { _ = rng.next() }

        var resumed = SeededGenerator(seed: rng.state)
        XCTAssertEqual((0..<10).map { _ in rng.next() },
                       (0..<10).map { _ in resumed.next() })
    }

    /// A schedule built with the same seed produces the same traffic. The property that matters
    /// at the package's own level, not just the generator's.
    func testTheSameSeedProducesTheSameSchedule() {
        func run(seed: UInt64) -> [TrafficCategory] {
            var rng = SeededGenerator(seed: seed)
            var schedule = TrafficSchedule(
                configuration: .init(frequencies: [.arrival: .random, .departure: .random],
                                     airspaceCapacity: 20,
                                     randomIntervals: [15, 20, 30, 45, 60, 90]),
                using: &rng)
            var spawned: [TrafficCategory] = []
            for _ in 0..<600 {
                spawned += schedule.advance(by: 1, currentCount: 0, using: &rng)
            }
            return spawned
        }
        XCTAssertFalse(run(seed: 99).isEmpty, "the run produced nothing to compare")
        XCTAssertEqual(run(seed: 99), run(seed: 99))
        XCTAssertNotEqual(run(seed: 99), run(seed: 100))
    }
}
