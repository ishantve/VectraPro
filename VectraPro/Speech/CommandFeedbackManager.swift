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
    /// callsign once at the end. Nothing here composes it, and nothing here can: the
    /// English this class used to assemble from the command enum had already lost
    /// which template was spoken, so the backend's own `readBackText` could never be
    /// used. That code is gone.
    func readback(_ spoken: String) {
        log(spoken, isError: false)
        FeedbackSound.speak(spoken)
    }

    // MARK: - Command results

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

}
