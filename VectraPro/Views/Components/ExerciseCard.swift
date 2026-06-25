//
//  ExerciseCard.swift
//  VectraPro
//
//  A single horizontally-scrolling card on the home screen.
//

import SwiftUI

struct ExerciseCard: View {

    let exercise: Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: exercise.systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.green)

            Spacer(minLength: 0)

            Text(exercise.title)
                .font(.headline)
                .foregroundStyle(.white)

            Text(exercise.subtitle)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(2)
        }
        .padding(20)
        .frame(width: 240, height: 170, alignment: .leading)
        .background(Color(white: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.green.opacity(0.35), lineWidth: 1)
        )
    }
}

#Preview {
    ExerciseCard(
        exercise: Exercise(
            title: "Guess the heading",
            subtitle: "Estimate the aircraft heading on the radar",
            systemImage: "location.north.line.fill",
            route: .map
        )
    )
    .padding()
    .background(.black)
}
