//
//  VoskLiveRecognizer.swift
//  VectraPro
//
//  Offline (Vosk) implementation of SpeechKit's LiveTranscribing, so the existing
//  push-to-talk pipeline (SpeechViewModel) can stream from Vosk instead of Azure —
//  no change to SpeechKit. The acoustic model ships in the app bundle under
//  Models/ (a folder reference the developer populates — see Models/README.md);
//  VoskSpeechKit itself no longer carries one. If no model is present, init fails
//  and SpeechViewModel falls back to Azure.
//

import Foundation
import SpeechKit
import VoskSpeechKit

@MainActor
final class VoskLiveRecognizer: LiveTranscribing {

    var onPartial: ((String) -> Void)?

    private let model: VoskSpeechModel
    private var session: VoskSpeechSession?

    /// Fails (returns nil) if no Vosk model is present in the app bundle's Models/
    /// folder, so the caller can fall back to another recognizer.
    init?() {
        guard let modelsRoot = Bundle.main.resourceURL?.appendingPathComponent("Models"),
              let info = VoskModelLocator(modelsRootPath: modelsRoot.path).latest(),
              let model = try? VoskSpeechModel(info: info) else { return nil }
        self.model = model
    }

    func start() {
        do {
            let session = try VoskSpeechSession(model: model)
            // Emit the running transcript live; also surface a finalized utterance
            // (mid-hold) as the latest partial so SpeechViewModel keeps it.
            session.onPartial = { [weak self] t in
                MainActor.assumeIsolated { if !t.value.isEmpty { self?.onPartial?(t.value) } }
            }
            session.onResult = { [weak self] t in
                MainActor.assumeIsolated { if !t.value.isEmpty { self?.onPartial?(t.value) } }
            }
            try session.start()
            self.session = session
        } catch {
            // Leave onPartial unspoken; the field simply stays empty on failure.
        }
    }

    func stop() {
        session?.stop()
        session = nil
    }
}
