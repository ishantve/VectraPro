//
//  ReplayEngine.swift
//  VectraPro
//
//  Re-runs a recorded session.
//
//  ── It does not play anything back ──────────────────────────────────────────
//  There is no stored position, heading or altitude to play. A recording holds a seed, the exercise as the
//  bytes the backend served, and the sparse stream of instructions a controller gave. Replay resets the
//  simulation to that seed and feeds those instructions back in at the ticks they were issued; the aircraft
//  arrive where they arrived because the simulation puts them there, exactly as it did the first time.
//
//  Which is why the World at any replay position is a *live* World and Continue Simulation needs no
//  restoration step — it was reached by simulating, not by loading a picture.
//
//  ── Nothing here is a second execution path ─────────────────────────────────
//  A recorded instruction goes back in through `CommandController.perform`, the same entry point the
//  microphone and the keypad use. The keypad is what proved a phraseology code plus slot values is enough to
//  drive the simulation — a keypress has nothing else — so replay reconstructs exactly that and reuses the
//  path rather than adding one.
//
//  ── Presentation is off while seeking ──────────────────────────────────────
//  Driving four hundred ticks would otherwise queue four hundred ticks of readbacks at someone who is
//  scrubbing. The side-effect gate handles it, so no call site here has to remember.
//

import Foundation
import ATCReplayKit
import ATCSimKit

@MainActor
final class ReplayEngine {

    enum LoadError: Error, CustomStringConvertible {
        case exerciseUnreadable(SessionID)
        case payloadCorrupt(SessionID)
        case notReproducibleHere(recorded: String, here: String)

        var description: String {
            switch self {
            case .exerciseUnreadable(let id):
                return "session \(id) has an exercise this build cannot read"
            case .payloadCorrupt(let id):
                return "session \(id)'s exercise payload does not match its digest"
            case .notReproducibleHere(let recorded, let here):
                return "recorded on \(recorded); this device is \(here)"
            }
        }
    }

    /// What was loaded, and whether it can be trusted.
    struct Loaded {
        let sessionID: SessionID
        let manifest: SessionManifest

        /// Instructions, indexed by the tick they were issued at.
        ///
        /// Grouped once at load. A replay steps thousands of times and scans this on each, so a dictionary
        /// rather than a filter is the difference between a seek that is instant and one that is quadratic.
        let inputsByTick: [Int: [Event]]

        /// Everything recorded, including the annotations replay does not consume — readbacks, transcripts,
        /// refusals. Kept so a timeline can show them and a reviewer can hear what the trainee heard.
        let annotations: [Event]

        /// Ticks the recording covers.
        let lastTick: Int

        /// True when this device computes the simulation the way the recording's did.
        ///
        /// A replay on a mismatched architecture is still useful for review and must not be scored — see
        /// `SessionSummary.isScoreable(on:)`. Loading does not refuse it; the caller decides.
        let isReproducibleHere: Bool
    }

    private let radar: MapViewModel
    private let coordinator: SessionCoordinator
    private var sessions: SessionManager { coordinator.sessions }

    /// The single authority on replay state — see `ReplayClock`. The engine writes `position` and reads
    /// everything else; it keeps no playback state of its own.
    let clock: ReplayClock

    private(set) var loaded: Loaded?

    /// Paces playback. The one wall-clock dependency replay has, and it decides *when* to step, never how
    /// much — each fire advances exactly one simulated second, so a replay at 30× reaches the same state as one
    /// at 1×. The same separation the live simulation relies on.
    private var timer: Timer?

    /// `clock` is optional rather than defaulted, because a main-actor default argument is evaluated in a
    /// nonisolated context and will not compile — the same pattern every injected dependency in this project
    /// uses for the same reason.
    init(radar: MapViewModel, recording: SessionCoordinator, clock: ReplayClock? = nil) {
        self.radar = radar
        self.coordinator = recording
        self.clock = clock ?? ReplayClock()
    }

