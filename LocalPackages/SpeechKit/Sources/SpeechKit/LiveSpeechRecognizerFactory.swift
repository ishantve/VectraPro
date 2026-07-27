//
//  LiveSpeechRecognizerFactory.swift
//  VectraPro
//
//  Returns the Azure live recognizer when the SDK is present, otherwise nil
//  (the view model then falls back to record-then-REST transcription).
//

import Foundation

public enum LiveSpeechRecognizerFactory {

    public static func make() -> LiveTranscribing? {
        #if canImport(MicrosoftCognitiveServicesSpeech)
        return AzureLiveRecognizer()
        #else
        return nil
        #endif
    }
}
