//
//  SpeechViewModel.swift
//  VectraPro
//
//  Push-to-talk transcription. When the Azure Speech SDK is present, transcribes
//  live as you speak. Otherwise falls back to record-then-upload (REST).
//  Slide-to-cancel discards the result.
//
//  The transcription field is shown while the mic is active and for a short
//  moment after the result arrives, then auto-hides.
//

import Combine
import SpeechKit
import ATCParserKit
import Foundation

@MainActor
final class SpeechViewModel: ObservableObject {

    static let shared = SpeechViewModel()

    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var showField = false
    @Published var isCancelling = false

    /// Fired with the final transcript when a command is ready to process.
    var onCommand: ((String) -> Void)?

    /// How long the field stays visible after a result before auto-hiding.
    private let autoHideDelay: TimeInterval = 3

    // Prefer offline Vosk for live transcription; fall back to Azure (or REST) if
    // no bundled Vosk model is available.
    private let live: LiveTranscribing? = VoskLiveRecognizer() ?? LiveSpeechRecognizerFactory.make()
    private let recorder = AudioRecorder()
    private let service = TranscriptionService()
    private var hideTask: Task<Void, Never>?

    init() {
        live?.onPartial = { [weak self] text in
            guard let self, self.isRecording else { return }
            // Clean + ICAO-uppercase live too, so the field is uppercase from the
            // first partial instead of flipping to caps only at the end.
            self.transcript = TranscriptCleaner.displayText(text)
        }
    }

    /// Request mic access up front so the first press starts immediately.
    func prepare() {
        recorder.requestPermission { _ in }
    }

    func beginTalking() {
        guard !isRecording, !isTranscribing else { return }
        hideTask?.cancel()
        isCancelling = false
        transcript = ""
        showField = true
        CommandFeedbackManager.shared.micStarted()

        if let live {
            isRecording = true
            live.start()
        } else {
            recorder.requestPermission { [weak self] granted in
                guard let self, granted else { return }
                do {
                    try self.recorder.start()
                    self.isRecording = true
                } catch {
                    print("Recording failed to start: \(error)")
                }
            }
        }
    }

    func finishTalking() {
        guard isRecording else { return }

        if live != nil {
            live?.stop()
            isRecording = false
            CommandFeedbackManager.shared.micStopped()
            // Clean recognizer quirks + ICAO-uppercase for display (and command).
            transcript = TranscriptCleaner.displayText(transcript)
            if !transcript.isEmpty { onCommand?(transcript) }
            scheduleAutoHide()
            return
        }

        // REST fallback: stop recording and upload the WAV.
        isRecording = false
        let recordedURL = recorder.stop()
        CommandFeedbackManager.shared.micStopped()
        guard let url = recordedURL else { scheduleAutoHide(); return }

        isTranscribing = true
        Task {
            do {
                let text = TranscriptCleaner.displayText(try await service.transcribe(wavURL: url))
                transcript = text.isEmpty ? "(no speech recognized)" : text
                if !text.isEmpty { onCommand?(text) }
            } catch TranscriptionError.notConfigured {
                transcript = "⚠️ AzureConfig.plist missing key/endpoint"
            } catch {
                transcript = "Failed: \(error.localizedDescription)"
                print("Transcription error: \(error)")
            }
            isTranscribing = false
            scheduleAutoHide()
        }
    }

    func cancelTalking() {
        guard isRecording else { return }
        if let live {
            live.stop()
        } else {
            recorder.cancel()
        }
        hideTask?.cancel()
        isRecording = false
        isCancelling = false
        transcript = ""
        showField = false
    }

    // MARK: - Command keypad preview

    /// Show / update the command sentence (from the keypad) in the field.
    func previewCommand(_ text: String) {
        guard !isRecording else { return }
        hideTask?.cancel()
        transcript = text
        showField = true
    }

    /// Done with the keypad (applied or cancelled) — clear the field at once.
    func clearPreview() {
        guard !isRecording else { return }
        hideTask?.cancel()
        transcript = ""
        showField = false
    }

    // MARK: - Auto-hide

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.autoHideDelay ?? 3) * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isRecording else { return }
            self.showField = false
            self.transcript = ""
        }
    }
}
