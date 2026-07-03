//
//  CommandFeedbackManager.swift
//  VectraPro
//
//  Central manager for all ATC command audio feedback.
//  Both the keyboard and voice command paths route every sound and TTS
//  utterance through here — nothing else calls FeedbackSound directly.
//

import Foundation

final class CommandFeedbackManager {

    static let shared = CommandFeedbackManager()
    private init() {}

    // MARK: - PTT mic lifecycle tones

    /// Short "mic open" tone — call when voice recording starts.
    func micStarted() {
        FeedbackSound.micOn()
    }

    /// Short "mic closed" tone — call when voice recording stops.
    func micStopped() {
        FeedbackSound.micOff()
    }

    // MARK: - Command results

    /// ATC-style readback after a command is successfully applied.
    /// Joins multiple commands with a comma, prefixed with the callsign.
    /// e.g. "ACA98, turn left heading 270, speed 250 knots"
    func commandAccepted(callsign: String, commands: [AircraftCommand]) {
        let text = commands.map { readback(for: $0) }.joined(separator: ", ")
        FeedbackSound.speak("\(callsign), \(text)")
    }

    /// Speaks an error phrase when a command cannot be applied.
    func commandError(_ phrase: String) {
        FeedbackSound.speak(phrase)
    }

    /// Standard error: no aircraft is selected when a command is issued.
    func aircraftNotFound() {
        commandError("Aircraft not found")
    }

    // MARK: - Readback text per command type

    /// Converts a single command into a natural-language ATC readback phrase.
    private func readback(for command: AircraftCommand) -> String {
        switch command {
        case .heading(let h):
            return "heading \(Int(h))"
        case .headingTurn(let h, let dir):
            return "turn \(dir == .left ? "left" : "right") heading \(Int(h))"
        case .relativeTurn(let deg, let dir):
            return "turn \(dir == .left ? "left" : "right") \(Int(deg)) degrees"
        case .presentHeading:
            return "present heading"
        case .flightLevel(let fl):
            return "flight level \(fl)"
        case .altitudeBlock(let low, let high):
            return "maintain block flight level \(low) through \(high)"
        case .speed(let kts):
            return "\(Int(kts)) knots"
        case .minSpeed(let kts):
            return "maintain \(Int(kts)) knots or greater"
        case .maxSpeed(let kts):
            return "do not exceed \(Int(kts)) knots"
        }
    }
}
