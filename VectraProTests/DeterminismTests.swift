//
//  DeterminismTests.swift
//  VectraProTests
//
//  Runs the whole simulation twice and asserts it ends up in the same place.
//
//  This is the check the recording and replay design rests on. Replay works by re-running the
//  simulation from a recorded seed and a recorded list of commands, rather than by playing back
//  stored positions — which is what makes "continue from a paused replay" possible at all, and what
//  keeps a session down to kilobytes instead of tens of megabytes. All of that is true only while
//  the simulation is reproducible.
//
//  Determinism is an invariant, and an invariant nobody checks decays. Every future change to the
//  step loop has to keep passing this, so a feature that reintroduces unseeded randomness or a real
//  clock fails here rather than being discovered later as a replay that quietly shows the wrong
//  thing.
//
//  Deliberately at the level of the whole loop rather than its parts: the parts were already
//  testable, and the bugs this is aimed at — a stray `Double.random`, a dispatch deadline, an
//  iteration over a Set — live in how the parts are combined.
//

import XCTest
import ATCSimKit
@testable import VectraPro

@MainActor
final class DeterminismTests: XCTestCase {

    /// Silent stand-ins. The simulation must not depend on anything the presentation layer does, so
    /// these record nothing and assert nothing — they exist to keep the run quiet.
    private final class SilentFeedback: CommandFeedback {
        func readback(_ spoken: String) {}
        func commandError(_ phrase: String) {}
        func aircraftNotFound() {}
    }

    private final class SilentReports: DeferredReportAnnouncing {
        func register(_ condition: ReportCondition, aircraftCallsign: String) {}
        func advance(aircraft: [Aircraft], allCallsigns: Set<String>,
                     fixes: [ATCSimKit.Fix], runways: [Runway]) {}
        func clear() {}
    }

    /// A view model with its own collaborators.
    ///
    /// Its **own spawner** matters: `AircraftSpawner` carries a shuffled radial cycle and an index
    /// into it, so two simulations sharing the singleton would draw from each other's cycle and
    /// neither would be reproducible. That coupling is invisible until you try to run two.
    private func makeSimulation() -> MapViewModel {
        MapViewModel(spawner: AircraftSpawner(),
                     feedback: SilentFeedback(),
                     reports: SilentReports())
    }

    /// Steps a simulation `ticks` times, fingerprinting it along the way.
    ///
    /// Stepped directly rather than through the timer: the point is to compare two runs step for
    /// step, and a timer would introduce the very real-time dependence being tested for.
    private func run(_ simulation: MapViewModel,
                     seed: UInt64,
                     ticks: Int,
                     sampleEvery: Int = 60,
                     commands: [(tick: Int, command: AircraftCommand)] = []) -> [StateHash] {
        simulation.reset(seed: seed)
        simulation.stopSimulation()          // no timer; this test owns the clock

        var fingerprints: [StateHash] = [simulation.stateHash]
        for tick in 1...ticks {
            for scripted in commands where scripted.tick == tick {
                // Applied to whichever aircraft is first, by id, so the target is the same in both
                // runs without needing to know what the seed produced.
                if let target = simulation.aircraft.min(by: { $0.id.uuidString < $1.id.uuidString }) {
                    simulation.applyToCallsign(target.callsign,
                                               commands: [scripted.command],
                                               readback: "ROGER")
                }
            }
            simulation.advanceStep()
            if tick % sampleEvery == 0 { fingerprints.append(simulation.stateHash) }
        }
        return fingerprints
    }

    // MARK: - The main property

