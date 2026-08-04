//
//  SimDeterminismTests.swift
//  SimDeterminismTests
//
//  Proves the package stands alone.
//
//  These tests import **only** SimDeterminism — no ATCSimKit, no ReplayCore, no aircraft. That is the whole claim
//  of the package: another deterministic simulation could depend on this and nothing else. A test file that needed
//  a second import to say anything useful would be evidence the split was wrong.
//

import XCTest
import SimDeterminism

final class SimDeterminismTests: XCTestCase {

    // MARK: - The clock

    /// A tick is an integer, and one tick is one simulated second.
    func testTheClockCountsWholeTicks() {
        var clock = SimulationClock()
        XCTAssertEqual(clock.tick, 0)
        clock.advance()
        clock.advance()
        XCTAssertEqual(clock.tick, 2)
        XCTAssertEqual(clock.elapsedSeconds, 2)
        XCTAssertEqual(SimulationClock.tickInterval, 1.0)
    }

    /// `isDue` is how a subsystem runs every N ticks without keeping its own counter — a second counter is a
    /// second thing to get wrong.
    func testWorkCanBeScheduledEveryNTicks() {
        var clock = SimulationClock()
        var fired: [Int] = []
        for _ in 1...10 {
            clock.advance()
            if clock.isDue(every: 3) { fired.append(clock.tick) }
        }
        XCTAssertEqual(fired, [3, 6, 9])
    }

    // MARK: - The generator

    /// The property the whole platform rests on: same seed, same sequence.
    func testTheSameSeedProducesTheSameSequence() {
        var a = SeededGenerator(seed: 0xC0FFEE)
        var b = SeededGenerator(seed: 0xC0FFEE)
        let left = (0..<64).map { _ in a.next() }
        let right = (0..<64).map { _ in b.next() }
        XCTAssertEqual(left, right)
    }

    func testDifferentSeedsDiverge() {
        var a = SeededGenerator(seed: 1)
        var b = SeededGenerator(seed: 2)
        XCTAssertNotEqual((0..<8).map { _ in a.next() }, (0..<8).map { _ in b.next() })
    }

    /// A generator is a value, so a copy continues independently rather than sharing a position. This is what
    /// lets a caller snapshot one, and it is easy to lose by making it a class.
    func testAGeneratorIsAValueNotAReference() {
        var original = SeededGenerator(seed: 42)
        _ = original.next()
        var copy = original
        XCTAssertEqual(copy.next(), original.next(),
                       "a copied generator must continue from the same position, independently")
    }

    /// Usable as a `RandomNumberGenerator`, which is what makes `shuffled(using:)` and friends deterministic.
    func testItDrivesTheStandardLibraryDeterministically() {
        var a = SeededGenerator(seed: 7)
        var b = SeededGenerator(seed: 7)
        XCTAssertEqual(Array(1...20).shuffled(using: &a), Array(1...20).shuffled(using: &b))
    }
}
