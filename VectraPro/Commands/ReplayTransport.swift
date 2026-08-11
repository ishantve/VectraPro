//
//  ReplayTransport.swift
//  VectraPro
//
//  The boundary a replay UI talks to: one value to render, one enum to send.
//
//  ── Why not just bind to the clock ─────────────────────────────────────────
//  A SwiftUI view could observe `ReplayClock` directly and call the engine, and for SwiftUI alone that would be
//  enough. It would also make SwiftUI the shape of the boundary — and this engine is meant to be usable from
//  UIKit, React Native and Unity without changing. None of those can observe an `ObservableObject` or hold a
//  `@Published`.
//
//  So the boundary is a **plain value** describing what to draw and a **plain enum** describing what was asked
//  for. Both are `Codable`, so the same pair crosses a React Native bridge or a C interface as JSON with nothing
//  added. SwiftUI gets the same two things and simply happens to be able to observe them cheaply.
//
//  ── The UI owns nothing ────────────────────────────────────────────────────
//  There is no state here either — `state` is computed from the clock on every read. A transport that cached
//  `isPlaying` would be a fourth copy of a fact that already has one authority, and the whole point of
//  `ReplayClock` was to stop that.
//

import Foundation
import ATCReplayKit

// MARK: - What to render

/// Everything a replay UI needs to draw, and nothing else.
///
/// Raw values, not formatted strings: how to write a duration is a presentation decision, and a transport that
/// returned `"12:45"` would have made it on the UI's behalf — differently from how Unity or a screen reader would
/// want it.
struct ReplayTransportState: Equatable, Codable, Sendable {

    /// Simulated seconds from the start of the recording.
    let position: Int

    /// Simulated seconds the recording covers.
    let duration: Int

    /// `"stopped"`, `"playing"`, `"paused"`, `"seeking"`.
    ///
    /// A string rather than the Swift enum, so a consumer that cannot see Swift types can still switch on it. New
    /// modes are additive for the same reason a source is: an unknown one renders as unknown rather than failing.
    let mode: String

    let speed: Double

    /// The speeds this build offers, so a picker does not hard-code them and drift from what the engine accepts.
    let availableSpeeds: [Double]

    /// 0…1, for a scrubber. Computed by the clock; nothing downstream recomputes it.
    let progress: Double

    let isLoaded: Bool
    let canPlay: Bool
    let canPause: Bool
    let canSeek: Bool
    let isAtEnd: Bool

    /// True when this device computes the simulation the way the recording's did.
    ///
    /// A UI should say so: a replay on a mismatched architecture is worth watching and must not be scored, and
    /// leaving that invisible is how a reviewer grades something they should not.
    let isReproducibleHere: Bool

    /// Nothing loaded.
    static let empty = ReplayTransportState(
        position: 0, duration: 0, mode: "stopped", speed: 1,
        availableSpeeds: ReplayClock.speedOptions, progress: 0,
        isLoaded: false, canPlay: false, canPause: false, canSeek: false,
        isAtEnd: false, isReproducibleHere: true)
}

// MARK: - What was asked for

/// Everything a replay UI can ask the engine to do.
///
/// An enum rather than a set of methods so the surface is enumerable: a bridge can accept it as JSON, and adding
/// a control is one case plus one branch rather than a new function on four platforms.
enum ReplayCommand: Equatable, Codable, Sendable {
    case play
    case pause
    case restart
    case stepForward
    case seek(tick: Int)
    case setSpeed(Double)

    /// Fork here and go live. Not a mode change — a new session; see `ReplayEngine.continueLive`.
    case continueLive(label: String)
}

// MARK: - Transport

/// The one thing a replay UI holds.
@MainActor
final class ReplayTransport {

    private let engine: ReplayEngine

    /// The last command that failed, for a UI to surface.
    ///
    /// Kept because the alternative is `perform` throwing into a button action, where the error is either ignored
    /// or crashes a view. A refused transport move — playing what is already playing — is a thing to show, not a
    /// thing to fail on.
    private(set) var lastError: String?

    init(engine: ReplayEngine) {
        self.engine = engine
    }

    nonisolated deinit { }

    /// The clock, so SwiftUI can observe it. Other platforms poll `state` instead.
    var clock: ReplayClock { engine.clock }

    /// What to draw. Computed, never cached — see the file header.
    var state: ReplayTransportState {
        let clock = engine.clock
        return ReplayTransportState(
            position: clock.position,
            duration: clock.bounds.upperBound,
            mode: modeName(clock.mode),
            speed: clock.speed,
            availableSpeeds: ReplayClock.speedOptions,
            progress: clock.progress,
            isLoaded: clock.isLoaded,
            canPlay: clock.canPlay,
            canPause: clock.canPause,
            canSeek: clock.canSeek,
            isAtEnd: clock.isAtEnd,
            isReproducibleHere: engine.loaded?.isReproducibleHere ?? true)
    }

    /// Runs a command.
    ///
    /// Does not throw. A UI action is not a place to handle an error, and a refused move is worth showing rather
    /// than failing on — so the reason lands in `lastError` and the caller carries on.
    @discardableResult
    func perform(_ command: ReplayCommand) -> Bool {
        lastError = nil
        do {
            switch command {
            case .play:                       try engine.play()
            case .pause:                      try engine.pause()
            case .restart:                    try engine.restart()
            case .stepForward:                _ = engine.stepForward()
            case .seek(let tick):             try engine.seek(to: tick)
            case .setSpeed(let speed):        engine.setSpeed(speed)
            case .continueLive(let label):    _ = try engine.continueLive(label: label)
            }
            return true
        } catch {
            lastError = "\(error)"
            return false
        }
    }

    /// Seeks by fraction, for a scrubber that works in 0…1 and should not have to know about ticks.
    @discardableResult
    func seek(toProgress fraction: Double) -> Bool {
        let bounds = engine.clock.bounds
        let span = bounds.upperBound - bounds.lowerBound
        let target = bounds.lowerBound + Int((Double(span) * min(1, max(0, fraction))).rounded())
        return perform(.seek(tick: target))
    }

    private func modeName(_ mode: ReplayClock.Mode) -> String {
        switch mode {
        case .stopped: return "stopped"
        case .playing: return "playing"
        case .paused:  return "paused"
        case .seeking: return "seeking"
        }
    }
}
