//
//  ExternalPanels.swift
//  VectraPro
//
//  The two companion windows shown next to the main objects window on the
//  external display: an information panel (right) and a control bar (bottom).
//  Content inside them is a placeholder for now.
//

import SwiftUI

// MARK: - Right information panel

struct InfoPanelView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.09, blue: 0.18),
                         Color(red: 0.03, green: 0.05, blue: 0.11)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.cyan.opacity(0.7))
                Text("Information")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Panel content coming soon")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

// MARK: - Bottom control bar

struct ControlBarView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.10, blue: 0.16),
                         Color(red: 0.04, green: 0.05, blue: 0.10)],
                startPoint: .leading, endPoint: .trailing
            )
            .ignoresSafeArea()

            HStack(spacing: 24) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 26))
                    .foregroundStyle(.green.opacity(0.7))
                Text("Controls")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
            }
            .padding(.horizontal, 28)
        }
    }
}

#Preview {
    InfoPanelView()
}