    nonisolated deinit { }

    /// Stops the timer. Not in `deinit`, which is nonisolated and cannot touch it.
    func tearDown() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 1 · Loading

    /// Loads a session and returns the simulation to its first tick.
    ///
    /// The exercise is decoded from the manifest's **embedded payload**, not fetched. That is the whole reason
    /// it is embedded: a replay that re-fetched its configuration would be replaying a different world if the
    /// backend had since changed a fix, with every position subtly wrong and no error anywhere.
    @discardableResult
    func load(_ sessionID: SessionID) throws -> Loaded {
        let manifest = try sessions.manifest(for: sessionID)

        guard manifest.payloadIsIntact else {
            throw LoadError.payloadCorrupt(sessionID)
        }
        let detail = try Self.exercise(from: manifest, sessionID: sessionID)

        let events = try sessions.events(for: sessionID)
        var inputs: [Int: [Event]] = [:]
        var annotations: [Event] = []
        for event in events {
            if event.payload.affectsSimulation {
                inputs[event.tick, default: []].append(event)
            } else {
                annotations.append(event)
            }
        }
        // Sorted by ordinal within each tick. One transmission carries several instructions and their order is
        // what `(tick, ordinal)` exists to preserve; applying them in dictionary order would lose it.
        for tick in inputs.keys {
            inputs[tick]?.sort { $0.ordinal < $1.ordinal }
        }

        let here = RecordingEnvironment.current()
        let loaded = Loaded(
            sessionID: sessionID,
            manifest: manifest,
            inputsByTick: inputs,
            annotations: annotations,
            lastTick: max(events.last?.tick ?? 0,
                          (try? sessions.catalogue.summary(id: sessionID)?.tickCount) as? Int ?? 0),
            isReproducibleHere: here.canReproduce(manifest.environment))

        // Nothing is recorded during a replay. Detached before the reset, so the reset's own session start
        // cannot attach a recorder that would write a replay into a new log.
        radar.recording = nil
        radar.inputs.recorder = nil

        radar.applyExercise(detail, payload: manifest.exercise.payload)
        radar.reset(seed: manifest.seed)
        radar.stopSimulation()

        self.loaded = loaded
        clock.load(bounds: 0...loaded.lastTick)
        return loaded
    }

    /// Releases the recording and returns the transport to nothing.
    func unload() {
        tearDown()
        loaded = nil
        clock.unload()
    }

    /// The exercise a recording embedded.
    ///
    /// Tries the wrapped response shape first, then the bare detail, because a payload may have been served
    /// either way and a recording should not become unreadable over an envelope.
    static func exercise(from manifest: SessionManifest,
                        sessionID: SessionID? = nil) throws -> ExerciseDetail {
        if let wrapped = try? JSONDecoder().decode(ExerciseDetailResponse.self,
                                                  from: manifest.exercise.payload).record {
            return wrapped
        }
        if let bare = try? JSONDecoder().decode(ExerciseDetail.self, from: manifest.exercise.payload) {
            return bare
        }
        throw LoadError.exerciseUnreadable(sessionID ?? manifest.sessionID)
    }

    // MARK: - 2 · Clock
    //
    // Read through, not duplicated. `ReplayClock` is the authority and these are conveniences so callers need
    // not reach past the engine; `progress`, `isAtEnd` and the transport predicates live there and are not
    // recomputed here.

    /// Where the simulation actually is. The clock mirrors this, and `testTheClockNeverDisagreesWithTheSimulation`
    /// pins that they do not drift.
    var currentTick: Int { radar.elapsedSeconds }

    var lastTick: Int { loaded?.lastTick ?? 0 }
    var progress: Double { clock.progress }
    var isAtEnd: Bool { clock.isAtEnd }

    // MARK: - 3 · Scheduler · 4 · Injection

