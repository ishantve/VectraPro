//
//  FeedbackSound.swift
//  VectraPro
//
//  Short PTT-style start/stop tones using built-in iOS system sounds.
//

import AudioToolbox
import AVFoundation

enum FeedbackSound {
    /// "begin record" tone — played when the mic turns on.
    static func micOn() { AudioServicesPlaySystemSound(1113) }

    /// "end record" tone — played when the mic turns off.
    static func micOff() { AudioServicesPlaySystemSound(1114) }

    /// Speak an error or status phrase using the device TTS engine.
    private static let synthesizer = AVSpeechSynthesizer()
    static func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate  = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }
}
