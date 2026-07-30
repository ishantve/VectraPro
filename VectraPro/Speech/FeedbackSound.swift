//
//  FeedbackSound.swift
//  VectraPro
//
//  PTT tones and spoken output.
//
//  Two things here are deliberate and were previously wrong:
//
//  • Utterances queue instead of cancelling each other. Every `speak` used to
//    begin with `stopSpeaking(.immediate)`, which was harmless while one command
//    produced one sentence — but a transmission carrying several instructions, or
//    several aircraft, produces several readbacks, and all but the last were cut
//    off mid-word. AVSpeechSynthesizer queues on its own; the cancel was what
//    prevented it. Interrupting is still available, but only where it is meant.
//
//  • The controller and the pilot get different voices. The controller speaks the
//    instruction, the pilot reads it back — in one voice the exchange is
//    indistinguishable, which defeats the point of a training simulator.
//
//  The audio session is set for playback before speaking. The Azure recogniser
//  puts the session in `.record` while the mic is live and deactivates it on stop,
//  so speech worked only by falling back on the implicit default. That is fragile
//  once readbacks get longer than a mic gap.
//

import AudioToolbox
import AVFoundation

enum FeedbackSound {

    /// Who is speaking. The pilot reads back; the controller and the system do not
    /// share that voice.
    enum Voice {
        case pilot
        case system
    }

    // MARK: - PTT tones

    /// "begin record" tone — played when the mic turns on.
    static func micOn() { AudioServicesPlaySystemSound(1113) }

    /// "end record" tone — played when the mic turns off.
    static func micOff() { AudioServicesPlaySystemSound(1114) }

    // MARK: - Speech

    private static let synthesizer = AVSpeechSynthesizer()

    /// Speaks `text`, queued behind anything already speaking.
    ///
    /// Pass `interrupting: true` only for something that genuinely supersedes what
    /// is being said — an error the controller needs now. Readbacks must queue, or
    /// a three-instruction transmission is heard as one instruction.
    static func speak(_ text: String,
                      as voice: Voice = .pilot,
                      interrupting: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        activatePlayback()

        if interrupting { synthesizer.stopSpeaking(at: .immediate) }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = self.voice(for: voice)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        // A short gap between queued readbacks, so two instructions do not run
        // into each other as one sentence.
        utterance.postUtteranceDelay = 0.15
        synthesizer.speak(utterance)
    }

    /// Stops whatever is being spoken — used when the mic opens, so a readback
    /// does not talk over the controller.
    static func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - Voices

    /// Preference order per role, falling back to whatever English voice exists.
    /// Two roles must not resolve to the same voice unless the device only has one.
    private static let preferences: [Voice: [String]] = [
        .pilot:  ["en-IN", "en-GB", "en-US"],
        .system: ["en-US", "en-GB", "en-IN"],
    ]

    private static let resolved: [Voice: AVSpeechSynthesisVoice?] = {
        let available = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        var chosen: [Voice: AVSpeechSynthesisVoice?] = [:]
        var taken = Set<String>()

        for role in [Voice.pilot, Voice.system] {
            let picked = (preferences[role] ?? []).lazy
                .compactMap { language in
                    available.first { $0.language == language && !taken.contains($0.identifier) }
                }
                .first
                ?? available.first { !taken.contains($0.identifier) }
                ?? available.first
            if let picked { taken.insert(picked.identifier) }
            chosen[role] = picked
        }
        return chosen
    }()

    private static func voice(for role: Voice) -> AVSpeechSynthesisVoice? {
        resolved[role] ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: - Audio session

    /// Puts the session in a state where speech is audible, without stopping the
    /// recogniser from taking it back for `.record` on the next transmission.
    private static func activatePlayback() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard session.category != .playback else { return }
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }
}
