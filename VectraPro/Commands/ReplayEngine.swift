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
    private let sessions: SessionManager

    private(set) var loaded: Loaded?

    init(radar: MapViewModel, sessions: SessionManager) {
        self.radar = radar
        self.sessions = sessions
    }

    nonisolated deinit { }

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
        guard let detail = try? JSONDecoder().decode(ExerciseDetailResponse.self,
                                                    from: manifest.exercise.payload).record
                ?? JSONDecoder().decode(ExerciseDetail.self, from: manifest.exercise.payload) else {
            throw LoadError.exerciseUnreadable(sessionID)
        }

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
        return loaded
    }

    // MARK: - 2 · Clock

    /// Where the replay is, in simulated seconds. The simulation's own clock — replay does not keep a second
    /// one, because two clocks are two things that have to agree.
    var currentTick: Int { radar.elapsedSeconds }

    var lastTick: Int { loaded?.lastTick ?? 0 }

    /// How far through, 0…1. For a scrubber.
    var progress: Double {
        guard lastTick > 0 else { return 0 }
        return min(1, Double(currentTick) / Double(lastTick))
    }

    var isAtEnd: Bool { currentTick >= lastTick }

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
