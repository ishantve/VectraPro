//
//  ExerciseCard.swift
//  VectraPro
//
//  Exercise detail card on the home screen — title, settings, and a START
//  button that opens the radar.
//

import SwiftUI

struct ExerciseCard: View {

    let exercise: Exercise
    let number: Int
    /// Loads the exercise detail; returns when done so navigation can proceed.
    let onStart: () async -> Void
    var onSettings: () -> Void = {}
    var onReplay: () -> Void = {}

    @State private var isStarting = false

    private let accent = Color(red: 0.32, green: 0.56, blue: 0.95)
    private let cardFill = LinearGradient(
        colors: [Color(red: 0.07, green: 0.11, blue: 0.20),
                 Color(red: 0.02, green: 0.04, blue: 0.09)],
        startPoint: .top, endPoint: .bottom
    )

    var body: some View {
        VStack(spacing: 0) {

            // Top: settings icon (leading), "Exercise N" centered, replay (trailing).
            Text("Exercise \(number)")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    Button(action: onSettings) {
                        Image("settings")
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .overlay(alignment: .trailing) {
                    Button(action: onReplay) {
                        Image("replay")
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }

            // Big title — fixed-height block so Settings starts at the same
            // vertical position on every card (1- or 2-line titles).
            Text(exercise.exerciseName)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .top)
                .padding(.top, 24)

            // Settings.
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.6))
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .frame(height: 1)

                settingRow("Weather", exercise.weatherValue)
                settingRow("Departure", exercise.departureValue)
                settingRow("Incoming", exercise.arrivalValue)
            }

            Spacer(minLength: 24)

            // START → loads exercise detail, then opens the radar.
            Button {
                guard !isStarting else { return }
                Task {
                    isStarting = true
                    await onStart()
                    isStarting = false
                }
            } label: {
                Group {
                    if isStarting {
                        ProgressView().tint(.white)
                    } else {
                        Text("START")
                            .font(.title3.weight(.medium))
                            .tracking(2)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.7), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isStarting)
        }
        .padding(28)
        .frame(width: 360, height: 600)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(accent.opacity(0.6), lineWidth: 1.5)
        )
        .shadow(color: accent.opacity(0.25), radius: 18)
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(accent)
            Text(label)
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(value)
                .font(.headline)
                .foregroundStyle(.white)
        }
        .font(.body)
    }
}

#Preview {
    ExerciseCard(
        exercise: Exercise(
            id: "1",
            exerciseName: "Guess the heading",
            airspaceRadius: 60,
            weatherType: "Custom",
            departureFlights: 2,
            arrivalFlights: 15
        ),
        number: 1,
        onStart: {}
    )
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.black)
}
