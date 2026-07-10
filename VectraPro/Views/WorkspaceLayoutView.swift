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
    @Environment(\.openWindow)    private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private let gap: CGFloat = 14
    private let outerPadding: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width  - outerPadding * 2
            let H = geo.size.height - outerPadding * 2

            // Bottom control bar takes a fixed share of the height.
            let bottomH = H * 0.16
            let topH    = H - bottomH - gap

            // Left window is a square: as large as fits, capped at 70% of width.
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
                ObjectCanvas(display: .main)
            }

            // Heading — always visible on the main panel
            VStack {
                Text("Main Display")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.top, 12)
                Spacer()
            }

            // Window toggle button — top-right of the first panel
            VStack {
                HStack {
                    Spacer()
                    Button {
                        if presentation.isRadarOpen {
                            dismissWindow(id: "radar")
                            presentation.isRadarOpen = false
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
                    .padding(12)
                }
                Spacer()
            }
        }
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
