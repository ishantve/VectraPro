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
        .defaultSize(CGSize(width: 800, height: 800))
    }
}

// MARK: - Main window

struct MainWindowView: View {

    @ObservedObject private var presentation = WindowPresentation.shared
    @Environment(\.openWindow)    private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            if presentation.isRadarOpen {
                // Radar has moved to its own window
                Color.black.ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.on.rectangle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.green.opacity(0.6))
                    Text("Content is on new window")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                DummyAnimatedScreen()
            }

            // Window toggle button — always visible
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
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(presentation.isRadarOpen ? .black : .green)
                            .frame(width: 44, height: 44)
                            .background(
                                presentation.isRadarOpen ? Color.green : Color.black.opacity(0.6),
                                in: Circle()
                            )
                            .overlay(Circle().stroke(Color.green.opacity(0.4), lineWidth: 1))
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Radar window

struct RadarWindowScene: View {
    var body: some View {
        DummyAnimatedScreen()
            .overlay(
                Rectangle()
                    .stroke(Color.green, lineWidth: 6)
                    .ignoresSafeArea()
            )
            // Keep state honest if the window is closed by the system / user.
            .onAppear    { WindowPresentation.shared.isRadarOpen = true  }
            .onDisappear { WindowPresentation.shared.isRadarOpen = false }
    }
}
