//
//  SimulationClock.swift
//  ATCSimKit
//
//  The simulation's only source of time.
//
//  Time here is an integer count of ticks, and one tick is one simulated second. Nothing in the
//  simulation may read `Date()`, `CACurrentMediaTime()` or a dispatch deadline: those measure real
//  time, and real time is not what the simulation runs on. A wall-clock delay inside the simulation
//  behaves differently at 1× and 30×, fires while paused, and cannot be replayed — the wreckage
//  timer that used to do exactly that is why this type exists.
//
//  Speed is deliberately not a property of the clock. Fast-forward is a *scheduling* concern: the
//  timer driving the simulation fires more often, and each step still advances exactly one second.
//  Folding speed into the clock would make the step size variable, which is how a simulation stops
//  being reproducible. Keeping them apart is load-bearing, not stylistic.
//

import Foundation

/// Simulated time, counted in ticks.
///
/// A value type with one stored property, so capturing it in a saved simulation — or comparing two
/// runs — is trivial.
public struct SimulationClock: Equatable, Sendable {

    /// Simulated seconds per tick. One, so that ticks and seconds are interchangeable and the
    /// exercise clock counts up smoothly rather than skipping numbers when sped up.
    public static let tickInterval: TimeInterval = 1.0

    /// Ticks elapsed since the exercise began.
    public private(set) var tick: Int

    public init(tick: Int = 0) {
        self.tick = tick
    }

    /// Advances one tick. The only way time moves.
    public mutating func advance() {
        tick += 1
    }

    /// Back to the start of an exercise.
    public mutating func reset() {
        tick = 0
    }

    /// Elapsed simulated seconds. Equal to `tick` while `tickInterval` is 1, and derived rather
    /// than stored so the two cannot drift — they were previously two counters incremented in two
    /// places, which is one edit away from disagreeing.
    public var elapsedSeconds: Int {
        Int(Double(tick) * Self.tickInterval)
    }

    /// Elapsed simulated time.
    public var elapsed: TimeInterval {
        Double(tick) * Self.tickInterval
    }

    /// Whether this tick is one of every `interval`-th — for work that runs less often than every
    /// tick, such as sampling a trail or toggling a blink.
    ///
    /// Phrased in ticks rather than in seconds so the cadence is fixed in simulated time and does
    /// not shift with the speed multiplier.
    public func isDue(every interval: Int) -> Bool {
        interval > 0 && tick % interval == 0
    }
}
