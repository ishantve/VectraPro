//
//  AuthService.swift
//  VectraPro
//
//  Logs in against the selected organization's `AuthURL` (Keycloak / OpenID
//  Connect token endpoint) and applies the resulting access token to APIManager
//  so all subsequent API calls are authenticated.
//

import Foundation

/// OAuth2 token response from the AuthURL.
struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case tokenType    = "token_type"
    }
}

/// Error body Keycloak returns on a failed token request.
struct OAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

enum AuthError: LocalizedError {
    case missingConfig
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "No organization configuration found. Please re-enter the Organization ID."
        case .message(let text):
            return text
        }
    }
}

@MainActor
final class AuthService {

    static let shared = AuthService()

    private(set) var accessToken: String?
    private(set) var refreshToken: String?
    /// The nickname for the current session, when the org uses nickname login.
    private(set) var nickname: String?

    /// Username + password login (OAuth2 password grant).
    func login(username: String, password: String) async throws {
        try await authenticate(extra: [
            "grant_type": "password",
            "username": username,
            "password": password
        ])
    }

    /// Nickname login (org `Nickname == "Allowed"`). Uses the client-credentials
    /// grant and tags the session with the chosen nickname.
    /// NOTE: confirm this is the intended nickname auth flow for your backend.
    func login(nickname: String) async throws {
        try await authenticate(extra: ["grant_type": "client_credentials"])
        self.nickname = nickname
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
        nickname = nil
        APIManager.shared.removeDefaultHeader(forKey: "Authorization")
    }

    // MARK: Core

    private func authenticate(extra: [String: String]) async throws {
        guard let config = ConfigStore.shared.current(), !config.authURL.isEmpty else {
            throw AuthError.missingConfig
        }

        var form = extra
        form["client_id"] = config.stratagemMobileID
        form["client_secret"] = config.stratagemMobileSecret

        do {
            let token: TokenResponse = try await APIManager.shared.postForm(config.authURL, form: form)
            accessToken = token.accessToken
            refreshToken = token.refreshToken
            APIManager.shared.setDefaultHeader("Bearer \(token.accessToken)", forKey: "Authorization")
        } catch let APIError.unacceptableStatus(_, data) {
            // Surface Keycloak's error_description when present.
            if let oauth = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
               let description = oauth.errorDescription ?? oauth.error {
                throw AuthError.message(description)
            }
            throw AuthError.message("Login failed. Please check your credentials.")
        }
    }
}