    /// Forty simulated minutes, twice, from one seed. This is the length of a real exercise and the
    /// span a replay has to reproduce.
    func testTheSameSeedProducesTheSameFortyMinutes() {
        let first  = run(makeSimulation(), seed: 0xA11C_E5, ticks: 2_400)
        let second = run(makeSimulation(), seed: 0xA11C_E5, ticks: 2_400)

        XCTAssertEqual(first.count, second.count)
        // Compared per sample rather than as a whole, so a failure says *when* the two runs parted
        // company — which is most of the work of diagnosing it.
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a, b, "diverged at tick \(a.tick)")
        }
    }

    /// The simulation must actually be doing something, or the test above would pass on two empty
    /// runs. Guards against a check that is green because nothing happened.
    func testTheRunIsNotVacuous() {
        let simulation = makeSimulation()
        let fingerprints = run(simulation, seed: 0xBEEF, ticks: 600)

        XCTAssertGreaterThan(Set(fingerprints.map(\.value)).count, 1,
                             "state never changed — the simulation was not running")
        XCTAssertGreaterThan(simulation.listAircraft.count, 0, "no aircraft were ever spawned")
    }

    /// Different seeds must diverge, or the seed is not being used and the first test proves
    /// nothing.
    func testDifferentSeedsProduceDifferentRuns() {
        let first  = run(makeSimulation(), seed: 1, ticks: 600)
        let second = run(makeSimulation(), seed: 2, ticks: 600)
        XCTAssertNotEqual(first.map(\.value), second.map(\.value))
    }

    /// The same seed twice *in the same process*, with a third run in between on a different seed.
    /// Catches state left behind in a singleton: if the run were reading anything global, the
    /// interleaved run would contaminate it.
    func testAnInterleavedRunDoesNotContaminateTheNextOne() {
        let first = run(makeSimulation(), seed: 0xC0FFEE, ticks: 300)
        _         = run(makeSimulation(), seed: 0xDECAF,  ticks: 300)
        let again = run(makeSimulation(), seed: 0xC0FFEE, ticks: 300)

        XCTAssertEqual(first.map(\.value), again.map(\.value),
                       "a run in between changed the result — something is being shared")
    }

    // MARK: - With commands

    /// Commands are the other half of a recording: a replay supplies the seed *and* what the
    /// controller did. The same seed and the same instructions must give the same result.
    func testTheSameSeedAndCommandsProduceTheSameRun() {
        let script: [(tick: Int, command: AircraftCommand)] = [
            (tick:  30, command: .heading(250)),
            (tick:  90, command: .speed(300)),
            (tick: 150, command: .altitude(feet: 26_000)),
            (tick: 300, command: .heading(90)),
            (tick: 450, command: .altitude(feet: 12_000)),
        ]
        let first  = run(makeSimulation(), seed: 0x5EED, ticks: 900, commands: script)
        let second = run(makeSimulation(), seed: 0x5EED, ticks: 900, commands: script)

        for (a, b) in zip(first, second) {
            XCTAssertEqual(a, b, "diverged at tick \(a.tick)")
        }
    }

    /// The commands must actually change the outcome, or the test above is only re-checking the
    /// seed.
    func testCommandsChangeTheOutcome() {
        let script: [(tick: Int, command: AircraftCommand)] = [
            (tick: 30, command: .heading(250)),
            (tick: 60, command: .altitude(feet: 26_000)),
        ]
        let commanded = run(makeSimulation(), seed: 0x5EED, ticks: 600, commands: script)
        let untouched = run(makeSimulation(), seed: 0x5EED, ticks: 600)
        XCTAssertNotEqual(commanded.map(\.value), untouched.map(\.value))
    }

    // MARK: - Across processes

    /// The whole loop, pinned to a constant.
    ///
    /// Every test above compares two runs *inside one process*, which cannot catch a whole class of
    /// fault: Swift seeds `Set` and `Dictionary` hashing per process, so if any decision ever
    /// depended on their iteration order, two runs in the same process would agree and two runs in
    /// different processes would not. A compiled-in constant turns every test run — on any machine,
    /// with any hash seed — into that second process.
    ///
    /// The cost is that this is brittle by design: it fails whenever the simulation's behaviour
    /// legitimately changes. That is the point, but it means the failure has to be read rather than
    /// silenced, so the message says how.
    func testTheLoopMatchesItsRecordedFingerprint() {
        let fingerprints = run(makeSimulation(), seed: 0xF1_5EED, ticks: 600, sampleEvery: 600)
        let actual = fingerprints.last!.value

        XCTAssertEqual(actual, 0x362D_862F_C06F_EBA4, """
            600 ticks of seed 0xF15EED produced \(String(format: "0x%016llX", actual)).

            If nothing about the simulation changed, this is the fault this test exists for: a
            decision somewhere now depends on Set or Dictionary iteration order, which is seeded per
            process and so agrees with itself inside one run and disagrees between runs. Sort before
            iterating.

            If the simulation *did* change — spawning, physics, scheduling — then this constant is
            stale and every existing recording is invalidated. Update it deliberately, as a decision.
            """)
    }

    // MARK: - No real clock

    /// Simulated time must depend only on steps taken, never on how long the run took in reality.
    ///
    /// This is what the wreckage timer used to violate: it removed aircraft 1.5 *real* seconds after
    /// a collision, so at 30× it cleared them 45 simulated seconds late, and it fired while paused.
    /// A test that inserts a real delay between steps would have caught it.
    func testRealTimeBetweenStepsDoesNotAffectTheOutcome() {
        let brisk = run(makeSimulation(), seed: 0x7777, ticks: 240)

        let paused = makeSimulation()
        paused.reset(seed: 0x7777)
        paused.stopSimulation()
        var fingerprints: [StateHash] = [paused.stateHash]
        for tick in 1...240 {
            paused.advanceStep()
            // A real pause partway through, long enough that any wall-clock deadline inside the
            // simulation would have expired.
            if tick == 120 { Thread.sleep(forTimeInterval: 0.25) }
            if tick % 60 == 0 { fingerprints.append(paused.stateHash) }
        }

        XCTAssertEqual(brisk.map(\.value), fingerprints.map(\.value),
                       "the simulation noticed real time passing")
    }

    /// The speed multiplier must not change what happens, only how fast it is watched. It sets the
    /// timer's period; each step still advances exactly one simulated second.
    func testTheSpeedMultiplierDoesNotChangeTheOutcome() {
        let normal = makeSimulation()
        let normalHashes = run(normal, seed: 0x1234, ticks: 300)

        let fast = makeSimulation()
        fast.reset(seed: 0x1234)
        fast.stopSimulation()
        for _ in 0..<5 { fast.increaseSpeed() }      // up the multiplier before stepping
        var fastHashes: [StateHash] = [fast.stateHash]
        for tick in 1...300 {
            fast.advanceStep()
            if tick % 60 == 0 { fastHashes.append(fast.stateHash) }
        }

        XCTAssertGreaterThan(fast.simulationSpeed, 1, "speed never actually changed")
        XCTAssertEqual(normalHashes.map(\.value), fastHashes.map(\.value),
                       "fast-forward changed the simulation rather than just the view of it")
    }
}
