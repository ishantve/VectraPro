//
//  WorkspaceLayoutView.swift
//  VectraPro
//
//  Three-panel workspace shown on the iPad screen (Stage-Manager-like layout):
//    • Left  — large square window holding the draggable objects
//    • Right — information panel (parallel to the square)
//    • Bottom — full-width control bar
//  The left panel has a window button (top-right) that detaches it into its
//  own separate window; while detached the panel shows a placeholder.
//

import SwiftUI

struct WorkspaceLayoutView: View {

    @ObservedObject private var presentation = WindowPresentation.shared
    @Environment(\.openWindow) private var openWindow

    /// Which display is currently shown in the left panel.
    @State private var selectedDisplay: DisplayID = .main

    private let gap: CGFloat = 14
    private let outerPadding: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width  - outerPadding * 2
            let H = geo.size.height - outerPadding * 2

            // Top row gets 84% of the height; the bottom control bar takes the rest.
            let topH    = H * 0.84
            let bottomH = H - topH - gap

            // Left window is a square: as large as fits, capped at 70% of width.
            // Since it's square, its width grows in step with the top height.
            let leftSide = min(W * 0.70, topH)
            let rightW   = W - leftSide - gap

            VStack(spacing: gap) {
                // Top row: square (left) + info panel (right)
                HStack(spacing: gap) {
                    panel {
                        firstPanelContent
                    }
                    .frame(width: leftSide, height: topH)

                    panel {
                        InfoPanelView()
                    }
                    .frame(width: rightW, height: topH)
                }

                // Bottom control bar
                panel {
                    ControlBarView()
                }
                .frame(width: W, height: bottomH)
            }
            .padding(outerPadding)
        }
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - First panel (objects + window toggle)

    private var firstPanelContent: some View {
        ZStack {
            // Content — objects normally, placeholder while detached
            if presentation.isRadarOpen {
                Color.black
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green.opacity(0.6))
                    Text("Content is on separate window")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                ObjectCanvas(display: selectedDisplay)
            }

            // Top bar: display selector (left) + window toggle (right)
            VStack {
                HStack {
                    // Display selector pill — hidden while radar window is open
                    if !presentation.isRadarOpen {
                        displaySelector
                    }
                    Spacer()
                    // Window toggle button
                    Button {
                        if presentation.isRadarOpen {
                            presentation.closeRadarWindow()
                        } else {
                            openWindow(id: "radar")
                            presentation.isRadarOpen = true
                        }
                    } label: {
                        Image(systemName: presentation.isRadarOpen
                              ? "rectangle.on.rectangle.fill"
                              : "rectangle.on.rectangle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(presentation.isRadarOpen ? .black : .green)
                            .frame(width: 40, height: 40)
                            .background(
                                presentation.isRadarOpen ? Color.green : Color.black.opacity(0.6),
                                in: Circle()
                            )
                            .overlay(Circle().stroke(Color.green.opacity(0.4), lineWidth: 1))
                    }
                }
                .padding(12)
                Spacer()
            }
        }
    }

    // MARK: - Display selector

    private var displaySelector: some View {
        HStack(spacing: 0) {
            displayTab("Display 1", display: .main)
            displayTab("Additional Screen", display: .interactive)
        }
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    private func displayTab(_ label: String, display: DisplayID) -> some View {
        let isActive = selectedDisplay == display
        return Button {
            selectedDisplay = display
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isActive ? .black : .white.opacity(0.6))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isActive ? Color.green : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: selectedDisplay)
    }

    // MARK: - Panel chrome

    @ViewBuilder
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }
}

#Preview {
    WorkspaceLayoutView()
}
