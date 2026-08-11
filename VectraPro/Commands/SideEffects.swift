//
//  SideEffects.swift
//  VectraPro
//
//  The boundary between the simulation and everything the simulation *causes*.
//
//  ── Two kinds of thing happen when a command is applied ─────────────────────
//  A **simulation state change** — an aircraft's target altitude, a pending report, a spawn countdown.
//  Deterministic, reproducible from a seed and an input, and the thing replay exists to recreate.
//
//  A **side effect** — a readback spoken aloud, a line in the feedback log, an analytics counter, a
//  haptic, a network call. Non-deterministic, outward-facing, and *not* part of the simulation. Replay
//  must reproduce the first exactly and must not re-trigger the second unless asked to.
//
//  The distinction is not obvious at a call site. `feedback.readback("CLIMBING…")` looks like part of
//  handling the command, and inside it a device synthesiser starts talking. Seeking through four hundred
//  ticks would queue forty utterances, and an instructor scrubbing a session would hear a session they
//  are not watching.
//
//  ── Why a gate rather than a flag ──────────────────────────────────────────
//  The alternative is `if !isSeeking { speak(…) }` at each call site, which decays: the next side effect
//  someone adds will not have it, and nothing will notice because the failure is "a noise happened", not
//  a crash or a wrong number.
//
//  So the mode lives in one object that every effect passes through. The simulation code does not know
//  which mode it is in and cannot get the check wrong, because it does not make the check.
//
//  ── Adding a side effect ───────────────────────────────────────────────────
//  Give it a method here. Do **not** reach for a singleton from simulation code — `SideEffectScanTests`
//  fails the build if you do, because a side effect that bypasses this boundary is one replay cannot
//  suppress, and the symptom appears months later as a replay that phones home.
//

import Foundation
import ATCSimKit

// MARK: - Mode

/// Whether side effects reach the outside world.
enum SideEffectMode: Equatable {

    /// A live exercise. Everything happens.
    case live

    /// Nothing leaves the app.
    ///
    /// For seeking, and for a replay a reviewer is scrubbing rather than watching: the simulation still
    /// runs exactly as it did, and nobody hears four hundred ticks of readbacks.
    case suppressed

    /// A replay being watched deliberately: speech and the log play, but nothing that reports outward —
    /// analytics, telemetry, notifications — fires again. A replay is not a second exercise, and counting
    /// it as one would corrupt the numbers about the first.
    case replaying

    /// Whether speech and on-screen feedback happen.
    var allowsPresentation: Bool { self != .suppressed }

    /// Whether anything is reported outside the app.
    ///
    /// False for a replay: the events being replayed were already counted when they were recorded, so
    /// counting them again would inflate every statistic each time a session is reviewed.
    var allowsReporting: Bool { self == .live }
}

// MARK: - Gate

/// The one boundary every non-deterministic effect crosses.
///
/// Conforms to `CommandFeedback`, so it drops into every place the simulation already speaks through
/// without any of them learning about modes.
@MainActor
final class SideEffectGate: CommandFeedback {

    /// Set by whoever is driving: live simulation, replay, or a seek.
    var mode: SideEffectMode

    private let presentation: CommandFeedback

    /// What was dropped, per mode change. Not for correctness — for saying "38 readbacks suppressed while
    /// seeking" in a diagnostic, instead of a silence nobody can account for.
    private(set) var suppressedCount = 0

    init(presentation: CommandFeedback, mode: SideEffectMode = .live) {
        self.presentation = presentation
        self.mode = mode
    }

    nonisolated deinit { }

    /// Runs `body` with side effects suppressed, restoring the previous mode afterwards.
    ///
    /// Scoped rather than a pair of set-calls, so an early return or a thrown error cannot leave the app
    /// permanently mute — which is exactly the bug a manual pair produces, and a silent one.
    func suppressing<T>(_ body: () throws -> T) rethrows -> T {
        let previous = mode
        mode = .suppressed
        defer { mode = previous }
        return try body()
    }

    // MARK: CommandFeedback — presentation

    func readback(_ spoken: String) {
        guard mode.allowsPresentation else { return suppressedCount += 1 }
        presentation.readback(spoken)
    }

    func commandError(_ phrase: String) {
        guard mode.allowsPresentation else { return suppressedCount += 1 }
        presentation.commandError(phrase)
    }

    func aircraftNotFound() {
        guard mode.allowsPresentation else { return suppressedCount += 1 }
        presentation.aircraftNotFound()
    }

    // MARK: Reporting

    /// Anything that leaves the device or accumulates a statistic — analytics, telemetry, a crash
    /// breadcrumb, a notification.
    ///
    /// Nothing calls this yet. It exists so the first analytics call has an obvious home on the correct
    /// side of the boundary, rather than being added as a singleton somebody later has to find and move.
    func report(_ name: String, _ parameters: [String: String] = [:]) {
        guard mode.allowsReporting else { return suppressedCount += 1 }
        #if DEBUG
        print("[report] \(name) \(parameters.isEmpty ? "" : "\(parameters)")")
        #endif
    }

    func resetSuppressedCount() { suppressedCount = 0 }
}
