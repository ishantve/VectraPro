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
//  • One voice for everything the app says. An earlier version gave "controller"
//    and "pilot" separate voices, which was based on a wrong reading: the app
//    never speaks as the controller — that is the human at the microphone. All
//    synthesised speech is the simulated pilot reading back, or the system
//    refusing, and splitting those two across voices only made the output sound
//    inconsistent from one command to the next.
//
//    The voice is chosen deterministically rather than taking whatever the system
//    lists first, so it does not change between launches or devices.
//
//  The audio session is set for playback before speaking. The Azure recogniser
//  puts the session in `.record` while the mic is live and deactivates it on stop,
//  so speech worked only by falling back on the implicit default. That is fragile
//  once readbacks get longer than a mic gap.
//

import AudioToolbox
import AVFoundation

enum FeedbackSound {

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
    static func speak(_ text: String, interrupting: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        activatePlayback()

        if interrupting { synthesizer.stopSpeaking(at: .immediate) }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice
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

    // MARK: - Voice

    /// Language preference, most specific first — an Indian-English pilot suits the
    /// airspace being controlled, with the wider variants as fallbacks.
    private static let languages = ["en-IN", "en-GB", "en-US", "en-AU"]

    /// The single voice used for everything the app says.
    ///
    /// Chosen once, and chosen deterministically: within a language the candidates
    /// are sorted by identifier, so the same device always gets the same voice
    /// instead of whatever `speechVoices()` happened to list first. A male voice is
    /// preferred; if the device has none installed for any of the languages above,
    /// any English voice is better than silence.
    private static let voice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.identifier < $1.identifier }

        for language in languages {
            if let male = english.first(where: { $0.language == language && $0.gender == .male }) {
                return male
            }
        }
        if let anyMale = english.first(where: { $0.gender == .male }) { return anyMale }
        for language in languages {
            if let any = english.first(where: { $0.language == language }) { return any }
        }
        return english.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

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
