//
//  PushToTalkMicButton.swift
//  VectraPro
//
//  Hold-to-talk mic button. Press to start transcribing; slide left past the
//  threshold and release to cancel (clears the text).
//

import SwiftUI

struct PushToTalkMicButton: View {

    @ObservedObject var viewModel: SpeechViewModel

    @State private var dragOffset: CGFloat = 0
    private let cancelThreshold: CGFloat = 80

    var body: some View {
        HStack(spacing: 12) {
            if viewModel.isRecording {
                Label("slide to cancel", systemImage: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.isCancelling ? .red : .white.opacity(0.85))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            micCircle
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.isRecording)
        .animation(.easeInOut(duration: 0.15), value: viewModel.isCancelling)
    }

    private var micCircle: some View {
        Image(systemName: viewModel.isRecording ? "mic.fill" : "mic")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(circleColor, in: Circle())
            .scaleEffect(viewModel.isRecording ? 1.15 : 1)
            .offset(x: dragOffset)
            .gesture(pressDrag)
    }

    private var circleColor: Color {
        if viewModel.isCancelling { return .red }
        return viewModel.isRecording ? .green : .black.opacity(0.6)
    }

    private var pressDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !viewModel.isRecording { viewModel.beginTalking() }
                // Slide left only, clamped.
                dragOffset = max(-120, min(0, value.translation.width))
                viewModel.isCancelling = value.translation.width < -cancelThreshold
            }
            .onEnded { _ in
                if viewModel.isCancelling {
                    viewModel.cancelTalking()
                } else {
                    viewModel.finishTalking()
                }
                withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
            }
    }
}
