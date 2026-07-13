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

    @ObservedObject private var store = ObjectsStore.shared
    private let step: CGFloat = 20

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.10, blue: 0.16),
                         Color(red: 0.04, green: 0.05, blue: 0.10)],
                startPoint: .leading, endPoint: .trailing
            )
            .ignoresSafeArea()

            HStack(spacing: 20) {
                // Home — back to mode selection
                Button {
                    if WindowPresentation.shared.isRadarOpen {
                        WindowPresentation.shared.closeRadarWindow()
                    }
                    WindowPresentation.shared.selectedMode = nil
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Text("Controls")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))

                Spacer()

                // Direction pad — moves the selected object
                let disabled = store.selectedID == nil
                HStack(spacing: 10) {
                    arrow("arrow.left")  { store.nudgeSelected(dx: -step, dy: 0) }
                    VStack(spacing: 10) {
                        arrow("arrow.up")   { store.nudgeSelected(dx: 0, dy: -step) }
                        arrow("arrow.down") { store.nudgeSelected(dx: 0, dy:  step) }
                    }
                    arrow("arrow.right") { store.nudgeSelected(dx:  step, dy: 0) }
                }
                .opacity(disabled ? 0.35 : 1)
                .disabled(disabled)

                Divider()
                    .frame(height: 44)
                    .overlay(Color.white.opacity(0.15))

                // Resize — grows / shrinks the selected object
                HStack(spacing: 10) {
                    arrow("minus") { store.resizeSelected(by: -12) }
                    arrow("plus")  { store.resizeSelected(by:  12) }
                }
                .opacity(disabled ? 0.35 : 1)
                .disabled(disabled)
            }
            .padding(.horizontal, 28)
        }
    }

    private func arrow(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.green.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    InfoPanelView()
}
