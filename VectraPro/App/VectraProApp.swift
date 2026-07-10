//
//  VectraProApp.swift
//  VectraPro
//
//  Created by Ishant Zibal on 24/06/26.
//

import SwiftUI

@main
struct VectraProApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView()
        }

        WindowGroup(id: "radar") {
            RadarWindowScene()
        }
        .defaultSize(CGSize(width: 700, height: 700))
    }
}

// MARK: - Main window

struct MainWindowView: View {

    @ObservedObject private var presentation = WindowPresentation.shared
    @Environment(\.openWindow)    private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if presentation.selectedMode == nil {
                // Step 1: User picks a mode
                HomeSelectionView()
            } else if presentation.selectedMode == .stageManager {
                // Step 2a: Stage Manager flow
                StageManagerDemoView(
                    openWindow: { openWindow(id: "radar") },
                    dismissWindow: { dismissWindow(id: "radar") }
                )
                // Auto-open when HDMI connects
                .onChange(of: presentation.externalDisplayConnectTrigger) { _, _ in
                    guard !presentation.isRadarOpen else { return }
                    openWindow(id: "radar")
                    presentation.isRadarOpen = true
                }
            } else {
                // Step 2b: HDMI Auto mode — just show status
                HDMIAutoStatusView()
            }
        }
        .animation(.easeInOut(duration: 0.35), value: presentation.selectedMode == nil)
    }
}

// MARK: - Home Selection View

struct HomeSelectionView: View {

    @ObservedObject private var presentation = WindowPresentation.shared

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.15),
                         Color(red: 0.02, green: 0.03, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            GridBackground()
                .opacity(0.10)
                .ignoresSafeArea()

            VStack(spacing: 40) {

                // Title
                VStack(spacing: 8) {
                    Text("VectraPro")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Choose a display mode to continue")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.45))
                }

                // Mode cards
                VStack(spacing: 20) {
                    ModeCard(
                        icon: "rectangle.on.rectangle.fill",
                        title: "Stage Manager Mode",
                        description: "Uses SwiftUI's openWindow API.\nWorks best with Stage Manager enabled.\nHDMI connect auto-opens a second window.",
                        accentColor: .green
                    ) {
                        presentation.selectedMode = .stageManager
                    }

                    ModeCard(
                        icon: "display.2",
                        title: "HDMI Auto Mode",
                        description: "Uses UIKit UIWindow directly.\nContent appears on the external screen\nautomatically the moment HDMI is plugged in.",
                        accentColor: .cyan
                    ) {
                        presentation.selectedMode = .hdmiAuto
                        // If screen is already connected, show immediately
                        presentation.triggerHDMIAutoIfScreenPresent()
                    }
                }
                .padding(.horizontal, 32)
            }
        }
    }
}

// MARK: - Mode Card

private struct ModeCard: View {
    let icon: String
    let title: String
    let description: String
    let accentColor: Color
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 52, height: 52)
                    .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accentColor.opacity(0.7))
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(accentColor.opacity(0.25), lineWidth: 1)
                    )
            )
            .scaleEffect(pressed ? 0.97 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(.easeOut(duration: 0.1)) { pressed = true } }
                .onEnded   { _ in withAnimation(.spring())               { pressed = false } }
        )
    }
}

// MARK: - Stage Manager Demo View

struct StageManagerDemoView: View {

    @ObservedObject private var presentation = WindowPresentation.shared
    let openWindow: () -> Void
    let dismissWindow: () -> Void

    var body: some View {
        // Home button now lives in the bottom control bar.
        WorkspaceLayoutView()
    }
}

// MARK: - HDMI Auto Status View

struct HDMIAutoStatusView: View {

    @ObservedObject private var presentation = WindowPresentation.shared

    private var isExternalConnected: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen != UIScreen.main }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.07, blue: 0.15),
                         Color(red: 0.02, green: 0.03, blue: 0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            GridBackground()
                .opacity(0.10)
                .ignoresSafeArea()

            VStack(spacing: 32) {

                // Status indicator
                VStack(spacing: 16) {
                    Image(systemName: isExternalConnected ? "display.2" : "display.trianglebadge.exclamationmark")
                        .font(.system(size: 64))
                        .foregroundStyle(isExternalConnected ? .cyan : .white.opacity(0.3))

                    Text(isExternalConnected ? "External Display Active" : "Waiting for HDMI…")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(isExternalConnected
                         ? "Content is showing on the external screen via UIKit."
                         : "Plug in your HDMI cable.\nContent will appear on the external screen automatically.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                // Back to home
                Button {
                    presentation.closeUIKitWindow()
                    presentation.selectedMode = nil
                } label: {
                    Label("Back to Home", systemImage: "house.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                }
            }
        }
    }
}

// MARK: - Radar window (Stage Manager mode)

struct RadarWindowScene: View {
    var body: some View {
        HStack(spacing: 0) {
            // Left half — extended display shows the SAME objects as Main
            ObjectCanvas(display: .main)
                .overlay(alignment: .top) {
                    displayTitle("Extended Display")
                }

            Rectangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 1)

            // Right half — interactive display with its objects
            ObjectCanvas(display: .interactive)
                .overlay(alignment: .top) {
                    displayTitle("Interactive Display")
                }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .overlay(
            Rectangle()
                .stroke(Color.green, lineWidth: 6)
                .ignoresSafeArea()
        )
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        // Keep state honest if the window is closed by the system / user.
        .onAppear    { WindowPresentation.shared.isRadarOpen = true  }
        .onDisappear { WindowPresentation.shared.isRadarOpen = false }
    }

    private func displayTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.top, 12)
    }
}
