//
//  CommandFeedbackManager.swift
//  VectraPro
//
//  Central manager for all ATC command audio feedback and the on-screen log.
//  Both the keyboard and voice command paths route every sound and TTS
//  utterance through here — nothing else calls FeedbackSound directly.
//

import Combine
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

    func micStarted() { FeedbackSound.micOn() }
    func micStopped() { FeedbackSound.micOff() }

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
    func commandError(_ phrase: String) {
        log(phrase, isError: true)
        FeedbackSound.speak(phrase)
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