    /// Advances one tick: injects whatever was issued at the current tick, then steps.
    ///
    /// **In that order, and it matters.** An instruction is issued while the clock reads N, before the step
    /// that takes it to N+1 — so it must go in before the step, not after. Driving this off a loop counter
    /// instead of the clock applied everything one tick late, which is the divergence the Phase B gate first
    /// reported.
    @discardableResult
    func stepForward() -> Bool {
        guard let loaded, currentTick < loaded.lastTick else { return false }

        for event in loaded.inputsByTick[currentTick] ?? [] {
            inject(event)
        }
        radar.advanceStep()
        clock.advanced(to: radar.elapsedSeconds)
        return true
    }

    /// Runs to `tick`, or to the end.
    ///
    /// Presentation is suppressed throughout: driving hundreds of ticks would otherwise queue hundreds of
    /// readbacks at a reviewer who is scrubbing rather than watching.
    func run(to tick: Int) {
        radar.sideEffects.suppressing {
            while currentTick < tick, stepForward() {}
        }
    }

    // MARK: - 5 · Timeline controls

    /// Starts advancing on a timer.
    ///
    /// A watched replay speaks: the mode is `.replaying`, so readbacks play but nothing reports outward — a
    /// replay is not a second exercise, and counting it as one would inflate every statistic each time a
    /// session is reviewed.
    func play() throws {
        try clock.play()
        radar.sideEffects.mode = .replaying
        schedule()
    }

    func pause() throws {
        try clock.pause()
        tearDown()
        radar.sideEffects.mode = .live
    }

    /// Changes speed, restarting the timer at the new interval if it is running.
    ///
    /// Only the interval changes. Folding speed into the step size is how a replay stops reaching the same
    /// state as the recording.
    func setSpeed(_ speed: Int) {
        clock.setSpeed(speed)
        if clock.isRunning { schedule() }
    }

