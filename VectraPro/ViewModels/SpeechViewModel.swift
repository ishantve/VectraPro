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

    private let live = LiveSpeechRecognizerFactory.make()
    private let recorder = AudioRecorder()
    private let service = TranscriptionService()
    private var hideTask: Task<Void, Never>?

    init() {
        live?.onPartial = { [weak self] text in
            guard let self, self.isRecording else { return }
            self.transcript = text
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
        FeedbackSound.micOn()

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
            FeedbackSound.micOff()
            if !transcript.isEmpty { onCommand?(transcript) }
            scheduleAutoHide()
            return
        }

        // REST fallback: stop recording and upload the WAV.
        isRecording = false
        let recordedURL = recorder.stop()
        FeedbackSound.micOff()
        guard let url = recordedURL else { scheduleAutoHide(); return }

        isTranscribing = true
        Task {
            do {
                let text = try await service.transcribe(wavURL: url)
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
