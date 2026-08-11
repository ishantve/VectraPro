//
//  SimulationClockTests.swift
//  ATCSimKitTests
//
//  The clock is four lines of arithmetic; what is worth testing is the property it exists to
//  protect — that simulated time is independent of real time and of the speed multiplier.
//

import XCTest
@testable import ATCSimKit

final class SimulationClockTests: XCTestCase {

    func testATickIsOneSimulatedSecond() {
        var clock = SimulationClock()
        XCTAssertEqual(clock.elapsedSeconds, 0)
        for expected in 1...10 {
            clock.advance()
            XCTAssertEqual(clock.elapsedSeconds, expected)
        }
    }

    /// **The reason this type exists.** A fixed number of steps must advance simulated time by a
    /// fixed amount, whatever the wall clock did in between. The wreckage timer this replaced was a
    /// real-time delay, so it cleared 1.5 real seconds later however fast the simulation ran — 45
    /// simulated seconds at 30× — and fired while paused.
    func testSimulatedTimeDependsOnlyOnStepsTaken() {
        var fast = SimulationClock()
        var slow = SimulationClock()

        for _ in 0..<2_400 { fast.advance() }          // as if run at 30×
        for _ in 0..<2_400 {
            slow.advance()                              // as if run at 1×, with pauses
        }

        XCTAssertEqual(fast.tick, slow.tick)
        XCTAssertEqual(fast.elapsedSeconds, 2_400, "40 simulated minutes")
        XCTAssertEqual(fast, slow)
    }

    /// Restoring a tick resumes time where it left off — what a saved simulation needs.
    func testAClockCanBeRestoredToATick() {
        var clock = SimulationClock()
        for _ in 0..<137 { clock.advance() }

        let restored = SimulationClock(tick: clock.tick)
        XCTAssertEqual(restored, clock)
        XCTAssertEqual(restored.elapsedSeconds, 137)
    }

    func testResetReturnsToTheStart() {
        var clock = SimulationClock(tick: 500)
        clock.reset()
        XCTAssertEqual(clock, SimulationClock())
    }

    /// Periodic work fires on a tick cadence, so it does not shift with the speed multiplier.
    func testPeriodicWorkFiresEveryNthTick() {
        var clock = SimulationClock()
        var fired = 0
        for _ in 0..<30 {
            clock.advance()
            if clock.isDue(every: 3) { fired += 1 }
        }
        XCTAssertEqual(fired, 10)
    }

    /// A zero or negative interval must not divide by zero or fire constantly.
    func testANonPositiveIntervalNeverFires() {
        var clock = SimulationClock()
        clock.advance()
        XCTAssertFalse(clock.isDue(every: 0))
        XCTAssertFalse(clock.isDue(every: -1))
    }
}