    private func schedule() {
        tearDown()
        let timer = Timer(timeInterval: clock.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTimerFire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func onTimerFire() {
        guard clock.isRunning else { return tearDown() }
        if !stepForward() {
            // Reached the end. The clock moves itself to `.paused`; the timer has nothing left to do.
            tearDown()
            radar.sideEffects.mode = .live
        }
    }

    // MARK: - 6 · Seeking

    /// Moves the replay to `tick`.
    ///
    /// Forward from here is stepping. Backward means starting again and re-simulating, because this simulation
    /// is not invertible — collision destruction, spawning and hold capture destroy information, and an
    /// `unstep` would be a second physics implementation obliged to agree with the first.
    ///
    /// No snapshots, deliberately. Phase 0 measured ~16 µs a tick, so re-running a whole forty-minute session
    /// is tens of milliseconds; a keyframe cache would be machinery earning nothing.
    /// `ReplayEngineTests.testMeasureSeekLatency` is what would say otherwise.
    @discardableResult
    func seek(to tick: Int) throws -> Int {
        guard let loaded else { return 0 }
        let target = min(max(tick, 0), loaded.lastTick)

        let previous = try clock.beginSeeking()
        defer { clock.endSeeking(restoring: previous) }

        tearDown()
        radar.sideEffects.mode = .live   // `run(to:)` suppresses; this is what it restores to

        if target < currentTick {
            // Backwards: back to the start of the recording, then forward. Reloading rather than resetting by
            // hand, so a seek lands in exactly the state a fresh load would — one path to a position, not two.
            radar.applyExercise(try Self.exercise(from: loaded.manifest), payload: loaded.manifest.exercise.payload)
            radar.reset(seed: loaded.manifest.seed)
            radar.stopSimulation()
            clock.advanced(to: radar.elapsedSeconds)
        }

        run(to: target)
        clock.advanced(to: radar.elapsedSeconds)
        return currentTick
    }

    /// Back to the first tick.
    func restart() throws {
        try seek(to: 0)
    }

    // MARK: - 8 · Continue Simulation

    /// Continues live from where the replay is.
    ///
    /// **Not a mode change.** A new session with a new id, a new manifest and a new log; the replayed session is
    /// not modified, only marked superseded. Think of it as starting a recording whose opening world happens to
    /// equal the replay position — there is no conversion of a replay into a live run, because there is nothing
    /// to convert.
    ///
    /// And no restoration step, which is the payoff of the whole architecture: the World here was reached by
    /// simulating from the seed, so it *is* a live World. Nothing is loaded, rebuilt or validated — the
    /// simulation simply carries on, and the only thing that changes is which log new inputs go to.
    @discardableResult
    func continueLive(label: String = "") throws -> ATCReplayKit.Session {
        guard let loaded else { throw LoadError.exerciseUnreadable(UUID()) }

        let forkTick = currentTick
        tearDown()
        radar.sideEffects.mode = .live

        let (child, recorder) = try coordinator.branch(from: loaded.sessionID,
                                                       at: forkTick,
                                                       label: label)

        // New inputs go to the branch. The counter continues from the prefix that was just copied in, so no
        // event id is minted twice — ids are `(session, ordinal)`, and the branch's ordinals must stay unique
        // within it.
        radar.inputs.resume(after: try recorder.open())
        radar.inputs.recorder = recorder
        radar.recording = coordinator

        // The engine is done: this is a live exercise now, not a replay.
        self.loaded = nil
        clock.unload()

        radar.startSimulation()
        return child
    }

    /// Feeds one recorded instruction back into the simulation.
    ///
    /// Through `perform`, the same entry point live input uses. The recorded slots are text and the simulation
    /// wants typed values, so they are rebuilt into `StaticCommandSlots` — which is exactly what a keypress
    /// supplies, and why this is a reconstruction rather than a new path.
    private func inject(_ event: Event) {
        guard case .commandIssued(let code, let callsign, let slots) = event.payload else { return }

        // The recording holds the *resolved* callsign, including for an instruction that named no aircraft and
        // went to the selected one — selection is something a controller did with their finger and cannot be
        // recomputed from a seed. Selecting it here is what makes that instruction land where it landed.
        if !callsign.isEmpty,
           let target = radar.listAircraft.first(where: {
               $0.callsign.caseInsensitiveCompare(callsign) == .orderedSame
           }) {
            radar.selectAircraft(target.id)
        }

        let result = radar.commands.perform(code: code,
                                            callsign: callsign.isEmpty ? nil : callsign,
                                            slots: Self.slots(from: slots),
                                            source: .replay,
                                            category: "replay")
        if !result.effects.isEmpty {
            radar.apply(result.effects, readback: Self.replayReadback)
        }
    }

    /// A readback the apply path will accept without asserting.
    ///
    /// `MapViewModel.announce` asserts when a command arrives with no reply, because a silent command is a bug
    /// in live use. During replay the words come from the recorded `readbackSpoken` annotations rather than
    /// being re-derived, so this is a placeholder that is never spoken — the gate suppresses presentation, and
    /// a watched replay speaks the recorded text.
    private static let replayReadback = "REPLAY"

    /// Recorded slot text, back into typed values.
    ///
    /// A value that parses wholly as integers becomes integers; anything else stays text. Comma-separated
    /// because a repeated placeholder — a block altitude names `LEVEL` twice — is recorded as one entry, and
    /// dropping the second half would replay half an instruction.
    static func slots(from recorded: [String: String]) -> StaticCommandSlots {
        var integers: [String: [Int]] = [:]
        var texts: [String: [String]] = [:]
        for (name, value) in recorded {
            let parts = value.split(separator: ",").map(String.init)
            let numbers = parts.compactMap(Int.init)
            if numbers.count == parts.count, !numbers.isEmpty {
                integers[name] = numbers
            } else {
                texts[name] = parts
            }
        }
        return StaticCommandSlots(integers: integers, texts: texts)
    }
}
