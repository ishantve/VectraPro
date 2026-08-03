//
//  ReplayClock.swift
//  VectraPro
//
//  The single authority on replay state: where the replay is, whether it is running, and how fast.
//
//  ── One authority, not three ───────────────────────────────────────────────
//  The alternative is an `isPlaying` on the engine, a `speed` on the transport bar and a scrubber holding its
//  own position. Three copies of the same fact, which drift: the scrubber lands somewhere the engine is not,
//  pausing leaves the bar showing "playing", a speed change reaches the timer and not the label. Every one of
//  those is a bug nobody can reproduce, because it depends on which copy was read.
//
//  So the engine, the scheduler and the UI all *observe* this. Nothing else keeps playback state.
//
//  ── It is not a second simulation clock ────────────────────────────────────
//  `SimulationClock` remains the only source of simulated time. `position` here mirrors it, and only the engine
//  writes it — immediately after a step, through `advanced(to:)`. So it reflects rather than duplicates, and a
//  test asserts the two never disagree. Two clocks that must agree eventually do not.
//
//  ── Mode is a machine ──────────────────────────────────────────────────────
//  Same discipline as `SessionLifecycle`: legal moves enumerated, illegal ones refused rather than quietly
//  applied. Playing while seeking, or resuming a replay that was never loaded, are the states that would put
//  the transport and the engine out of step.
//

import Combine
import Foundation
import ATCSimKit

@MainActor
final class ReplayClock: ObservableObject {

    /// What the replay is doing.
    enum Mode: Equatable {

        /// Nothing loaded, or loaded and not started.
        case stopped

        /// Advancing on a timer.
        case playing

        /// Loaded, positioned, not advancing.
        case paused

        /// Being moved to a position. Distinct from `paused` because presentation is suppressed here and a
        /// second seek must not start while one is running — the two would interleave into a position neither
        /// asked for.
        case seeking
    }

    @Published private(set) var mode: Mode = .stopped

    /// Where the replay is, in simulated seconds. Mirrors `SimulationClock.tick`; only the engine writes it.
    @Published private(set) var position: Int = 0

    /// Playback multiplier. The same set the live simulation offers, so the transport reads the same either way.
    @Published private(set) var speed: Int = 1

    /// The span the recording covers. `0...0` until something is loaded.
    @Published private(set) var bounds: ClosedRange<Int> = 0...0

    static let speedOptions = MapViewModel.speedOptions

    /// The app target defaults to `MainActor` isolation, which makes an implicit deinit isolated, and releasing
    /// one off the main actor aborts the process. The fourth class in this project to need this — the rule is
    /// simply that **every `final class` in this target needs it**, and `IsolatedDeinitScanTests` is where that
    /// gets checked rather than remembered.
    nonisolated deinit { }

    // MARK: - Derived

    /// How far through, 0…1. For a scrubber; nothing else computes this.
    var progress: Double {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, Double(position - bounds.lowerBound) / Double(span)))
    }

    var isAtEnd: Bool { position >= bounds.upperBound }
    var isLoaded: Bool { bounds.upperBound > bounds.lowerBound }
    var isRunning: Bool { mode == .playing }

    /// Whether the transport should offer play. False at the end, so the button does not sit there doing
    /// nothing — the honest answer is "restart or seek back".
    var canPlay: Bool { isLoaded && !isAtEnd && (mode == .paused || mode == .stopped) }
    var canPause: Bool { mode == .playing }
    var canSeek: Bool { isLoaded && mode != .seeking }

    /// Real seconds between steps at the current speed.
    ///
    /// Speed changes the interval, never the step size — the same rule the live simulation follows, and the
    /// reason a replay at 30× reaches the same state as one at 1×.
    var tickInterval: TimeInterval {
        SimulationClock.tickInterval / Double(max(1, speed))
    }

    // MARK: - Transitions

    enum TransitionError: Error, Equatable, CustomStringConvertible {
        case notAllowed(from: String, to: String)

        var description: String {
            switch self {
            case .notAllowed(let from, let to): return "the replay cannot go from \(from) to \(to)"
            }
        }
    }

    /// Positions the clock over a freshly loaded recording.
    ///
    /// Resets to `.stopped` whatever it was: loading a different session while playing the last one would leave
    /// the transport describing a recording that is no longer there.
    func load(bounds: ClosedRange<Int>) {
        self.bounds = bounds
        position = bounds.lowerBound
        mode = .stopped
    }

    func unload() {
        bounds = 0...0
        position = 0
        speed = 1
        mode = .stopped
    }

    func play() throws {
        guard canPlay else { throw TransitionError.notAllowed(from: name(mode), to: "playing") }
        mode = .playing
    }

    func pause() throws {
        guard mode == .playing else { throw TransitionError.notAllowed(from: name(mode), to: "paused") }
        mode = .paused
    }

    /// Stops without unloading — the position and bounds stay, so the transport can offer play again.
    func stop() {
        guard mode != .stopped else { return }
        mode = isLoaded ? .paused : .stopped
    }

    /// Speed may change at any time, including mid-play, and does not interrupt.
    ///
    /// Clamped to the offered set rather than refused: a stray value from a slider is not worth an error, and
    /// silently accepting an unlisted speed would let the transport show something the timer is not doing.
    func setSpeed(_ requested: Int) {
        speed = Self.speedOptions.contains(requested)
            ? requested
            : (Self.speedOptions.last { $0 <= requested } ?? Self.speedOptions.first ?? 1)
    }

    /// Enters `.seeking`, returning what to restore afterwards.
    ///
    /// Scoped by returning the previous mode rather than remembering it here: a seek that failed partway would
    /// otherwise leave the clock stuck in `.seeking`, and a stuck transport is indistinguishable from a hung
    /// one.
    func beginSeeking() throws -> Mode {
        guard canSeek else { throw TransitionError.notAllowed(from: name(mode), to: "seeking") }
        let previous = mode
        mode = .seeking
        return previous
    }

    /// Leaves `.seeking`.
    ///
    /// A seek never resumes playing on its own. Landing somewhere and immediately running on is not what
    /// dragging a scrubber asks for, and it would make the position the user chose momentary.
    func endSeeking(restoring previous: Mode) {
        mode = previous == .stopped && !isLoaded ? .stopped : .paused
    }

    /// The engine reports where the simulation actually got to.
    ///
    /// The only writer of `position`, and it takes the simulation's own reading rather than incrementing —
    /// incrementing would be a second count of the same thing, free to disagree.
    func advanced(to tick: Int) {
        position = min(max(tick, bounds.lowerBound), bounds.upperBound)
        if isAtEnd, mode == .playing { mode = .paused }
    }

    private func name(_ mode: Mode) -> String {
        switch mode {
        case .stopped: return "stopped"
        case .playing: return "playing"
        case .paused:  return "paused"
        case .seeking: return "seeking"
        }
    }
}
