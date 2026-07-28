//
//  AudioRecorder.swift
//  VectraPro
//
//  Records microphone audio to a 16 kHz mono PCM WAV file (the format Azure
//  speech-to-text expects).
//

import AVFoundation

public final class AudioRecorder {

    private var recorder: AVAudioRecorder?
    public private(set) var fileURL: URL?

    public init() {}

    public func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    public func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vectra_speech.wav")
        try? FileManager.default.removeItem(at: url)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.record()
        self.recorder = recorder
        self.fileURL = url
    }

    /// Stop recording and return the finished file.
    @discardableResult
    public func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        return fileURL
    }

    /// Stop and discard the recording.
    public func cancel() {
        recorder?.stop()
        recorder = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
