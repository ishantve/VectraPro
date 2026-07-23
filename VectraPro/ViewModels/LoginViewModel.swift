//
//  LoginViewModel.swift
//  VectraPro
//
//  Owns the login → post-login bootstrap orchestration, moved out of
//  LoginScreen. The view keeps only presentation (form state, toast, loading,
//  navigation); the auth + session-load sequence lives here.
//

import Combine
import Foundation

@MainActor
final class LoginViewModel: ObservableObject {

    private let auth: AuthService
    private let session: SessionService

    init(auth: AuthService = .shared, session: SessionService = .shared) {
        self.auth = auth
        self.session = session
    }

    /// Authenticate (nickname or username/password), then run the post-login
    /// bootstrap (/organizations → /games → nickname user). Throws on failure so
    /// the view can present the error.
    func signIn(nicknameAllowed: Bool, nickname: String,
                username: String, password: String) async throws {
        if nicknameAllowed {
            try await auth.login(nickname: nickname)
        } else {
            try await auth.login(username: username, password: password)
        }
        // Post-login bootstrap: /organizations then /games (sequential).
        try await session.loadInitialData()
    }
}
