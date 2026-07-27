//
//  RootView.swift
//  VectraPro
//
//  Flow coordinator: on launch, resume a saved session straight to Home;
//  otherwise run onboarding (Organization ID → Login → Home).
//

import SwiftUI
import NetworkKit

enum AppRoute: Hashable {
    case login
}

struct RootView: View {

    private enum Phase {
        case checking      // deciding whether a saved session can resume
        case onboarding    // OrgID → Login
        case home          // logged in
    }

    @State private var phase: Phase = .checking
    @State private var path: [AppRoute] = []
    @State private var showSessionExpired = false
    @ObservedObject private var auth = AuthService.shared

    var body: some View {
        Group {
            switch phase {
            case .checking:
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView().tint(.white)
                }

            case .home:
                HomeScreen(onLogout: {
                    path.removeAll()
                    phase = .onboarding
                })

            case .onboarding:
                NavigationStack(path: $path) {
                    OrgIDScreen(onConfigured: { path.append(.login) })
                        .navigationDestination(for: AppRoute.self) { route in
                            switch route {
                            case .login:
                                LoginScreen(
                                    onLogin: { phase = .home },
                                    onChangeOrganization: { path.removeAll() }
                                )
                            }
                        }
                }
                .tint(.green)
            }
        }
        .task { await resume() }
        .onChange(of: auth.sessionExpired) { _, expired in
            guard expired else { return }
            // Refresh token dead → reset to the Organization ID screen + message.
            path.removeAll()
            phase = .onboarding
            showSessionExpired = true
            auth.sessionExpired = false   // consume the signal
        }
        .alert("Session Expired", isPresented: $showSessionExpired) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your session has expired. Please log in again.")
        }
    }

    /// On launch, if there's a saved session and a known API base URL, restore
    /// them and re-run the post-login bootstrap; on success go straight Home.
    @MainActor
    private func resume() async {
        guard phase == .checking else { return }

        guard AuthService.shared.isLoggedIn,
              let baseURL = ConfigStore.shared.cachedBaseURL else {
            phase = .onboarding
            return
        }

        APIManager.shared.baseURL = baseURL
        do {
            // Validates the session (auto-refreshes the token) and restores the
            // OrganizationId / gameId headers + org/game/user data.
            try await SessionService.shared.loadInitialData()
            phase = .home
        } catch {
            phase = .onboarding
        }
    }
}

#Preview {
    RootView()
}
