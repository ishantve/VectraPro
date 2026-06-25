//
//  FeedbackSound.swift
//  VectraPro
//
//  Short PTT-style start/stop tones using built-in iOS system sounds.
//

import AudioToolbox

enum FeedbackSound {
    /// "begin record" tone — played when the mic turns on.
    static func micOn() { AudioServicesPlaySystemSound(1113) }

    /// "end record" tone — played when the mic turns off.
    static func micOff() { AudioServicesPlaySystemSound(1114) }
}
