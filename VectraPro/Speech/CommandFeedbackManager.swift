//
//  CommandFeedbackManager.swift
//  VectraPro
//
//  Central manager for all ATC command audio feedback and the on-screen log.
//  Both the keyboard and voice command paths route every sound and TTS
//  utterance through here — nothing else calls FeedbackSound directly.
//

import Combine
import ATCSimKit
import Foundation

// MARK: - FeedbackEntry

struct FeedbackEntry: Identifiable {
    let id      = UUID()
    let text:    String
    let isError: Bool
}

// MARK: - CommandFeedbackManager

final class CommandFeedbackManager: ObservableObject {

    static let shared = CommandFeedbackManager()
    private init() {}

    /// Recent feedback entries (newest first). Auto-expires after 8 s each.
    @Published var feedbackLog: [FeedbackEntry] = []
    private let maxLogEntries = 8

    // MARK: - PTT mic lifecycle tones

    func micStarted() {
        // Don't let a readback talk over the controller keying the mic.
        FeedbackSound.stopSpeaking()
        FeedbackSound.micOn()
    }

    func micStopped() { FeedbackSound.micOff() }

    // MARK: - Pre-rendered readback

    /// Speaks a readback that was already rendered as ICAO phraseology.
    ///
    /// The text arrives finished — template wording, numbers spoken digit by digit,
    /// callsign once at the end. Nothing here composes it, which is the point:
    /// `readback(for:)` below builds its own English from the simulator's command
    /// enum, and by then which template was spoken has been forgotten, so the
    /// backend's own `readBackText` could never be used.
    func readback(_ spoken: String) {
        log(spoken, isError: false)
        FeedbackSound.speak(spoken)
    }

    // MARK: - Command results

    /// ATC-style readback after a command is successfully applied.
    func commandAccepted(callsign: String, commands: [AircraftCommand]) {
        let detail = commands.isEmpty
            ? "wilco"
            : commands.map { readback(for: $0) }.joined(separator: ", ")
        let text = "\(callsign), \(detail)"
        log(text, isError: false)
        FeedbackSound.speak(text)
    }

    /// Speaks an error phrase when a command cannot be applied.
    /// Interrupts: a rejection the controller needs to hear now outranks a
    /// readback still being spoken.
    func commandError(_ phrase: String) {
        log(phrase, isError: true)
        FeedbackSound.speak(phrase, interrupting: true)
    }

    /// Standard error: no aircraft selected / found when a command is issued.
    func aircraftNotFound() {
        commandError("Aircraft not found")
    }

    // MARK: - Log management

    private func log(_ text: String, isError: Bool) {
        let entry = FeedbackEntry(text: text, isError: isError)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.feedbackLog.insert(entry, at: 0)
            if self.feedbackLog.count > self.maxLogEntries {
                self.feedbackLog = Array(self.feedbackLog.prefix(self.maxLogEntries))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.feedbackLog.removeAll { $0.id == entry.id }
        }
    }

    /// Altitudes are described the way they would have been said.
    private func spokenAltitude(_ feet: Double) -> String {
        feet >= 10_000 ? "flight level \(Int(feet / 100))" : "\(Int(feet)) feet"
    }

    // MARK: - Readback text per command type

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
        case .stopTurn(let h):
            return "stop turn heading \(Int(h))"
        case .altitude(let feet):
            return spokenAltitude(feet)
        case .altitudeBlock(let low, let high):
            return "maintain block flight level \(Int(low / 100)) through \(Int(high / 100))"
        case .speed(let kts):
            return "\(Int(kts)) knots"
        case .minSpeed(let kts):
            return "maintain \(Int(kts)) knots or greater"
        case .maxSpeed(let kts):
            return "do not exceed \(Int(kts)) knots"
        case .stopClimb(let feet):
            return "stop climb at \(spokenAltitude(feet))"
        case .stopDescent(let feet):
            return "stop descent at \(spokenAltitude(feet))"
        case .hold(let fix):
            return "hold at \(fix.uppercased())"
        case .proceedDirect(let fix):
            return "proceed direct to \(fix.uppercased())"
        case .squawk(let code):
            return "squawk \(code)"
        case .clearedForTakeoff(let runway):
            return runway.map { "runway \($0) cleared for takeoff" } ?? "cleared for takeoff"
        case .goAround:
            return "going around"
        case .interceptLocalizer(let runway):
            return "intercept the localizer runway \(runway)"
        }
    }
}
