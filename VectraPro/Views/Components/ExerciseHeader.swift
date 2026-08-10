//
//  ExerciseHeader.swift
//  VectraPro
//
//  Back button, and the exercise clock beneath it.
//
//  This was written twice in MapScreen — once for the normal layout and once for the
//  detached workspace — identical but for the padding around it. The padding stays at
//  the call sites, since the two layouts place it differently; everything inside is the
//  same and is now written once.
//

import SwiftUI

struct ExerciseHeader: View {

    let elapsedSeconds: Int
    /// False when the exercise has no set duration, in which case there is no clock.
    let showsTimer: Bool
    let onBack: () -> Void

    private static let clockTint = Color(red: 0.2, green: 1.0, blue: 0.4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            backButton
            if showsTimer { timer }
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.6), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
        }
    }

    private var timer: some View {
        HStack(spacing: 6) {
            Image("timer_icon")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
            Text(elapsedSeconds.asTimerString)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(Self.clockTint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.6), in: Capsule())
        .overlay(Capsule().stroke(Self.clockTint.opacity(0.4), lineWidth: 1))
    }
}
