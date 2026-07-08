//
//  AzureLiveRecognizer.swift
//  VectraPro
//
//  Live (streaming) speech-to-text via the Azure Speech SDK using the custom
//  model from AzureConfig.plist. Compiled only when the SDK is present, so the
//  project keeps building before the dependency is added.
//

#if canImport(MicrosoftCognitiveServicesSpeech)

import AVFoundation
import Foundation
import MicrosoftCognitiveServicesSpeech

final class AzureLiveRecognizer: LiveTranscribing {

    var onPartial: ((String) -> Void)?

    private var recognizer: SPXSpeechRecognizer?
    private var finalized = ""

    func start() {
        requestMicrophone { [weak self] granted in
            guard granted else { return }
            self?.beginRecognition()
        }
    }

    func stop() {
        try? recognizer?.stopContinuousRecognition()
        recognizer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Private

    private func beginRecognition() {
        finalized = ""
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let config = AzureConfiguration.shared
            let speechConfig = try SPXSpeechConfiguration(
                subscription: config.azureSubscriptionKey,
                region: config.azureRegion
            )
            if !config.azureEndpointId.isEmpty {
                speechConfig.endpointId = config.azureEndpointId   // custom model
            }
            speechConfig.speechRecognitionLanguage = "en-US"

            let audio = SPXAudioConfiguration()   // default microphone
            let recognizer = try SPXSpeechRecognizer(
                speechConfiguration: speechConfig,
                audioConfiguration: audio
            )

            // Live, in-progress hypothesis.
            recognizer.addRecognizingEventHandler { [weak self] _, event in
                guard let self else { return }
                self.publish(self.combine(with: event.result.text))
            }
            // A finalised segment — append it.
            recognizer.addRecognizedEventHandler { [weak self] _, event in
                guard let self, let text = event.result.text, !text.isEmpty else { return }
                self.finalized = self.combine(with: text)
                self.publish(self.finalized)
            }

            self.recognizer = recognizer
            try recognizer.startContinuousRecognition()
        } catch {
            print("Azure live recognition failed to start: \(error)")
        }
    }

    private func combine(with current: String?) -> String {
        let partial = current ?? ""
        if finalized.isEmpty { return partial }
        if partial.isEmpty { return finalized }
        return finalized + " " + partial
    }

    private func publish(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onPartial?(text)
        }
    }

    private func requestMicrophone(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}

#endif
