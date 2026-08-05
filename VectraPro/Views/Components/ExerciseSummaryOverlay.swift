//
//  ExerciseSummaryOverlay.swift
//  VectraPro
//
//  Shown over the radar once an exercise's time is up.
//
//  Lifted out of MapScreen unchanged. It reads two values and has one button, so it
//  takes them as plain inputs rather than the whole view model — which also means it
//  can be previewed without a running simulation.
//

import SwiftUI

struct ExerciseSummaryOverlay: View {

    let exerciseName: String
    let durationSeconds: Int
    let onExit: () -> Void

    private static let accent = Color(red: 0.2, green: 1.0, blue: 0.4)

    var body: some View {
        ZStack {
            Color.black.opacity(0.75).ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Self.accent)

                Text("Exercise Complete")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    Text(exerciseName)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.85))

                    Text("Duration: \(durationSeconds.asTimerString)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Button(action: onExit) {
                    Text("Exit")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(width: 160, height: 44)
                        .background(Self.accent, in: Capsule())
                }
            }
            .padding(40)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.12), lineWidth: 1))
            .padding(32)
        }
    }
}

extension Int {
    /// Formats seconds as "HH:MM:SS".
    var asTimerString: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        let seconds = self % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

#Preview {
    ExerciseSummaryOverlay(exerciseName: "Delhi Approach — Mixed Traffic",
                           durationSeconds: 3_725) {}
}
