//
//  SeededRandomTests.swift
//  ATCSimKitTests
//
//  Pins this package's copy of `SeededGenerator` to a shared sequence, and pins the stream
//  separation that the whole replay design rests on.
//
//  ATCTrafficKit has the same generator, for the reason given in SeededRandom.swift: that package
//  must stay Foundation-only so it can carry a C interface. Both suites assert the same hard-coded
//  values, so if either copy is edited both tests fail. Divergence between them is the only way
//  the duplication could actually cause harm, and this is what prevents it happening quietly.
//

import XCTest
@testable import ATCSimKit

final class SeededRandomTests: XCTestCase {

    /// The shared vector. ATCTrafficKit's `SeededGeneratorTests` asserts these same values.
    /// Do not regenerate them to make a failing test pass: a change here silently changes every
    /// saved simulation.
    static let sharedVector: [UInt64] = [
        0x988C_ED4D_9E13_3DAA, 0x659E_27C2_A1C5_FFA8, 0xD0F1_527C_73B2_EFBC,
        0x46FC_33FF_15BE_F56A, 0x00DD_4AAB_4072_C7E9, 0xEC50_5698_F15D_1984,
    ]

    func testSeededGeneratorMatchesTheSharedVector() {
        var rng = SeededGenerator(seed: RandomStreams.defaultSeed)
        for (index, expected) in Self.sharedVector.enumerated() {
            XCTAssertEqual(rng.next(), expected, "diverged at draw \(index)")
        }
    }

    func testTheSameSeedReplaysTheSameSequence() {
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        for _ in 0..<100 { XCTAssertEqual(first.next(), second.next()) }
    }

    /// State is the whole generator: restoring it resumes the sequence exactly. This is what makes
    /// a saved simulation resumable rather than merely re-startable — without it, the next draw
    /// after a restore is not the next draw that was going to happen.
    func testCapturedStateResumesTheSequence() {
        var rng = SeededGenerator(seed: 7)
        for _ in 0..<10 { _ = rng.next() }

        var resumed = SeededGenerator(seed: rng.state)
        XCTAssertEqual((0..<10).map { _ in rng.next() },
                       (0..<10).map { _ in resumed.next() })
    }

    // MARK: - Streams

    /// Every stream starts somewhere different, or they would produce correlated traffic.
    func testStreamsAreIndependentOfEachOther() {
        let streams = RandomStreams(seed: 1234)
        let states = [streams.spawner.state, streams.promotion.state,
                      streams.traffic.state, streams.weather.state]
        XCTAssertEqual(Set(states).count, states.count, "two streams started at the same place")
    }

    /// **The property the replay design depends on.** Drawing from one stream must not move any
    /// other. If it did, adding a single draw to the spawner would change the weather in every
    /// recording ever made, and no saved simulation would replay.
    func testDrawingFromOneStreamDoesNotDisturbAnother() {
        var streams = RandomStreams(seed: 1234)
        let trafficBefore = streams.traffic.state
        let weatherBefore = streams.weather.state

        for _ in 0..<1_000 { _ = streams.spawner.next() }

        XCTAssertEqual(streams.traffic.state, trafficBefore)
        XCTAssertEqual(streams.weather.state, weatherBefore)
    }

    /// The same root seed rebuilds the same set of streams.
    func testStreamsAreReproducibleFromTheRootSeed() {
        var first = RandomStreams(seed: 5150)
        var second = RandomStreams(seed: 5150)
        for _ in 0..<50 {
            XCTAssertEqual(first.spawner.next(), second.spawner.next())
            XCTAssertEqual(first.promotion.next(), second.promotion.next())
        }
    }

    /// Nearby seeds must not overlap. With a plain `seed + streamID` derivation, root seed 1's
    /// second stream and root seed 2's first stream would be the same sequence — the reason the
    /// seed is mixed rather than added.
    func testNearbySeedsDoNotShareStreams() {
        var all: Set<UInt64> = []
        for seed in UInt64(1)...8 {
            let streams = RandomStreams(seed: seed)
            all.formUnion([streams.spawner.state, streams.promotion.state,
                           streams.traffic.state, streams.weather.state])
        }
        XCTAssertEqual(all.count, 8 * 4, "two (seed, stream) pairs collided")
    }

    /// The root seed is kept, so a run can be reproduced from what a recording would store.
    func testTheRootSeedIsRecoverable() {
        XCTAssertEqual(RandomStreams(seed: 777).seed, 777)
    }
}
