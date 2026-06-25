//
//  TranscriptionField.swift
//  VectraPro
//
//  Read-only field at the top that shows the live mic transcription.
//

import SwiftUI

struct TranscriptionField: View {

    @ObservedObject var viewModel: SpeechViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(viewModel.isRecording ? .green : .white.opacity(0.5))

            Text(displayText)
                .font(.callout)
                .foregroundStyle(viewModel.transcript.isEmpty ? .white.opacity(0.45) : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var displayText: String {
        if !viewModel.transcript.isEmpty { return viewModel.transcript }
        if viewModel.isTranscribing { return "Transcribing…" }
        return viewModel.isRecording ? "Listening…" : "Hold the mic to talk"
    }
}
